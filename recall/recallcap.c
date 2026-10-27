// recallcap: plays periodic pink noise (a different noise per channel) into chosen card return channels and records the 32 card sends.
// Used to measure the EQ curve of console channels set to A+B (return before the insert, send after the EQ): see docs/RECALL.md.
// It goes through the CoreAudio device "GS-R24M FireWire" (gsrd and the plug-in must be running; no other application using the device).
//
//   recallcap BASE --ch 1,2,3 [--level -36] [--seconds 14] [--confirmed]
//   without --confirmed it only prints the checklist and exits (nothing is played).
//
// Writes BASE.in.f32 (frames x 32 float32), BASE.x.f32 (one noise period per channel), BASE.json. Analysis: recall/analyze.py.

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CH 32
#define L 65536

static Float64 gRate = 48000;
static int gNCh, gChan[CH];
static float *gNoise[CH];               // one period each
static float gAmp;
static float *gIn; static size_t gInCap, gInFrames;
static double gFirstOut = -1, gFirstIn = -1;
static uint64_t gOutFrames, gTotalOut;

static void fft(double *re, double *im, int n, int inv) {
    for (int i = 1, j = 0; i < n; i++) { int bit = n >> 1; for (; j & bit; bit >>= 1) j ^= bit; j ^= bit; if (i < j) { double t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; } }
    for (int len = 2; len <= n; len <<= 1) {
        double ang = 2 * M_PI / len * (inv ? 1 : -1), wr = cos(ang), wi = sin(ang);
        for (int i = 0; i < n; i += len) {
            double cr = 1, ci = 0;
            for (int k = 0; k < len / 2; k++) {
                int a = i + k, b = i + k + len / 2;
                double xr = re[b] * cr - im[b] * ci, xi = re[b] * ci + im[b] * cr;
                re[b] = re[a] - xr; im[b] = im[a] - xi; re[a] += xr; im[a] += xi;
                double t = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = t;
            }
        }
    }
}
static uint64_t rng(uint64_t *s) { *s ^= *s << 13; *s ^= *s >> 7; *s ^= *s << 17; return *s; }

// Periodic pink noise: random phases, amplitude proportional to 1/sqrt(f) between 10 Hz and 0.45 fs, rms normalised to 1.
static float *makeNoise(unsigned seed, double rate) {
    double *re = calloc(L, sizeof(double)), *im = calloc(L, sizeof(double));
    uint64_t s = 0x9E3779B97F4A7C15ull * (seed + 1) + 12345;
    for (int k = 1; k < L / 2; k++) {
        double f = rate * k / L;
        if (f < 10 || f > 0.45 * rate) continue;
        double ph = 2 * M_PI * ((double)(rng(&s) >> 11) / 9007199254740992.0), a = pow(f, -0.5);
        re[k] = a * cos(ph); im[k] = a * sin(ph); re[L - k] = re[k]; im[L - k] = -im[k];
    }
    fft(re, im, L, 1);
    double s2 = 0; for (int i = 0; i < L; i++) s2 += re[i] * re[i];
    double g = 1.0 / sqrt(s2 / L);
    float *o = malloc(L * sizeof(float));
    for (int i = 0; i < L; i++) o[i] = (float)(re[i] * g);
    free(re); free(im);
    return o;
}

static OSStatus ioProc(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *inT, AudioBufferList *out, const AudioTimeStamp *outT, void *cl) {
    (void)dev; (void)now; (void)cl;
    if (in && in->mNumberBuffers) {
        UInt32 n = in->mBuffers[0].mDataByteSize / (CH * sizeof(float));
        if (gFirstIn < 0) gFirstIn = inT->mSampleTime;
        if (gInFrames + n <= gInCap) { memcpy(gIn + gInFrames * CH, in->mBuffers[0].mData, (size_t)n * CH * sizeof(float)); gInFrames += n; }
    }
    if (out && out->mNumberBuffers) {
        UInt32 n = out->mBuffers[0].mDataByteSize / (CH * sizeof(float));
        float *o = out->mBuffers[0].mData;
        memset(o, 0, out->mBuffers[0].mDataByteSize);
        if (gFirstOut < 0) gFirstOut = outT->mSampleTime;
        double fade = 0.5 * gRate;
        for (UInt32 i = 0; i < n; i++) {
            int64_t S = (int64_t)(outT->mSampleTime + i);
            double t = (double)gOutFrames, env = 1.0;
            if (t < fade) env = t / fade;
            if (t > (double)gTotalOut - fade) env = fmax(0.0, ((double)gTotalOut - t) / fade);
            gOutFrames++;
            if (env <= 0 || gOutFrames > gTotalOut) continue;
            int idx = (int)(((S % L) + L) % L);
            for (int c = 0; c < gNCh; c++) o[i * CH + gChan[c] - 1] = (float)(gAmp * env) * gNoise[c][idx];
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

static void checklist(void) {
    printf("Checklist before any sound (EQ capture):\n"
           "  1. Unplug the inserts.\n"
           "  2. Switch OFF the monitors and the headphones.\n"
           "  3. Press A and B on the channels to measure (return before the insert, send after the EQ).\n"
           "  4. Nothing else may use the GS-R24M device.\n"
           "Add --confirmed to start. The noise reaches every bus the channel feeds (main, aux, groups).\n");
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: recallcap BASE --ch 1,2,3 [--level -36] [--seconds 14] [--confirmed]\n"); return 2; }
    const char *base = argv[1]; double level = -36, secs = 14; int confirmed = 0;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--ch") && i + 1 < argc) { char *p = strtok(argv[++i], ","); while (p && gNCh < CH) { int c = atoi(p); if (c >= 1 && c <= 24) gChan[gNCh++] = c; p = strtok(NULL, ","); } }
        else if (!strcmp(argv[i], "--level") && i + 1 < argc) level = atof(argv[++i]);
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) secs = atof(argv[++i]);
        else if (!strcmp(argv[i], "--confirmed")) confirmed = 1;
    }
    if (gNCh == 0) { fprintf(stderr, "no channel given (--ch 1,2,...; channels 1 to 24)\n"); return 2; }
    if (level > -20) level = -20;                                  // never louder than -20 dBFS rms
    if (secs < 8) secs = 8; if (secs > 60) secs = 60;
    if (!confirmed) { checklist(); return 0; }
    AudioDeviceID dev = findByName("GS-R24M FireWire");
    if (!dev) { fprintf(stderr, "device 'GS-R24M FireWire' not found (is gsrd running and the plug-in installed?)\n"); return 1; }
    AudioObjectPropertyAddress ra = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 sz = sizeof gRate; AudioObjectGetPropertyData(dev, &ra, 0, NULL, &sz, &gRate);
    AudioObjectPropertyAddress ba = { kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 bf = 512; AudioObjectSetPropertyData(dev, &ba, 0, NULL, sizeof bf, &bf);
    gAmp = (float)pow(10.0, level / 20.0);
    for (int c = 0; c < gNCh; c++) gNoise[c] = makeNoise((unsigned)gChan[c], gRate);
    gTotalOut = (uint64_t)(secs * gRate);
    gInCap = (size_t)((secs + 3) * gRate); gIn = calloc(gInCap * CH, sizeof(float));
    printf("playing pink noise at %.0f dBFS rms on channels", level); for (int c = 0; c < gNCh; c++) printf(" %d", gChan[c]); printf(", %.0f Hz, %.0f s\n", gRate, secs);
    AudioDeviceIOProcID pid;
    if (AudioDeviceCreateIOProcID(dev, ioProc, NULL, &pid) != noErr || AudioDeviceStart(dev, pid) != noErr) { fprintf(stderr, "could not start the device\n"); return 1; }
    sleep((unsigned)secs + 2);
    AudioDeviceStop(dev, pid); AudioDeviceDestroyIOProcID(dev, pid);
    char path[512];
    snprintf(path, sizeof path, "%s.in.f32", base); FILE *f = fopen(path, "wb"); fwrite(gIn, sizeof(float), gInFrames * CH, f); fclose(f);
    snprintf(path, sizeof path, "%s.x.f32", base); f = fopen(path, "wb"); for (int c = 0; c < gNCh; c++) fwrite(gNoise[c], sizeof(float), L, f); fclose(f);
    snprintf(path, sizeof path, "%s.json", base); f = fopen(path, "w");
    fprintf(f, "{\"rate\":%.0f,\"L\":%d,\"level\":%.1f,\"frames\":%zu,\"channels\":[", gRate, L, level, gInFrames);
    for (int c = 0; c < gNCh; c++) fprintf(f, "%s%d", c ? "," : "", gChan[c]);
    fprintf(f, "]}\n"); fclose(f);
    printf("recorded %zu frames -> %s.*\n", gInFrames, base);
    return 0;
}
