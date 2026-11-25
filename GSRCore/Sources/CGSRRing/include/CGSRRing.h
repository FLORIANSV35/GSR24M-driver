// Read access to the shared ring between gsrd and the HAL plug-in (hal/gsr_ring.h), for Swift: plain functions, no _Atomic types in the interface.
// The layout comes from the same header the daemon and the plug-in are built with, through shim.c.
#ifndef CGSRRING_H
#define CGSRRING_H
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 1 when the region is a ring this code understands (magic, version, size).
int gsrv_ok(const void *region, size_t bytes);
uint32_t gsrv_generation(const void *region);
uint32_t gsrv_state(const void *region);          // 0 down, 1 idle, 2 streaming
uint32_t gsrv_rate(const void *region);
uint32_t gsrv_ring_frames(const void *region);
uint32_t gsrv_channels_in(const void *region);
uint32_t gsrv_channels_out(const void *region);
uint64_t gsrv_in_written(const void *region);     // capture frames since the stream started
uint64_t gsrv_out_written(const void *region);    // highest playback frame written by the plug-in, plus 1
/// Copies `frames` frames of channel `ch` of the capture ring (out = 0) or of the playback ring (out = 1), starting at card frame `from`, into `dst`.
/// Returns the number of frames that were valid (the others are set to 0): for the capture ring a frame is valid when from + i < inWritten and not older
/// than one ring; for the playback ring when it was written and not overwritten.
uint32_t gsrv_copy(const void *region, int out, unsigned ch, uint64_t from, uint32_t frames, float *dst);
/// The channel name the daemon published ("" when none); at most 32 bytes plus the terminator.
void gsrv_name(const void *region, int out, unsigned ch, char *dst, size_t cap);

/// Test helper: formats a region of `bytes` bytes (as gsrd does) and sets the sample rate.
size_t gsrv_ring_bytes_for(uint32_t ringFrames);
void gsrv_format(void *region, uint32_t ringFrames, uint32_t rate);
void gsrv_test_write(void *region, int out, unsigned ch, uint64_t frame, float value);
void gsrv_test_set_written(void *region, uint64_t inWritten, uint64_t outWritten);

#ifdef __cplusplus
}
#endif
#endif
