// Development stand-in for gsrd: behaves like the card side of the shared memory (gsr_ring.h) without any FireWire.
// It simulates a card clock that runs 138 ppm fast against the Mac, produces test tones on the input ring
// (channel k at 200 + 50 k Hz) and checks what the plug-in wrote to the output ring.
// This is test code for the plug-in. It is not part of the product and never touches the card.
//
//   devsim --file PATH [--rate 96000]     ring in a file (used by the offline harness)
//   devsim --xpc [--rate 96000]           ring handed out over the Mach service GSR_MACH_SERVICE (LaunchDaemon)
//
// Build: see build.sh

#include "gsr_ring.h"

#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <xpc/xpc.h>

#define RING_FRAMES 16384u
#define OUT_LATENCY 3072u
#define CARD_PPM 138.0

static GsrRingHeader *H;
static mach_timebase_info_data_t TB;
static double hostHz;
static const uint32_t kRates[4] = {44100, 48000, 88200, 96000};

static void initHeader(uint32_t rate) {
    memset(H, 0, 4096);
    H->magic = GSR_RING_MAGIC; H->version = GSR_RING_VERSION;
    atomic_store(&H->sampleRate, rate); atomic_store(&H->state, GSR_STATE_IDLE);
    H->channelsIn = H->channelsOut = GSR_MAX_CH; H->ringFrames = RING_FRAMES;
    H->inLatencyFrames = 0; H->outLatencyFrames = OUT_LATENCY; H->safetyIn = 192; H->safetyOut = 192;
    H->inOffset = 4096; H->outOffset = 4096 + (uint64_t)RING_FRAMES * GSR_MAX_CH * sizeof(float);
    H->totalBytes = gsr_ring_bytes(RING_FRAMES);
    for (int k = 0; k < GSR_MAX_CH; k++) { snprintf(H->nameIn[k], GSR_NAME_LEN, "In %d", k + 1); snprintf(H->nameOut[k], GSR_NAME_LEN, "Out %d", k + 1); }
    atomic_store(&H->generation, 1);
}

// Counts rising zero crossings to estimate a frequency; keeps RMS.
typedef struct { double prev, rms2; uint64_t n, cross; } Meter;
static void meterAdd(Meter *m, double x) { if (m->prev < 0 && x >= 0) m->cross++; m->prev = x; m->rms2 += x * x; m->n++; }

static void makeRealtime(void) {
    // A daemon thread gets its timers coalesced (about 3 ms late in the spike): the simulated card clock must be real-time like the FireWire callbacks.
    thread_time_constraint_policy_data_t p;
    p.period = (uint32_t)(hostHz * 0.001); p.computation = (uint32_t)(hostHz * 0.0002); p.constraint = (uint32_t)(hostHz * 0.0006); p.preemptible = 1;
    kern_return_t r = thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&p, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    printf("devsim: real-time policy %s\n", r == KERN_SUCCESS ? "set" : "FAILED"); fflush(stdout);
}

static void *clockThread(void *arg) {
    (void)arg;
    makeRealtime();
    uint64_t gen = 1;
    uint32_t rate = atomic_load(&H->sampleRate);
    double tpf = hostHz / (rate * (1.0 + CARD_PPM * 1e-6));
    uint64_t t0 = mach_absolute_time();
    uint64_t frames = 0, lastReport = t0, lateOut = 0;
    Meter m0 = {0}, m31 = {0};
    uint64_t reportFrames = 0;
    atomic_store(&H->state, GSR_STATE_STREAMING);
    for (;;) {
        mach_wait_until(mach_absolute_time() + (uint64_t)(hostHz * 0.001));
        uint64_t now = mach_absolute_time();
        // clock change requested by the plug-in: restart the "card" at the new rate
        uint32_t req = atomic_load(&H->requestedRate);
        if (req) {
            for (int i = 0; i < 4; i++) if (kRates[i] == req) {
                printf("devsim: rate change %u -> %u\n", rate, req); fflush(stdout);
                atomic_store(&H->state, GSR_STATE_IDLE);
                rate = req; atomic_store(&H->sampleRate, rate);
                atomic_store(&H->inWritten, 0); atomic_store(&H->outRead, 0); atomic_store(&H->outWritten, 0);
                gen++; atomic_store(&H->generation, (uint32_t)gen);
                tpf = hostHz / (rate * (1.0 + CARD_PPM * 1e-6)); t0 = mach_absolute_time(); frames = 0; reportFrames = 0;
                atomic_store(&H->state, GSR_STATE_STREAMING);
            }
            atomic_store(&H->requestedRate, 0);
            continue;
        }
        uint64_t target = (uint64_t)(((double)(now - t0)) / tpf);
        float *in = gsr_in_ring(H); const float *out = gsr_out_ring(H);
        uint32_t clients = atomic_load(&H->ioClients);
        uint64_t outW = atomic_load_explicit(&H->outWritten, memory_order_acquire);
        for (; frames < target; frames++) {
            size_t slot = (size_t)(frames & (RING_FRAMES - 1)) * GSR_MAX_CH;
            for (int k = 0; k < GSR_MAX_CH; k++) in[slot + k] = 0.1f * sinf((float)(2 * M_PI * fmod((200.0 + 50.0 * k) * (double)frames / rate, 1.0)));
            // card plays frame `frames` from output sample time frames - OUT_LATENCY
            int64_t st = (int64_t)frames - OUT_LATENCY;
            if (clients && st >= 0 && (uint64_t)st < outW) {
                const float *o = out + (size_t)(st & (RING_FRAMES - 1)) * GSR_MAX_CH;
                meterAdd(&m0, o[0]); meterAdd(&m31, o[31]);
            } else if (clients && st >= 0) lateOut++;
        }
        atomic_store_explicit(&H->inWritten, frames, memory_order_release);
        atomic_store_explicit(&H->outRead, frames, memory_order_relaxed);
        gsr_anchor_write(H, frames, t0 + (uint64_t)((double)frames * tpf), tpf);
        if ((now - lastReport) * TB.numer / TB.denom >= 1000000000ull) {
            lastReport = now;
            double secs = (double)(frames - reportFrames) / rate; reportFrames = frames;
            printf("devsim: rate %u clients %u | out ch1 %6.1f Hz rms %.3f | out ch32 %6.1f Hz rms %.3f | out late %llu, in late (plug-in) %llu\n",
                   rate, clients, m0.cross / secs, m0.n ? sqrt(m0.rms2 / m0.n) : 0, m31.cross / secs, m31.n ? sqrt(m31.rms2 / m31.n) : 0,
                   (unsigned long long)lateOut, (unsigned long long)atomic_load(&H->inLate));
            fflush(stdout);
            memset(&m0, 0, sizeof m0); memset(&m31, 0, sizeof m31);
        }
    }
    return NULL;
}

int main(int argc, char **argv) {
    const char *file = NULL; int xpc = 0; uint32_t rate = 48000;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--file") && i + 1 < argc) file = argv[++i];
        else if (!strcmp(argv[i], "--xpc")) xpc = 1;
        else if (!strcmp(argv[i], "--rate") && i + 1 < argc) rate = (uint32_t)atoi(argv[++i]);
    }
    if (!file && !xpc) { fprintf(stderr, "usage: devsim --file PATH | --xpc [--rate N]\n"); return 2; }
    mach_timebase_info(&TB); hostHz = 1e9 * TB.denom / TB.numer;
    size_t bytes = (size_t)gsr_ring_bytes(RING_FRAMES);
    if (file) {
        int fd = open(file, O_RDWR | O_CREAT | O_TRUNC, 0644);
        if (fd < 0 || ftruncate(fd, (off_t)bytes)) { perror("ring file"); return 1; }
        H = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (H == MAP_FAILED) { perror("mmap"); return 1; }
    } else {
        vm_address_t va = 0;
        if (vm_allocate(mach_task_self(), &va, bytes, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) return 1;
        H = (GsrRingHeader *)va;
    }
    initHeader(rate);
    pthread_t t; pthread_create(&t, NULL, clockThread, NULL);
    if (xpc) {
        xpc_connection_t l = xpc_connection_create_mach_service(GSR_MACH_SERVICE, dispatch_get_main_queue(), XPC_CONNECTION_MACH_SERVICE_LISTENER);
        xpc_connection_set_event_handler(l, ^(xpc_object_t peer) {
            if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
            xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
                if (xpc_get_type(msg) != XPC_TYPE_DICTIONARY) return;
                xpc_object_t reply = xpc_dictionary_create_reply(msg);
                if (!reply) return;
                xpc_dictionary_set_value(reply, "ring", xpc_shmem_create(H, bytes));
                xpc_connection_send_message(peer, reply);
                printf("devsim: ring handed to pid %d\n", xpc_connection_get_pid(peer)); fflush(stdout);
            });
            xpc_connection_resume(peer);
        });
        xpc_connection_resume(l);
        dispatch_main();
    }
    pthread_join(t, NULL);
    return 0;
}
