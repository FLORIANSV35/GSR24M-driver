#include "CGSRRing.h"
#include "../../../hal/gsr_ring.h"
#include <string.h>

static const GsrRingHeader *H(const void *r) { return (const GsrRingHeader *)r; }

int gsrv_ok(const void *region, size_t bytes) {
    if (!region || bytes < sizeof(GsrRingHeader)) return 0;
    const GsrRingHeader *h = H(region);
    if (h->magic != GSR_RING_MAGIC || h->version != GSR_RING_VERSION) return 0;
    if (!h->ringFrames || (h->ringFrames & (h->ringFrames - 1))) return 0;
    if (h->channelsIn > GSR_MAX_CH || h->channelsOut > GSR_MAX_CH) return 0;
    return h->totalBytes <= bytes && h->totalBytes >= gsr_ring_bytes(h->ringFrames) && h->inOffset < bytes && h->outOffset < bytes;
}
uint32_t gsrv_generation(const void *r) { return atomic_load_explicit(&H(r)->generation, memory_order_relaxed); }
uint32_t gsrv_state(const void *r) { return atomic_load_explicit(&H(r)->state, memory_order_relaxed); }
uint32_t gsrv_rate(const void *r) { return atomic_load_explicit(&H(r)->sampleRate, memory_order_relaxed); }
uint32_t gsrv_ring_frames(const void *r) { return H(r)->ringFrames; }
uint32_t gsrv_channels_in(const void *r) { return H(r)->channelsIn; }
uint32_t gsrv_channels_out(const void *r) { return H(r)->channelsOut; }
uint64_t gsrv_in_written(const void *r) { return atomic_load_explicit(&H(r)->inWritten, memory_order_acquire); }
uint64_t gsrv_out_written(const void *r) { return atomic_load_explicit(&H(r)->outWritten, memory_order_acquire); }

uint32_t gsrv_copy(const void *region, int out, unsigned ch, uint64_t from, uint32_t frames, float *dst) {
    const GsrRingHeader *h = H(region);
    if (ch >= GSR_MAX_CH || !frames) { if (dst) memset(dst, 0, frames * sizeof(float)); return 0; }
    const float *ring = out ? (const float *)((const char *)region + h->outOffset) : (const float *)((const char *)region + h->inOffset);
    uint64_t written = out ? gsrv_out_written(region) : gsrv_in_written(region);
    uint64_t mask = h->ringFrames - 1;
    uint32_t valid = 0;
    for (uint32_t i = 0; i < frames; i++) {
        uint64_t s = from + i;
        if (s < written && s + h->ringFrames > written) { dst[i] = ring[(s & mask) * GSR_MAX_CH + ch]; valid++; }
        else dst[i] = 0.0f;
    }
    // the writer may have lapped part of what was just read: what is not certain any more is dropped
    uint64_t again = out ? gsrv_out_written(region) : gsrv_in_written(region);
    if (again != written)
        for (uint32_t i = 0; i < frames; i++) if (from + i + h->ringFrames <= again && dst[i] != 0.0f) { dst[i] = 0.0f; valid--; }
    return valid;
}

void gsrv_name(const void *region, int out, unsigned ch, char *dst, size_t cap) {
    if (!cap) return;
    dst[0] = 0;
    if (ch >= GSR_MAX_CH) return;
    const char *n = out ? H(region)->nameOut[ch] : H(region)->nameIn[ch];
    size_t k = 0;
    while (k < GSR_NAME_LEN && k + 1 < cap && n[k]) { dst[k] = n[k]; k++; }
    dst[k] = 0;
}

size_t gsrv_ring_bytes_for(uint32_t ringFrames) { return (size_t)gsr_ring_bytes(ringFrames); }

void gsrv_format(void *region, uint32_t ringFrames, uint32_t rate) {
    GsrRingHeader *h = (GsrRingHeader *)region;
    memset(region, 0, (size_t)gsr_ring_bytes(ringFrames));
    h->magic = GSR_RING_MAGIC; h->version = GSR_RING_VERSION; h->ringFrames = ringFrames;
    h->channelsIn = GSR_MAX_CH; h->channelsOut = GSR_MAX_CH;
    atomic_store(&h->sampleRate, rate); atomic_store(&h->state, GSR_STATE_STREAMING); atomic_store(&h->generation, 1);
    uint64_t one = (uint64_t)ringFrames * GSR_MAX_CH * sizeof(float);
    h->inOffset = 4096; h->outOffset = 4096 + one; h->totalBytes = 4096 + 2 * one;
}
void gsrv_test_write(void *region, int out, unsigned ch, uint64_t frame, float value) {
    GsrRingHeader *h = (GsrRingHeader *)region;
    float *ring = (float *)((char *)region + (out ? h->outOffset : h->inOffset));
    ring[(frame & (h->ringFrames - 1)) * GSR_MAX_CH + ch] = value;
}
void gsrv_test_set_written(void *region, uint64_t inWritten, uint64_t outWritten) {
    GsrRingHeader *h = (GsrRingHeader *)region;
    atomic_store(&h->inWritten, inWritten); atomic_store(&h->outWritten, outWritten);
}
