// SPDX-License-Identifier: Apache-2.0
//
// Command line client for the MIDI of the card, through gsrd (same Mach service as the app).
//   gsrmidi listen [seconds]      subscribe and print every MIDI message the card receives (all three ports), decoded
//   gsrmidi send PORT HEX...      send bytes to a port, e.g.  gsrmidi send 0 90 6D 7F
//   gsrmidi stats                 the "midi" counters of gsrd, including the bytes seen on every multiplexed port number
#include "../hal/gsr_ring.h"
#include "gsr_midi.h"
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xpc/xpc.h>

static mach_timebase_info_data_t gTb;
static double gNow;      // seconds since the first byte, for display

// Running-status decoder, one per port.
typedef struct { uint8_t status, data[2]; int have, need; int sysex; uint8_t sx[256]; int sxn; } Dec;
static Dec gDec[GSRM_PORTS];

static void show(unsigned port, const uint8_t *m, int n, const char *what) {
    printf("%8.3f  port %u  ", gNow, port);
    for (int i = 0; i < n; i++) printf("%02X ", m[i]);
    for (int i = n; i < 8; i++) printf("   ");
    printf(" %s\n", what);
}

static void feed(unsigned port, uint8_t b, double t) {
    Dec *d = &gDec[port];
    char what[96]; uint8_t msg[3];
    gNow = t;
    if (b >= 0xF8) { msg[0] = b; snprintf(what, sizeof what, "realtime"); show(port, msg, 1, what); return; }
    if (d->sysex) {
        if (d->sxn < (int)sizeof d->sx) d->sx[d->sxn++] = b;
        if (b == 0xF7) {
            char hex[32] = {0};
            if (d->sxn >= 6 && d->sx[0] == 0x7F && d->sx[2] == 0x06) snprintf(hex, sizeof hex, "MMC command 0x%02X", d->sx[3]);
            snprintf(what, sizeof what, "sysex, %d bytes %s", d->sxn, hex);
            printf("%8.3f  port %u  F0 ", gNow, port);
            for (int i = 0; i < d->sxn; i++) printf("%02X ", d->sx[i]);
            printf(" %s\n", what);
            d->sysex = 0; d->sxn = 0;
        }
        return;
    }
    if (b & 0x80) {
        if (b == 0xF0) { d->sysex = 1; d->sxn = 0; return; }
        d->status = b; d->have = 0;
        d->need = ((b & 0xF0) == 0xC0 || (b & 0xF0) == 0xD0) ? 1 : 2;
        return;
    }
    if (!d->status) return;
    d->data[d->have++] = b;
    if (d->have < d->need) return;
    d->have = 0;
    msg[0] = d->status; msg[1] = d->data[0]; msg[2] = d->need > 1 ? d->data[1] : 0;
    unsigned ch = (d->status & 0x0F) + 1;
    switch (d->status & 0xF0) {
        case 0x90: snprintf(what, sizeof what, msg[2] ? "note on  ch%u  note 0x%02X (%u)  velocity %u" : "note off ch%u  note 0x%02X (%u)", ch, msg[1], msg[1], msg[2]); break;
        case 0x80: snprintf(what, sizeof what, "note off ch%u  note 0x%02X (%u)", ch, msg[1], msg[1]); break;
        case 0xB0: snprintf(what, sizeof what, "control  ch%u  controller 0x%02X (%u)  value %u", ch, msg[1], msg[1], msg[2]); break;
        case 0xA0: snprintf(what, sizeof what, "aftertouch ch%u  0x%02X  %u", ch, msg[1], msg[2]); break;
        default: snprintf(what, sizeof what, "status 0x%02X", d->status);
    }
    show(port, msg, d->need + 1, what);
}

static xpc_connection_t conn(xpc_handler_t h) {
    xpc_connection_t c = xpc_connection_create_mach_service(GSR_MACH_SERVICE, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), 0);
    xpc_connection_set_event_handler(c, h);
    xpc_connection_resume(c);
    return c;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: gsrmidi listen [seconds] | send PORT HEX... | stats\n"); return 2; }
    mach_timebase_info(&gTb);
    if (!strcmp(argv[1], "listen")) {
        double secs = argc > 2 ? atof(argv[2]) : 60;
        setvbuf(stdout, NULL, _IOLBF, 0);
        __block uint64_t first = 0;
        xpc_connection_t c = conn(^(xpc_object_t e) {
            if (xpc_get_type(e) != XPC_TYPE_DICTIONARY) return;
            const char *op = xpc_dictionary_get_string(e, "op");
            if (!op || strcmp(op, "midi")) return;
            size_t n = 0; const uint8_t *d = xpc_dictionary_get_data(e, "data", &n);
            unsigned port = (unsigned)xpc_dictionary_get_uint64(e, "port");
            uint64_t t = xpc_dictionary_get_uint64(e, "t");
            if (!first) first = t;
            double sec = (double)(t - first) * gTb.numer / gTb.denom / 1e9;
            if (port < GSRM_PORTS) for (size_t i = 0; i < n; i++) feed(port, d[i], sec);
        });
        xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(m, "op", "midiSubscribe");
        xpc_object_t r = xpc_connection_send_message_with_reply_sync(c, m);
        if (xpc_get_type(r) != XPC_TYPE_DICTIONARY || !xpc_dictionary_get_bool(r, "ok")) { fprintf(stderr, "could not subscribe (is gsrd running, and the new version?)\n"); return 1; }
        fprintf(stderr, "listening for %.0f s on the %llu MIDI ports of the card; use the console now\n", secs, (unsigned long long)xpc_dictionary_get_uint64(r, "ports"));
        sleep((unsigned)secs);
        return 0;
    }
    if (!strcmp(argv[1], "send") && argc > 3) {
        uint8_t buf[256]; size_t n = 0;
        for (int i = 3; i < argc && n < sizeof buf; i++) buf[n++] = (uint8_t)strtoul(argv[i], NULL, 16);
        xpc_connection_t c = conn(^(xpc_object_t e) { (void)e; });
        xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(m, "op", "midiSend");
        xpc_dictionary_set_uint64(m, "port", strtoull(argv[2], NULL, 10));
        xpc_dictionary_set_data(m, "data", buf, n);
        xpc_object_t r = xpc_connection_send_message_with_reply_sync(c, m);
        int ok = xpc_get_type(r) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_bool(r, "ok");
        printf("%s (%llu of %zu bytes accepted)\n", ok ? "sent" : "refused", xpc_get_type(r) == XPC_TYPE_DICTIONARY ? (unsigned long long)xpc_dictionary_get_uint64(r, "accepted") : 0ULL, n);
        return ok ? 0 : 1;
    }
    if (!strcmp(argv[1], "stats")) {
        xpc_connection_t c = conn(^(xpc_object_t e) { (void)e; });
        xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(m, "op", "info");
        xpc_object_t r = xpc_connection_send_message_with_reply_sync(c, m);
        if (xpc_get_type(r) != XPC_TYPE_DICTIONARY) { fprintf(stderr, "no reply\n"); return 1; }
        const char *json = xpc_dictionary_get_string(r, "json"), *p = json ? strstr(json, "\"midi\":{") : NULL;
        if (!p) { printf("no midi section: the installed gsrd is the old version\n"); return 1; }
        int depth = 0; const char *q = p + 7;
        printf("midi ");
        for (; *q; q++) { putchar(*q); if (*q == '{') depth++; if (*q == '}' && --depth == 0) break; }
        printf("\n");
        return 0;
    }
    fprintf(stderr, "unknown command\n");
    return 2;
}
