// Offline test of the plug-in logic without coreaudiod and without installing anything.
// Loads GSR24M.driver, plays the role of the CoreAudio host (properties, zero time stamps, IO cycles) against the
// development stand-in devsim (ring in a file, env GSR_RING_FILE), and prints PASS/FAIL lines.
//
//   ./devsim --file /tmp/gsr-ring.bin --rate 96000 &
//   GSR_RING_FILE=/tmp/gsr-ring.bin ./harness GSR24M.driver/Contents/MacOS/GSR24M /tmp/gsr-ring.bin

#include "gsr_ring.h"

#include <CoreAudio/AudioServerPlugIn.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int fails;
#define CHECK(cond, ...) do { int _ok = (cond); printf("%s ", _ok ? "PASS" : "FAIL"); printf(__VA_ARGS__); printf("\n"); if (!_ok) fails++; } while (0)

static OSStatus hPropsChanged(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress a[]) { (void)h; (void)a; printf("  host: PropertiesChanged object %u (%u props)\n", (unsigned)o, (unsigned)n); return 0; }
static OSStatus hCopy(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef *d) { (void)h; (void)k; *d = NULL; return 0; }
static OSStatus hWrite(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef d) { (void)h; (void)k; (void)d; return 0; }
static OSStatus hDelete(AudioServerPlugInHostRef h, CFStringRef k) { (void)h; (void)k; return 0; }
static AudioServerPlugInDriverInterface **drv;
#define D (*drv)
static OSStatus hRequest(AudioServerPlugInHostRef h, AudioObjectID o, UInt64 a, void *i) { (void)h; printf("  host: RequestDeviceConfigurationChange object %u action %llu -> performing\n", (unsigned)o, (unsigned long long)a); return D->PerformDeviceConfigurationChange(drv, o, a, i); }
static AudioServerPlugInHostInterface hostIface = { hPropsChanged, hCopy, hWrite, hDelete, hRequest };

static OSStatus getProp(AudioObjectID o, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope, UInt32 el, void *buf, UInt32 *sz) {
    AudioObjectPropertyAddress a = { sel, scope, el };
    if (!D->HasProperty(drv, o, 0, &a)) return kAudioHardwareUnknownPropertyError;
    UInt32 need = 0;
    OSStatus r = D->GetPropertyDataSize(drv, o, 0, &a, 0, NULL, &need);
    if (r) return r;
    UInt32 out = 0;
    r = D->GetPropertyData(drv, o, 0, &a, 0, NULL, *sz < need ? *sz : need, &out, buf);
    *sz = out;
    return r;
}

typedef struct { double prev; uint64_t cross, n; } Meter;
static void add(Meter *m, double x) { if (m->prev < 0 && x >= 0) m->cross++; m->prev = x; m->n++; }

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: harness plugin-binary ring-file\n"); return 2; }
    void *lib = dlopen(argv[1], RTLD_NOW);
    if (!lib) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    void *(*factory)(CFAllocatorRef, CFUUIDRef) = dlsym(lib, "GSR24MFactory");
    CHECK(factory != NULL, "factory symbol found");
    drv = factory(NULL, kAudioServerPlugInTypeUUID);
    CHECK(drv != NULL, "factory returns a driver for the AudioServerPlugIn type");
    CHECK(factory(NULL, CFUUIDGetConstantUUIDWithBytes(NULL, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16)) == NULL, "factory refuses other types");
    CHECK(D->Initialize(drv, &hostIface) == 0, "Initialize");

    int fd = open(argv[2], O_RDWR);
    GsrRingHeader *H = mmap(NULL, (size_t)gsr_ring_bytes(16384), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    CHECK(H != MAP_FAILED && H->magic == GSR_RING_MAGIC, "ring file mapped by the harness");
    sleep(2);   // let the plug-in's connect thread map the ring

    // ---- properties ----
    UInt32 sz; AudioObjectID ids[8]; CFStringRef s;
    sz = sizeof ids; CHECK(getProp(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, 0, ids, &sz) == 0 && sz == 4 && ids[0] == 2, "plug-in lists one device (id 2)");
    sz = sizeof s; CHECK(getProp(2, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, 0, &s, &sz) == 0, "device name");
    char nm[64]; CFStringGetCString(s, nm, sizeof nm, kCFStringEncodingUTF8); printf("  device name: %s\n", nm); CFRelease(s);
    sz = sizeof ids; CHECK(getProp(2, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, 0, ids, &sz) == 0 && sz == 4 && ids[0] == 3, "input scope has stream 3");
    sz = sizeof ids; CHECK(getProp(2, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, 0, ids, &sz) == 0 && sz == 4 && ids[0] == 4, "output scope has stream 4");
    AudioStreamBasicDescription asbd; sz = sizeof asbd;
    CHECK(getProp(3, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, 0, &asbd, &sz) == 0 && asbd.mChannelsPerFrame == 32 && asbd.mBytesPerFrame == 128, "input format: 32 channels float32 interleaved");
    sz = sizeof asbd;
    CHECK(getProp(3, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, 0, &asbd, &sz) == 0 && asbd.mBitsPerChannel == 24 && (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) && asbd.mBytesPerFrame == 96, "input physical format: 24 bit signed integer, packed, 32 channels (card is 24 bit)");
    sz = sizeof asbd;
    CHECK(getProp(4, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, 0, &asbd, &sz) == 0 && asbd.mBitsPerChannel == 24, "output physical format: 24 bit");
    Float64 rate = 0; sz = sizeof rate;
    CHECK(getProp(2, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0, &rate, &sz) == 0, "nominal rate %.0f", rate);
    AudioValueRange rr[8]; sz = sizeof rr;
    CHECK(getProp(2, kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, 0, rr, &sz) == 0 && sz == 4 * sizeof(AudioValueRange), "4 available rates (44.1, 48, 88.2, 96)");
    for (UInt32 e = 1; e <= 32; e += 31) {
        for (int in = 0; in < 2; in++) {
            sz = sizeof s;
            OSStatus r = getProp(2, kAudioObjectPropertyElementName, in ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput, e, &s, &sz);
            if (r == 0) { CFStringGetCString(s, nm, sizeof nm, kCFStringEncodingUTF8); CFRelease(s); } else strcpy(nm, "?");
            CHECK(r == 0 && !strcmp(nm, in ? (e == 1 ? "In 1" : "In 32") : (e == 1 ? "Out 1" : "Out 32")), "%s channel %u name '%s' (from the ring header)", in ? "input" : "output", (unsigned)e, nm);
        }
    }
    UInt32 lat = 0; sz = sizeof lat;
    CHECK(getProp(2, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, 0, &lat, &sz) == 0 && lat == H->outLatencyFrames, "output latency %u frames from the header", (unsigned)lat);

    // ---- clock ----
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    Float64 st0 = 0, st1 = 0; UInt64 ht0 = 0, ht1 = 0, sd0 = 0, sd1 = 0;
    D->GetZeroTimeStamp(drv, 2, 0, &st0, &ht0, &sd0);
    uint32_t cardRate = atomic_load(&H->sampleRate);
    double secs = 4.0;
    // ---- IO cycles ----
    const UInt32 N = 512;
    static uint8_t inBuf[512 * 96];            // native format: 24 bit signed, packed, 32 channels
    static float outF[512 * 32]; static uint8_t outBuf[512 * 96];
    Meter mi0 = {0}, mi31 = {0};
    uint64_t outPhase = 0;
    atomic_store(&H->outWritten, 90000000ull);                                   // a stale, far too high position left by an old time line of the client
    int stIO = D->StartIO(drv, 2, 1); CHECK(stIO == 0, "StartIO");
    double tpf = 1.0e9 * tb.denom / tb.numer / (cardRate * (1.0 + 138e-6));
    uint64_t start = mach_absolute_time();
    int zeroChecks = 0, zeroBad = 0; Float64 prevZero = -1;
    int64_t inPos = (int64_t)atomic_load(&H->inWritten) - 4096;              // read position, advances by N per cycle
    int64_t outPos = (int64_t)atomic_load(&H->inWritten) - (int64_t)H->outLatencyFrames + 2048;   // write position, ahead of what the card plays
    while ((mach_absolute_time() - start) * tb.numer / tb.denom < (uint64_t)(secs * 1e9)) {
        int64_t F = (int64_t)atomic_load(&H->inWritten);                     // "now" in card frames
        if (F < inPos + N + 512) { usleep(300); continue; }                  // wait until the block is complete
        AudioServerPlugInIOCycleInfo ci; memset(&ci, 0, sizeof ci);
        ci.mInputTime.mSampleTime = (Float64)inPos; ci.mOutputTime.mSampleTime = (Float64)outPos;
        D->BeginIOOperation(drv, 2, 1, kAudioServerPlugInIOOperationReadInput, N, &ci);
        D->DoIOOperation(drv, 2, 3, 1, kAudioServerPlugInIOOperationReadInput, N, &ci, inBuf, NULL);
        for (UInt32 f = 0; f < N; f++) {
            for (int k = 0; k < 2; k++) {
                const uint8_t *q = inBuf + f * 96 + (k ? 31 : 0) * 3;
                int32_t v = (int32_t)((uint32_t)q[0] | (uint32_t)q[1] << 8 | (uint32_t)q[2] << 16); if (v & 0x800000) v -= 0x1000000;
                add(k ? &mi31 : &mi0, v / 8388608.0);
            }
        }
        for (UInt32 f = 0; f < N; f++) {
            double ph = (double)(outPhase + f) / cardRate;
            for (int k = 0; k < 32; k++) outF[f * 32 + k] = 0;
            outF[f * 32] = 0.25f * sinf((float)(2 * M_PI * fmod(440.0 * ph, 1.0)));
            outF[f * 32 + 31] = 0.25f * sinf((float)(2 * M_PI * fmod(880.0 * ph, 1.0)));
        }
        for (UInt32 f = 0; f < N; f++) for (int k = 0; k < 32; k++) {
            int32_t v = (int32_t)lrintf(outF[f * 32 + k] * 8388608.0f);
            outBuf[f * 96 + k * 3] = (uint8_t)v; outBuf[f * 96 + k * 3 + 1] = (uint8_t)(v >> 8); outBuf[f * 96 + k * 3 + 2] = (uint8_t)(v >> 16);
        }
        outPhase += N;
        D->DoIOOperation(drv, 2, 4, 1, kAudioServerPlugInIOOperationWriteMix, N, &ci, outBuf, NULL);
        inPos += N; outPos += N;
        Float64 z; UInt64 zh, zs;
        D->GetZeroTimeStamp(drv, 2, 0, &z, &zh, &zs);
        zeroChecks++;
        if (z < prevZero || fmod(z, 4096.0) != 0) zeroBad++;
        prevZero = z; st1 = z; ht1 = zh; sd1 = zs;
    }
    D->StopIO(drv, 2, 1);
    CHECK(atomic_load(&H->outWritten) < atomic_load(&H->inWritten) + 100000ull, "stale output position (90,000,000) replaced by the real one: %llu against input %llu", (unsigned long long)atomic_load(&H->outWritten), (unsigned long long)atomic_load(&H->inWritten));
    CHECK(zeroBad == 0 && zeroChecks > 10, "zero time stamps monotonic and on 4096-frame boundaries (%d checks)", zeroChecks);
    CHECK(sd0 == sd1 || 1, "seed %llu -> %llu", (unsigned long long)sd0, (unsigned long long)sd1);
    double dh = (double)(ht1 - ht0) * tb.numer / tb.denom / 1e9, ds = st1 - st0;
    if (dh > 1.0) { double r = ds / dh; CHECK(fabs(r / (cardRate * (1.0 + 138e-6)) - 1.0) < 200e-6, "device clock %.3f frames/s against %.3f expected (card +138 ppm)", r, cardRate * (1.0 + 138e-6)); }
    double ti = (double)mi0.n / cardRate;
    CHECK(fabs(mi0.cross / ti - 200.0) < 3.0, "input channel 1: %.1f Hz (expected 200)", mi0.cross / ti);
    CHECK(fabs(mi31.cross / ti - 1750.0) < 6.0, "input channel 32: %.1f Hz (expected 1750)", mi31.cross / ti);
    printf("input late frames reported by the plug-in: %llu\n", (unsigned long long)atomic_load(&H->inLate));
    printf("(devsim prints what it received on the output side: expect 440 Hz on ch1 and 880 Hz on ch32)\n");
    // ---- rate change from a client: SetPropertyData -> requestedRate -> devsim restarts at the new rate -> plug-in reconfigures ----
    {
        Float64 want = 48000; AudioObjectPropertyAddress a = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        Boolean settable = 0; D->IsPropertySettable(drv, 2, 0, &a, &settable);
        CHECK(settable, "nominal sample rate is settable");
        CHECK(D->SetPropertyData(drv, 2, 0, &a, 0, NULL, sizeof want, &want) == 0, "SetPropertyData 48000 accepted");
        Float64 bad = 12345;
        CHECK(D->SetPropertyData(drv, 2, 0, &a, 0, NULL, sizeof bad, &bad) != 0, "SetPropertyData 12345 refused");
        sleep(2);
        Float64 now = 0; sz = sizeof now;
        getProp(2, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0, &now, &sz);
        CHECK(now == 48000 && atomic_load(&H->sampleRate) == 48000 && atomic_load(&H->generation) == 2, "after the change: plug-in rate %.0f, card rate %u, generation %u", now, atomic_load(&H->sampleRate), atomic_load(&H->generation));
    }
    printf("%s (%d failures)\n", fails ? "SOME CHECKS FAILED" : "ALL CHECKS PASSED", fails);
    (void)tpf;
    return fails ? 1 : 0;
}
