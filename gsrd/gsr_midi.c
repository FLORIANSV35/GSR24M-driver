// SPDX-License-Identifier: Apache-2.0
#include "gsr_midi.h"

#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

// ---------- capture: isochronous thread to subscribers ----------

#define EVQ 8192
typedef struct { uint64_t t; uint8_t port, byte; } Ev;
static Ev gEv[EVQ];
static _Atomic uint32_t gEvHead, gEvTail;                 // single producer (isochronous thread), single consumer (gQ)
static dispatch_queue_t gQ;
static dispatch_source_t gSrc;
static _Atomic uint64_t gInBytes[GSRM_MUX], gOutBytes[GSRM_PORTS], gInDrops, gOutDrops;

#define MAXSUB 8
static xpc_connection_t gSub[MAXSUB];
static pthread_mutex_t gSubLock = PTHREAD_MUTEX_INITIALIZER;

static void drain(void) {
    uint32_t tail = atomic_load_explicit(&gEvTail, memory_order_relaxed), head = atomic_load_explicit(&gEvHead, memory_order_acquire);
    if (tail == head) return;
    uint8_t buf[GSRM_PORTS][256]; unsigned n[GSRM_PORTS] = {0}; uint64_t t0[GSRM_PORTS] = {0};
    while (tail != head) {
        const Ev *e = &gEv[tail % EVQ];
        if (e->port < GSRM_PORTS) {
            if (n[e->port] == 0) t0[e->port] = e->t;
            if (n[e->port] < sizeof buf[0]) buf[e->port][n[e->port]++] = e->byte;
        }
        tail++;
    }
    atomic_store_explicit(&gEvTail, tail, memory_order_release);
    pthread_mutex_lock(&gSubLock);
    for (int s = 0; s < MAXSUB; s++) {
        if (!gSub[s]) continue;
        for (unsigned p = 0; p < GSRM_PORTS; p++) {
            if (!n[p]) continue;
            xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
            xpc_dictionary_set_string(m, "op", "midi");
            xpc_dictionary_set_uint64(m, "port", p);
            xpc_dictionary_set_uint64(m, "t", t0[p]);
            xpc_dictionary_set_data(m, "data", buf[p], n[p]);
            xpc_connection_send_message(gSub[s], m);
            xpc_release(m);
        }
    }
    pthread_mutex_unlock(&gSubLock);
}

void gsrm_rx(const uint8_t *quadlet, uint32_t dbc) {
    uint8_t b[3];
    int n = gsrm_decode(quadlet, b);
    if (!n) return;
    unsigned port = gsrm_port_of(dbc);
    atomic_fetch_add_explicit(&gInBytes[port], (uint64_t)n, memory_order_relaxed);   // all eight, to see where the card really puts the bytes
    if (port >= GSRM_PORTS) return;
    uint64_t now = mach_absolute_time();
    for (int i = 0; i < n; i++) {
        uint32_t head = atomic_load_explicit(&gEvHead, memory_order_relaxed), tail = atomic_load_explicit(&gEvTail, memory_order_acquire);
        if (head - tail >= EVQ) { atomic_fetch_add_explicit(&gInDrops, 1, memory_order_relaxed); continue; }
        gEv[head % EVQ] = (Ev){ now, (uint8_t)port, b[i] };
        atomic_store_explicit(&gEvHead, head + 1, memory_order_release);
    }
    if (gSrc) dispatch_source_merge_data(gSrc, 1);
}

// ---------- playback: any thread to the isochronous thread ----------

#define OQ 4096
typedef struct {
    uint8_t b[OQ];
    _Atomic uint32_t head, tail;                           // producers serialised by `lock`; the consumer is the isochronous thread
    pthread_mutex_t lock;
    uint64_t next;                                         // first block at which this port may carry another byte
} OutQ;
static OutQ gOut[GSRM_PORTS];

int gsrm_send(unsigned port, const uint8_t *data, size_t n) {
    if (port >= GSRM_PORTS) return 0;
    OutQ *o = &gOut[port];
    size_t k = 0;
    pthread_mutex_lock(&o->lock);
    uint32_t head = atomic_load_explicit(&o->head, memory_order_relaxed);
    for (; k < n; k++) {
        if (head - atomic_load_explicit(&o->tail, memory_order_acquire) >= OQ) { atomic_fetch_add(&gOutDrops, n - k); break; }
        o->b[head % OQ] = data[k]; head++;
    }
    atomic_store_explicit(&o->head, head, memory_order_release);
    pthread_mutex_unlock(&o->lock);
    return (int)k;
}

unsigned gsrm_gap_for_rate(unsigned rate) { return (unsigned)((uint64_t)rate * 320 / 1000000) + 1; }    // 16 blocks at 48 kHz, 31 at 96 kHz

void gsrm_patch(uint8_t *blocks, unsigned blockBytes, unsigned midiOffset, unsigned nBlocks, uint8_t dbc, uint64_t *blockClock, unsigned gap) {
    for (unsigned b = 0; b < nBlocks; b++) {
        unsigned port = gsrm_port_of((uint32_t)dbc + b);
        uint64_t t = *blockClock + b;
        if (port >= GSRM_PORTS) continue;
        OutQ *o = &gOut[port];
        if (t < o->next) continue;
        uint32_t tail = atomic_load_explicit(&o->tail, memory_order_relaxed), head = atomic_load_explicit(&o->head, memory_order_acquire);
        if (tail == head) continue;
        uint8_t *q = blocks + (size_t)b * blockBytes + midiOffset;
        if (q[0] != 0x80) continue;                        // the slot already carries something
        uint8_t byte = o->b[tail % OQ];
        gsrm_encode(q, &byte, 1);
        atomic_store_explicit(&o->tail, tail + 1, memory_order_release);
        o->next = t + gap;
        atomic_fetch_add_explicit(&gOutBytes[port], 1, memory_order_relaxed);
    }
    *blockClock += nBlocks;
}

void gsrm_reset(void) {
    for (unsigned p = 0; p < GSRM_PORTS; p++) {
        atomic_store(&gOut[p].tail, atomic_load(&gOut[p].head));
        gOut[p].next = 0;
    }
}

// ---------- XPC ----------

void gsrm_init(void) {
    for (unsigned p = 0; p < GSRM_PORTS; p++) pthread_mutex_init(&gOut[p].lock, NULL);
    gQ = dispatch_queue_create("com.gsr24m.gsrd.midi", DISPATCH_QUEUE_SERIAL);
    gSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_OR, 0, 0, gQ);
    dispatch_source_set_event_handler(gSrc, ^{ drain(); });
    dispatch_resume(gSrc);
}

void gsrm_peer_gone(xpc_connection_t peer) {
    pthread_mutex_lock(&gSubLock);
    for (int s = 0; s < MAXSUB; s++) if (gSub[s] == peer) { xpc_release(gSub[s]); gSub[s] = NULL; }
    pthread_mutex_unlock(&gSubLock);
}

int gsrm_xpc(const char *op, xpc_object_t msg, xpc_object_t reply, xpc_connection_t peer) {
    if (!op || strncmp(op, "midi", 4)) return 0;
    if (!strcmp(op, "midiSubscribe")) {
        int ok = 0;
        pthread_mutex_lock(&gSubLock);
        for (int s = 0; s < MAXSUB && !ok; s++) if (gSub[s] == peer) ok = 1;
        for (int s = 0; s < MAXSUB && !ok; s++) if (!gSub[s]) { gSub[s] = xpc_retain(peer); ok = 1; }
        pthread_mutex_unlock(&gSubLock);
        xpc_dictionary_set_bool(reply, "ok", ok);
        xpc_dictionary_set_uint64(reply, "ports", GSRM_PORTS);
    } else if (!strcmp(op, "midiUnsubscribe")) {
        gsrm_peer_gone(peer);
        xpc_dictionary_set_bool(reply, "ok", true);
    } else if (!strcmp(op, "midiSend")) {
        size_t len = 0;
        const void *d = xpc_dictionary_get_data(msg, "data", &len);
        uint64_t port = xpc_dictionary_get_uint64(msg, "port");
        int k = (d && port < GSRM_PORTS) ? gsrm_send((unsigned)port, d, len) : 0;
        xpc_dictionary_set_bool(reply, "ok", d && (size_t)k == len);
        xpc_dictionary_set_uint64(reply, "accepted", (uint64_t)k);
    } else xpc_dictionary_set_bool(reply, "ok", false);
    return 1;
}

size_t gsrm_json(char *buf, size_t cap, size_t n) {
    #define APP(...) do { if (n < cap) { int m = snprintf(buf + n, cap - n, __VA_ARGS__); if (m > 0) n = (n + (size_t)m < cap) ? n + (size_t)m : cap; } } while (0)
    int subs = 0;
    pthread_mutex_lock(&gSubLock);
    for (int s = 0; s < MAXSUB; s++) if (gSub[s]) subs++;
    pthread_mutex_unlock(&gSubLock);
    APP(",\"midi\":{\"subscribers\":%d,\"in\":[", subs);
    for (int p = 0; p < GSRM_MUX; p++) APP("%s%llu", p ? "," : "", (unsigned long long)atomic_load(&gInBytes[p]));
    APP("],\"out\":[");
    for (int p = 0; p < GSRM_PORTS; p++) APP("%s%llu", p ? "," : "", (unsigned long long)atomic_load(&gOutBytes[p]));
    APP("],\"inDrops\":%llu,\"outDrops\":%llu}", (unsigned long long)atomic_load(&gInDrops), (unsigned long long)atomic_load(&gOutDrops));
    #undef APP
    return n;
}
