// Shared memory between gsrd (producer/consumer on the FireWire side) and the HAL plug-in (CoreAudio side).
// One region: header, then the input ring (card to host), then the output ring (host to card).
// Samples are float32, interleaved by frame, GSR_MAX_CH channels per frame. Ring sizes are powers of two.
//
// Time base: "sample time" S is the card's frame counter since the stream generation started (0 at start).
// The plug-in uses S directly as CoreAudio sample time. The card is the clock master.
//
//   input  frame S is valid when S < inWritten and S >= inWritten - ringFrames.
//   output frame S is written by the plug-in at slot S mod ringFrames; outWritten is the highest S+1 written.
//   gsrd plays card frame f from output sample time f - outLatencyFrames; a frame beyond outWritten is silence.

#ifndef GSR_RING_H
#define GSR_RING_H

#include <stdatomic.h>
#include <stdint.h>

#define GSR_RING_MAGIC 0x32525347u          // 'GSR2'
#define GSR_RING_VERSION 1
#define GSR_MAX_CH 32
#define GSR_NAME_LEN 32
#define GSR_MACH_SERVICE "com.gsr24m.gsrd"

enum { GSR_STATE_DOWN = 0, GSR_STATE_IDLE = 1, GSR_STATE_STREAMING = 2 };

typedef struct {
    uint32_t magic, version;
    _Atomic uint32_t generation;            // bumped on every stream (re)start; CoreAudio sample time restarts at 0
    _Atomic uint32_t state;                 // GSR_STATE_*
    _Atomic uint32_t sampleRate;            // Hz, current card rate
    _Atomic uint32_t requestedRate;         // written by the plug-in when a client changes the nominal rate; gsrd clears it
    uint32_t channelsIn, channelsOut;       // used channels per frame, <= GSR_MAX_CH
    uint32_t ringFrames;                    // power of two
    uint32_t inLatencyFrames;               // reported to CoreAudio as device latency (input)
    uint32_t outLatencyFrames;              // reported as device latency (output); also the offset used by gsrd
    uint32_t safetyIn, safetyOut;           // safety offsets reported to CoreAudio
    _Atomic uint32_t anchorSeq;             // seqlock: odd while gsrd updates the anchor
    uint32_t pad0;
    uint64_t anchorFrame;                   // sample time at anchorHost
    uint64_t anchorHost;                    // mach_absolute_time
    double hostTicksPerFrame;               // measured, includes the card clock error
    _Atomic uint64_t inWritten;             // frames captured since generation start
    _Atomic uint64_t outRead;               // frames fed to the card (informational)
    _Atomic uint64_t outWritten;            // highest output frame written by the plug-in + 1
    _Atomic uint32_t ioClients;             // number of running IO clients (plug-in increments in StartIO)
    _Atomic uint32_t namesRevision;         // bumped by gsrd when the channel names change; the plug-in tells CoreAudio
    _Atomic uint64_t inLate, outLate;       // counters: input frames missing at read time, output frames missing at play time
    char nameIn[GSR_MAX_CH][GSR_NAME_LEN];  // channel names (card to host)
    char nameOut[GSR_MAX_CH][GSR_NAME_LEN]; // channel names (host to card)
    uint64_t inOffset, outOffset;           // byte offsets of the rings from the start of the region
    uint64_t totalBytes;
} GsrRingHeader;

static inline uint64_t gsr_ring_bytes(uint32_t ringFrames) {
    return 4096 + 2ull * ringFrames * GSR_MAX_CH * sizeof(float);
}

static inline float *gsr_in_ring(GsrRingHeader *h) { return (float *)((char *)h + h->inOffset); }
static inline float *gsr_out_ring(GsrRingHeader *h) { return (float *)((char *)h + h->outOffset); }

// Producer side: publish a clock anchor.
static inline void gsr_anchor_write(GsrRingHeader *h, uint64_t frame, uint64_t host, double ticksPerFrame) {
    uint32_t s = atomic_load_explicit(&h->anchorSeq, memory_order_relaxed);
    atomic_store_explicit(&h->anchorSeq, s + 1, memory_order_release);
    h->anchorFrame = frame; h->anchorHost = host; h->hostTicksPerFrame = ticksPerFrame;
    atomic_store_explicit(&h->anchorSeq, s + 2, memory_order_release);
}

// Consumer side: consistent read of the anchor. Returns 0 if no anchor yet.
static inline int gsr_anchor_read(GsrRingHeader *h, uint64_t *frame, uint64_t *host, double *tpf) {
    for (int i = 0; i < 8; i++) {
        uint32_t s0 = atomic_load_explicit(&h->anchorSeq, memory_order_acquire);
        if (s0 & 1) continue;
        uint64_t f = h->anchorFrame, t = h->anchorHost; double p = h->hostTicksPerFrame;
        if (atomic_load_explicit(&h->anchorSeq, memory_order_acquire) == s0) { *frame = f; *host = t; *tpf = p; return s0 != 0 && p > 0; }
    }
    return 0;
}

#endif
