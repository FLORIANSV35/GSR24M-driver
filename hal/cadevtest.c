// Native CoreAudio test of the GS-R24M device, the way a DAW would use it (IOProc on the device).
// Input: every callback is compared frame by frame with what devsim writes (channel k = 0.1 sin(2 pi (200 + 50 k) S / rate),
//        S = card frame = CoreAudio sample time). Output: 440 Hz on channel 1 and 880 Hz on channel 32, phase from the sample time.
// Test code. Needs the devsim install (hal/install.sh).
//
//   ./cadevtest [seconds] [rate] [buffer frames]
//   ./cadevtest --set-default-output "MiniFuse 2"     put the default output device back (name as shown in Audio MIDI Setup)

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CH 32
#define MAX_BLOCKS 20000

static AudioDeviceID gDev;
static Float64 gRate = 48000;
static float *gIn; static size_t gInCap, gInFrames;
static Float64 gBlockS[MAX_BLOCKS]; static UInt32 gBlockN[MAX_BLOCKS]; static size_t gBlocks;
static Float64 gOutFirst = -1, gOutLast; static UInt32 gOutBlocks, gOutJumps;

static int gLoop, gReal, gNoOut;
static uint32_t noiseAt(int64_t S) { uint64_t x = (uint64_t)S * 0x9E3779B97F4A7C15ull; x ^= x >> 29; x *= 0xBF58476D1CE4E5B9ull; x ^= x >> 32; return (uint32_t)x; }
static float noiseSample(int64_t S) { return ((float)(noiseAt(S) >> 8) / 8388608.0f - 1.0f) * 0.1f; }
static OSStatus ioProc(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *inT, AudioBufferList *out, const AudioTimeStamp *outT, void *cl) {
    (void)dev; (void)now; (void)cl;
    if (in && in->mNumberBuffers && gBlocks < MAX_BLOCKS) {
        UInt32 n = in->mBuffers[0].mDataByteSize / (CH * sizeof(float));
        if (gInFrames + n <= gInCap) {
            memcpy(gIn + gInFrames * CH, in->mBuffers[0].mData, (size_t)n * CH * sizeof(float));
            gBlockS[gBlocks] = inT->mSampleTime; gBlockN[gBlocks] = n; gBlocks++; gInFrames += n;
        }
    }
    if (out && out->mNumberBuffers) {
        UInt32 n = out->mBuffers[0].mDataByteSize / (CH * sizeof(float));
        float *o = out->mBuffers[0].mData;
        memset(o, 0, out->mBuffers[0].mDataByteSize);
        Float64 s0 = outT->mSampleTime;
        if (gNoOut) { gOutBlocks++; return noErr; }
        if (gOutFirst >= 0 && s0 != gOutLast) gOutJumps++;
        if (gOutFirst < 0) gOutFirst = s0;
        gOutLast = s0 + n; gOutBlocks++;
        for (UInt32 i = 0; i < n; i++) {
            Float64 t = (s0 + i) / gRate;
            if (gLoop) { o[i * CH + 0] = noiseSample((int64_t)(s0 + i)); continue; }
            o[i * CH + 0] = 0.25f * sinf((float)(2 * M_PI * fmod(440.0 * t, 1.0)));
            o[i * CH + 31] = 0.25f * sinf((float)(2 * M_PI * fmod(880.0 * t, 1.0)));
        }
    }
    return noErr;
}

static AudioDeviceID findByName(const char *name) {
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 sz = 0; AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz);
    AudioDeviceID *ids = malloc(sz); AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids);
    AudioDeviceID found = 0;
    for (UInt32 i = 0; i < sz / sizeof *ids; i++) {
        AudioObjectPropertyAddress n = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        CFStringRef s = NULL; UInt32 ns = sizeof s;
        if (AudioObjectGetPropertyData(ids[i], &n, 0, NULL, &ns, &s) == noErr && s) {
            char buf[128]; CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(s);
            if (!strcmp(buf, name)) found = ids[i];
        }
    }
    free(ids);
    return found;
}

int main(int argc, char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "--names")) {
        AudioDeviceID d = findByName("GS-R24M FireWire");
        if (!d) { fprintf(stderr, "device 'GS-R24M FireWire' not found\n"); return 1; }
        const int els[] = {1, 2, 3, 16, 17, 31, 32};
        for (int dir = 0; dir < 2; dir++) {
            printf("%s:", dir ? "output" : "input");
            for (unsigned e = 0; e < sizeof els / sizeof els[0]; e++) {
                AudioObjectPropertyAddress a = { kAudioObjectPropertyElementName, dir ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput, (UInt32)els[e] };
                CFStringRef str = NULL; UInt32 sz = sizeof str; char buf[64] = "?";
                if (AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &str) == noErr && str) { CFStringGetCString(str, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(str); }
                printf("  %d='%s'", els[e], buf);
            }
            printf("\n");
        }
        return 0;
    }
    if (argc >= 3 && !strcmp(argv[1], "--set-default-output")) {
        AudioDeviceID d = findByName(argv[2]);
        if (!d) { fprintf(stderr, "device '%s' not found\n", argv[2]); return 1; }
        AudioObjectPropertyAddress a = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        OSStatus r = AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, sizeof d, &d);
        printf("default output -> %s: %s\n", argv[2], r == noErr ? "done" : "failed");
        return r != noErr;
    }
    if (argc >= 2 && !strcmp(argv[1], "--rec")) { gReal = 1; gNoOut = 1; for (int k = 1; k < argc - 1; k++) argv[k] = argv[k + 1]; argc--; }
    if (argc >= 2 && !strcmp(argv[1], "--real")) { gReal = 1; for (int k = 1; k < argc - 1; k++) argv[k] = argv[k + 1]; argc--; }
    if (argc >= 2 && !strcmp(argv[1], "--loopback")) { gLoop = 1; for (int k = 1; k < argc - 1; k++) argv[k] = argv[k + 1]; argc--; }
    double secs = argc > 1 ? atof(argv[1]) : 6; UInt32 want = argc > 2 ? (UInt32)atoi(argv[2]) : 0; UInt32 bufFrames = argc > 3 ? (UInt32)atoi(argv[3]) : 256;
    gDev = findByName("GS-R24M FireWire");
    if (!gDev) { fprintf(stderr, "device 'GS-R24M FireWire' not found\n"); return 1; }
    if (want) {
        Float64 r = want; AudioObjectPropertyAddress a = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        OSStatus e = AudioObjectSetPropertyData(gDev, &a, 0, NULL, sizeof r, &r);
        printf("set rate %u: %d\n", want, (int)e); sleep(3);
    }
    AudioObjectPropertyAddress ra = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 sz = sizeof gRate; AudioObjectGetPropertyData(gDev, &ra, 0, NULL, &sz, &gRate);
    AudioObjectPropertyAddress ba = { kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectSetPropertyData(gDev, &ba, 0, NULL, sizeof bufFrames, &bufFrames);
    UInt32 bf = 0; sz = sizeof bf; AudioObjectGetPropertyData(gDev, &ba, 0, NULL, &sz, &bf);
    UInt32 lat[2] = {0, 0}, saf[2] = {0, 0};
    AudioObjectPropertyAddress la = { kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain }, sa = { kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain };
    sz = 4; AudioObjectGetPropertyData(gDev, &la, 0, NULL, &sz, &lat[0]); AudioObjectGetPropertyData(gDev, &sa, 0, NULL, &sz, &saf[0]);
    la.mScope = sa.mScope = kAudioObjectPropertyScopeOutput;
    AudioObjectGetPropertyData(gDev, &la, 0, NULL, &sz, &lat[1]); AudioObjectGetPropertyData(gDev, &sa, 0, NULL, &sz, &saf[1]);
    printf("device rate %.0f, IO buffer %u frames, latency in/out %u/%u, safety in/out %u/%u\n", gRate, bf, lat[0], lat[1], saf[0], saf[1]);

    gInCap = (size_t)((secs + 2) * gRate); gIn = calloc(gInCap * CH, sizeof(float));
    AudioDeviceIOProcID pid;
    if (AudioDeviceCreateIOProcID(gDev, ioProc, NULL, &pid) != noErr) { fprintf(stderr, "no IOProc\n"); return 1; }
    if (AudioDeviceStart(gDev, pid) != noErr) { fprintf(stderr, "start failed\n"); return 1; }
    sleep((unsigned)secs);
    AudioDeviceStop(gDev, pid); AudioDeviceDestroyIOProcID(gDev, pid);

    if (gReal) {
        // Real card: level and frequency (rising zero crossings) of every input channel over the last second, and sample time continuity.
        size_t from = gInFrames > (size_t)gRate ? gInFrames - (size_t)gRate : 0; unsigned jumps2 = 0; Float64 pe = -1;
        for (size_t b = 0; b < gBlocks; b++) { if (pe >= 0 && gBlockS[b] != pe) { if (jumps2 < 12) printf("  jump at callback %zu: expected %.0f, got %.0f (%+.0f frames)\n", b, pe, gBlockS[b], gBlockS[b] - pe); jumps2++; } pe = gBlockS[b] + gBlockN[b]; }
        printf("input: %zu callbacks, sample time jumps: %u, output jumps: %u\n", gBlocks, jumps2, gOutJumps);
        for (int k = 0; k < CH; k++) {
            double s2 = 0, prev = 0; unsigned cross = 0; size_t n = gInFrames - from;
            for (size_t i = from; i < gInFrames; i++) { double v = gIn[i * CH + k]; s2 += v * v; if (i > from && prev < 0 && v >= 0) cross++; prev = v; }
            double rms = sqrt(s2 / n);
            if (rms > 3e-5) printf("  input ch%2d: rms %6.1f dBFS, about %7.1f Hz\n", k + 1, 20 * log10(rms), cross * (double)gRate / (double)n);
        }
        if (gNoOut) {
            // Recording of what comes back from the console master (music played by an app): level per 5 s and runs of exact zeros.
            for (int k = 30; k < 32; k++) {
                printf("  input ch%d level per 0.5 s (dBFS rms):", k + 1);
                size_t blk = (size_t)(gRate / 2);
                for (size_t b = (size_t)gRate; b + blk <= gInFrames; b += blk) { double s2 = 0; for (size_t i = b; i < b + blk; i++) { double v = gIn[i * CH + k]; s2 += v * v; } printf(" %.1f", 10 * log10(s2 / blk + 1e-20)); }
                size_t run = 0, longest = 0, runs = 0;
                for (size_t i = (size_t)gRate; i < gInFrames; i++) { if (gIn[i * CH + k] == 0.0f) { run++; } else { if (run >= 24) runs++; if (run > longest) longest = run; run = 0; } }
                printf("\n    runs of at least 24 exact zeros: %zu, longest %zu frames\n", runs, longest);
            }
        }
        return 0;
    }
    if (gLoop) {
        // Round trip: noise written on output channel 1 at sample time S, back from the console master on input channel 31 (and 32).
        // Cross-correlation over lags 0..300 ms using one second of the noise.
        size_t total = gInFrames, seg = (size_t)gRate; if (total < seg + (size_t)(0.4 * gRate) + (size_t)gRate) { printf("recording too short\n"); return 1; }
        // build a contiguous input array with sample times
        Float64 firstS = gBlockS[0];
        size_t maxLag = (size_t)(0.3 * gRate);
        for (int chn = 30; chn <= 31; chn++) {
            double best = 0, bestLag = -1, e2 = 0;
            size_t start = (size_t)(1.0 * gRate);       // skip the first second
            for (size_t i = 0; i < seg; i++) e2 += (double)noiseSample((int64_t)(firstS + start + i)) * noiseSample((int64_t)(firstS + start + i));
            for (size_t lag = 0; lag <= maxLag; lag++) {
                double acc = 0, ein = 0;
                for (size_t i = 0; i < seg; i += 2) { double a = noiseSample((int64_t)(firstS + start + i)), b = gIn[(start + i + lag) * CH + chn]; acc += a * b; ein += b * b; }
                double cc = (e2 > 0 && ein > 0) ? acc / sqrt((e2 / 2) * ein) : 0;
                if (fabs(cc) > fabs(best)) { best = cc; bestLag = (double)lag; }
            }
            printf("loopback: output channel 1 -> input channel %d: best lag %.0f frames (%.2f ms), correlation %.3f\n", chn + 1, bestLag, bestLag / gRate * 1000.0, best);
            printf("   correlation around the peak (lag-3..lag+3):");
            for (int dl = -3; dl <= 3; dl++) {
                size_t lag = (size_t)(bestLag + dl); double acc = 0, ein = 0;
                for (size_t i = 0; i < seg; i += 2) { double a = noiseSample((int64_t)(firstS + start + i)), b = gIn[(start + i + lag) * CH + chn]; acc += a * b; ein += b * b; }
                printf(" %.3f", (e2 > 0 && ein > 0) ? acc / sqrt((e2 / 2) * ein) : 0);
            }
            printf("\n");
        }
        return 0;
    }
    // ---- analysis: skip the first 0.5 s (start-up) ----
    size_t skip = (size_t)(0.5 * gRate), pos = 0; unsigned jumps = 0; Float64 prevEnd = -1;
    double maxErr[CH] = {0}; size_t compared = 0, badFrames = 0;
    for (size_t b = 0; b < gBlocks; b++) {
        if (prevEnd >= 0 && gBlockS[b] != prevEnd) jumps++;
        prevEnd = gBlockS[b] + gBlockN[b];
        for (UInt32 i = 0; i < gBlockN[b]; i++, pos++) {
            if (pos < skip) continue;
            Float64 S = gBlockS[b] + i; int bad = 0;
            for (int k = 0; k < CH; k++) {
                double f = 200.0 + 50.0 * k, want2 = 0.1 * sin(2 * M_PI * fmod(f * S / gRate, 1.0));
                double e = fabs(gIn[pos * CH + k] - want2);
                if (e > maxErr[k]) maxErr[k] = e;
                if (e > 0.002) bad = 1;
            }
            badFrames += bad; compared++;
        }
    }
    double worst = 0; int wk = 0; for (int k = 0; k < CH; k++) if (maxErr[k] > worst) { worst = maxErr[k]; wk = k; }
    printf("input: %zu callbacks, %zu frames compared, sample time jumps between callbacks: %u\n", gBlocks, compared, jumps);
    printf("input: frames with an error above 0.002 (any channel): %zu (%.3f%%); worst error %.5f on channel %d\n", badFrames, compared ? 100.0 * badFrames / compared : 0, worst, wk + 1);
    printf("output: %u callbacks, sample time jumps: %u\n", gOutBlocks, gOutJumps);
    printf("%s\n", (jumps == 0 && badFrames == 0 && gOutJumps == 0 && compared > 0) ? "PASS" : "FAIL");
    return 0;
}
