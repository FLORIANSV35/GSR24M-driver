// GSR24M AudioServerPlugIn. One device, 32 inputs and 32 outputs, float32.
// No FireWire code here: audio and the clock anchor come from gsrd through shared memory (gsr_ring.h).
// If gsrd is absent the device stays alive, runs on a free-running clock at the nominal rate and delivers silence.
//
// Rules for the IO path (GetZeroTimeStamp, DoIOOperation): no locks, no allocation, no sleeping, no logging.

#include "gsr_ring.h"

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <math.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <xpc/xpc.h>

#define LOG(...) do { char _b[300]; snprintf(_b, sizeof _b, __VA_ARGS__); os_log(OS_LOG_DEFAULT, "GSR24M %{public}s", _b); } while (0)

enum { kObjPlugIn = kAudioObjectPlugInObject, kObjDevice = 2, kObjStreamIn = 3, kObjStreamOut = 4 };
enum { kChangeRate = 1, kChangeRefresh = 2 };
static _Atomic uint32_t gRateRequested;          // rate a client asked for; the change is applied (and waited for) in PerformDeviceConfigurationChange
static uint32_t gPubNamesRev;
static uint32_t gPubSafetyIn = 256, gPubSafetyOut = 256, gPubInLat, gPubOutLat;   // timing values CoreAudio has been given (connect thread / config change only)
#define ZERO_PERIOD 4096u
#define ANCHOR_STALE_NS 1500000000ull          // anchor older than this: gsrd is considered gone

static const Float64 kRates[4] = {44100, 48000, 88200, 96000};

static AudioServerPlugInHostRef gHost;
static GsrRingHeader *_Atomic gHdr;
static _Atomic Float64 gRate = 48000;           // rate presented to CoreAudio
static _Atomic uint32_t gIoRunning;
static uint64_t gVirtHost;                      // free-running clock origin (IO thread only)
static _Atomic uint32_t gVirtSeed = 1;
static mach_timebase_info_data_t gTb;
static double gHostHz;                          // mach ticks per second

static inline uint64_t hostNow(void) { return mach_absolute_time(); }
static GsrRingHeader *hdr(void) { return atomic_load_explicit(&gHdr, memory_order_acquire); }

// ---------- connection to gsrd (background thread, may sleep) ----------

static GsrRingHeader *mapFromFile(const char *path) {
    int fd = open(path, O_RDWR);
    if (fd < 0) return NULL;
    GsrRingHeader *h = NULL;
    off_t sz = lseek(fd, 0, SEEK_END);
    if (sz > 4096) { void *p = mmap(NULL, (size_t)sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0); if (p != MAP_FAILED) h = p; }
    close(fd);
    return h;
}

static GsrRingHeader *mapFromXpc(void) {
    xpc_connection_t c = xpc_connection_create_mach_service(GSR_MACH_SERVICE, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), 0);
    if (!c) return NULL;
    xpc_connection_set_event_handler(c, ^(xpc_object_t e) { (void)e; });
    xpc_connection_resume(c);
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(m, "op", "ring");
    xpc_object_t rep = xpc_connection_send_message_with_reply_sync(c, m);
    GsrRingHeader *h = NULL;
    if (xpc_get_type(rep) == XPC_TYPE_DICTIONARY) {
        xpc_object_t shm = xpc_dictionary_get_value(rep, "ring");
        void *addr = NULL;
        if (shm && xpc_shmem_map(shm, &addr) > 4096) h = addr;
    }
    return h;
}

static int hdrOk(const GsrRingHeader *h) {
    return h && h->magic == GSR_RING_MAGIC && h->version == GSR_RING_VERSION && h->ringFrames && (h->ringFrames & (h->ringFrames - 1)) == 0
        && h->channelsIn <= GSR_MAX_CH && h->channelsOut <= GSR_MAX_CH && h->totalBytes >= gsr_ring_bytes(h->ringFrames);
}

static int anchorFresh(GsrRingHeader *h) {
    uint64_t f, t; double p;
    if (!gsr_anchor_read(h, &f, &t, &p)) return 0;
    int64_t d = (int64_t)(hostNow() - t);      // the anchor time can be a little ahead of now: that is fresh, not stale
    uint64_t age = d < 0 ? 0 : (uint64_t)d * gTb.numer / gTb.denom;
    return age < ANCHOR_STALE_NS;
}

// The HAL caches device properties. Whatever depends on what gsrd publishes (latency, safety offsets, channel names, rate) has to be
// announced when the ring appears or the rate changes, otherwise CoreAudio keeps the defaults it read before gsrd was there.
static void notifyDeviceTiming(void) {
    if (!gHost) return;
    AudioObjectPropertyAddress a[7] = {
        { kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
        { kAudioObjectPropertyElementName, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementWildcard },
        { kAudioObjectPropertyElementName, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementWildcard },
        { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain } };
    gHost->PropertiesChanged(gHost, kObjDevice, 7, a);
}

static void *connectThread(void *arg) {
    (void)arg;
    const char *file = getenv("GSR_RING_FILE");
    uint64_t staleSince = 0;
    for (;;) {
        GsrRingHeader *h = hdr();
        if (h) {
            // gsrd gone (crash, restart): its anchor stops moving. Drop the ring and ask again. The old mapping is
            // left in place on purpose (the IO thread may still be reading it); it is small and restarts are rare.
            if (anchorFresh(h)) staleSince = 0;
            else if (!staleSince) staleSince = hostNow();
            else if ((hostNow() - staleSince) * gTb.numer / gTb.denom > 2000000000ull) {
                atomic_store_explicit(&gHdr, NULL, memory_order_release);
                staleSince = 0; h = NULL;
                LOG("gsrd stopped answering: ring dropped, will reconnect");
            }
        }
        if (!h) {
            GsrRingHeader *n = file ? mapFromFile(file) : mapFromXpc();
            if (hdrOk(n) && anchorFresh(n)) {
                uint32_t running = atomic_load(&gIoRunning);
                if (running) atomic_fetch_add(&n->ioClients, running);       // tell the new gsrd that IO is running
                atomic_store_explicit(&gHdr, n, memory_order_release);
                LOG("ring mapped (%s), rate %u, safety in/out %u/%u", file ? "file" : "xpc", atomic_load(&n->sampleRate), n->safetyIn, n->safetyOut);
                if (gHost) gHost->RequestDeviceConfigurationChange(gHost, kObjDevice, kChangeRefresh, NULL);
            }
        } else {
            uint32_t r = atomic_load(&h->sampleRate);
            { uint32_t nr = atomic_load(&h->namesRevision);
              if (nr != gPubNamesRev && gHost) {
                  gPubNamesRev = nr;
                  AudioObjectPropertyAddress na[2] = { { kAudioObjectPropertyElementName, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementWildcard },
                                                       { kAudioObjectPropertyElementName, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementWildcard } };
                  gHost->PropertiesChanged(gHost, kObjDevice, 2, na);
                  LOG("channel names changed (revision %u)", nr);
              } }
            if (anchorFresh(h) && gHost && (h->safetyIn != gPubSafetyIn || h->safetyOut != gPubSafetyOut || h->inLatencyFrames != gPubInLat || h->outLatencyFrames != gPubOutLat) && !((Float64)r != atomic_load(&gRate))) {
                LOG("timing changed (safety in/out %u/%u): asking CoreAudio to re-read the device", h->safetyIn, h->safetyOut);
                gHost->RequestDeviceConfigurationChange(gHost, kObjDevice, kChangeRefresh, NULL);
            }
            if (r && (Float64)r != atomic_load(&gRate) && anchorFresh(h) && gHost && !atomic_load(&gRateRequested)) {
                LOG("card rate is now %u: asking CoreAudio to reconfigure", r);
                gHost->RequestDeviceConfigurationChange(gHost, kObjDevice, kChangeRate, NULL);
            }
        }
        usleep(250000);
    }
    return NULL;
}

// ---------- clock ----------

// Returns the sample time now and the host time of a given sample time. Falls back to a free-running clock.
static int clockNow(Float64 *framesNow, uint64_t *seed, double *tpf, uint64_t *f0, uint64_t *h0) {
    GsrRingHeader *h = hdr();
    uint64_t now = hostNow();
    uint64_t f, t; double p;
    int64_t dAge;
    if (h && gsr_anchor_read(h, &f, &t, &p) && (dAge = (int64_t)(now - t)) < (int64_t)(ANCHOR_STALE_NS * gTb.denom / gTb.numer)) {
        *tpf = p; *f0 = f; *h0 = t; *seed = atomic_load_explicit(&h->generation, memory_order_relaxed);
        *framesNow = (Float64)f + (Float64)((int64_t)(now - t)) / p;
        return 1;
    }
    Float64 rate = atomic_load_explicit(&gRate, memory_order_relaxed);
    if (!gVirtHost) gVirtHost = now;
    *tpf = gHostHz / rate; *f0 = 0; *h0 = gVirtHost; *seed = 0x80000000u + atomic_load(&gVirtSeed);
    *framesNow = (Float64)(now - gVirtHost) / *tpf;
    return 0;
}

// ---------- properties ----------

typedef enum { P_SIZE, P_GET } PMode;

static CFStringRef chanName(int input, UInt32 element) {
    GsrRingHeader *h = hdr();
    char buf[GSR_NAME_LEN + 1] = {0};
    if (h && element >= 1 && element <= GSR_MAX_CH && hdrOk(h)) memcpy(buf, input ? h->nameIn[element - 1] : h->nameOut[element - 1], GSR_NAME_LEN);
    if (!buf[0]) snprintf(buf, sizeof buf, "CH%u", (unsigned)element);
    return CFStringCreateWithCString(NULL, buf, kCFStringEncodingUTF8);
}

// Virtual format (what clients get): Float32, 32 channels. Physical format (what the card carries): 24 bit signed integer, packed.
static void fillASBD(AudioStreamBasicDescription *d, Float64 rate, int physical) {
    memset(d, 0, sizeof *d);
    d->mSampleRate = rate; d->mFormatID = kAudioFormatLinearPCM;
    d->mChannelsPerFrame = GSR_MAX_CH; d->mFramesPerPacket = 1;
    if (physical) {
        d->mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        d->mBitsPerChannel = 24; d->mBytesPerFrame = GSR_MAX_CH * 3;
    } else {
        d->mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
        d->mBitsPerChannel = 32; d->mBytesPerFrame = GSR_MAX_CH * 4;
    }
    d->mBytesPerPacket = d->mBytesPerFrame;
}

#define OUT(sz, stmt) do { *outSize = (sz); if (mode == P_GET) { if (bufSize < (sz)) return kAudioHardwareBadPropertySizeError; stmt; } return kAudioHardwareNoError; } while (0)

static OSStatus Prop(AudioObjectID o, const AudioObjectPropertyAddress *a, PMode mode, UInt32 bufSize, UInt32 *outSize, void *buf, UInt32 qSize, const void *q) {
    GsrRingHeader *h = hdr();
    int hv = h && hdrOk(h);
    Float64 rate = atomic_load(&gRate);
    int scopeIn = a->mScope == kAudioObjectPropertyScopeInput, scopeOut = a->mScope == kAudioObjectPropertyScopeOutput;
    if (o == kObjPlugIn) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: OUT(sizeof(AudioClassID), *(AudioClassID *)buf = kAudioObjectClassID);
        case kAudioObjectPropertyClass: OUT(sizeof(AudioClassID), *(AudioClassID *)buf = kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: OUT(sizeof(AudioObjectID), *(AudioObjectID *)buf = kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: OUT(sizeof(CFStringRef), *(CFStringRef *)buf = CFSTR("GSR24M"));
        case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList: OUT(sizeof(AudioObjectID), *(AudioObjectID *)buf = kObjDevice);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (qSize != sizeof(CFStringRef) || !q) return kAudioHardwareBadPropertySizeError;
            OUT(sizeof(AudioObjectID), *(AudioObjectID *)buf = CFEqual(*(CFStringRef *)q, CFSTR("GSR24M-Device")) ? kObjDevice : kAudioObjectUnknown);
        }
        }
        return kAudioHardwareUnknownPropertyError;
    }
    if (o == kObjDevice) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: OUT(sizeof(AudioClassID), *(AudioClassID *)buf = kAudioObjectClassID);
        case kAudioObjectPropertyClass: OUT(sizeof(AudioClassID), *(AudioClassID *)buf = kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: OUT(sizeof(AudioObjectID), *(AudioObjectID *)buf = kObjPlugIn);
        case kAudioObjectPropertyName: OUT(sizeof(CFStringRef), *(CFStringRef *)buf = CFSTR("GS-R24M FireWire"));
        case kAudioObjectPropertyManufacturer: OUT(sizeof(CFStringRef), *(CFStringRef *)buf = CFSTR("Allen & Heath"));
        case kAudioObjectPropertyModelName: OUT(sizeof(CFStringRef), *(CFStringRef *)buf = CFSTR("GS-R24"));
        case kAudioDevicePropertyDeviceUID: OUT(sizeof(CFStringRef), *(CFStringRef *)buf = CFSTR("GSR24M-Device"));
        case kAudioDevicePropertyModelUID: OUT(sizeof(CFStringRef), *(CFStringRef *)buf = CFSTR("GSR24M-Model"));
        case kAudioDevicePropertyTransportType: OUT(sizeof(UInt32), *(UInt32 *)buf = kAudioDeviceTransportTypeFireWire);
        case kAudioDevicePropertyRelatedDevices: OUT(sizeof(AudioObjectID), *(AudioObjectID *)buf = kObjDevice);
        case kAudioDevicePropertyClockDomain: OUT(sizeof(UInt32), *(UInt32 *)buf = 0x47535231);
        case kAudioDevicePropertyDeviceIsAlive: OUT(sizeof(UInt32), *(UInt32 *)buf = 1);
        case kAudioDevicePropertyDeviceIsRunning: OUT(sizeof(UInt32), *(UInt32 *)buf = atomic_load(&gIoRunning) ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: OUT(sizeof(UInt32), *(UInt32 *)buf = 1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: OUT(sizeof(UInt32), *(UInt32 *)buf = 0);
        case kAudioDevicePropertyLatency: OUT(sizeof(UInt32), *(UInt32 *)buf = scopeIn ? (hv ? h->inLatencyFrames : 0) : (hv ? h->outLatencyFrames : 0));
        case kAudioDevicePropertySafetyOffset: OUT(sizeof(UInt32), *(UInt32 *)buf = scopeIn ? (hv ? h->safetyIn : 256) : (hv ? h->safetyOut : 256));
        case kAudioDevicePropertyStreams: {
            if (scopeIn) OUT(sizeof(AudioObjectID), *(AudioObjectID *)buf = kObjStreamIn);
            if (scopeOut) OUT(sizeof(AudioObjectID), *(AudioObjectID *)buf = kObjStreamOut);
            OUT(2 * sizeof(AudioObjectID), ((AudioObjectID *)buf)[0] = kObjStreamIn; ((AudioObjectID *)buf)[1] = kObjStreamOut);
        }
        case kAudioObjectPropertyOwnedObjects: OUT(2 * sizeof(AudioObjectID), ((AudioObjectID *)buf)[0] = kObjStreamIn; ((AudioObjectID *)buf)[1] = kObjStreamOut);
        case kAudioObjectPropertyControlList: OUT(0, (void)0);
        case kAudioDevicePropertyNominalSampleRate: OUT(sizeof(Float64), *(Float64 *)buf = rate);
        case kAudioDevicePropertyAvailableNominalSampleRates: OUT(sizeof kRates / sizeof kRates[0] * sizeof(AudioValueRange),
            for (int i = 0; i < 4; i++) { ((AudioValueRange *)buf)[i].mMinimum = kRates[i]; ((AudioValueRange *)buf)[i].mMaximum = kRates[i]; });
        case kAudioDevicePropertyIsHidden: OUT(sizeof(UInt32), *(UInt32 *)buf = 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: OUT(sizeof(UInt32), *(UInt32 *)buf = ZERO_PERIOD);
        case kAudioDevicePropertyPreferredChannelsForStereo: OUT(2 * sizeof(UInt32), ((UInt32 *)buf)[0] = 1; ((UInt32 *)buf)[1] = 2);
        case kAudioObjectPropertyElementName:
            if ((scopeIn || scopeOut) && a->mElement >= 1 && a->mElement <= GSR_MAX_CH) OUT(sizeof(CFStringRef), *(CFStringRef *)buf = chanName(scopeIn, a->mElement));
            return kAudioHardwareUnknownPropertyError;
        }
        return kAudioHardwareUnknownPropertyError;
    }
    if (o == kObjStreamIn || o == kObjStreamOut) {
        int input = o == kObjStreamIn;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: OUT(sizeof(AudioClassID), *(AudioClassID *)buf = kAudioObjectClassID);
        case kAudioObjectPropertyClass: OUT(sizeof(AudioClassID), *(AudioClassID *)buf = kAudioStreamClassID);
        case kAudioObjectPropertyOwner: OUT(sizeof(AudioObjectID), *(AudioObjectID *)buf = kObjDevice);
        case kAudioObjectPropertyName: OUT(sizeof(CFStringRef), *(CFStringRef *)buf = input ? CFSTR("GS-R24M input") : CFSTR("GS-R24M output"));
        case kAudioStreamPropertyIsActive: OUT(sizeof(UInt32), *(UInt32 *)buf = 1);
        case kAudioStreamPropertyDirection: OUT(sizeof(UInt32), *(UInt32 *)buf = input ? 1 : 0);
        case kAudioStreamPropertyTerminalType: OUT(sizeof(UInt32), *(UInt32 *)buf = input ? kAudioStreamTerminalTypeLine : kAudioStreamTerminalTypeLine);
        case kAudioStreamPropertyStartingChannel: OUT(sizeof(UInt32), *(UInt32 *)buf = 1);
        case kAudioStreamPropertyLatency: OUT(sizeof(UInt32), *(UInt32 *)buf = 0);
        case kAudioStreamPropertyVirtualFormat: OUT(sizeof(AudioStreamBasicDescription), fillASBD((AudioStreamBasicDescription *)buf, rate, 0));
        case kAudioStreamPropertyPhysicalFormat: OUT(sizeof(AudioStreamBasicDescription), fillASBD((AudioStreamBasicDescription *)buf, rate, 1));
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            OUT(4 * sizeof(AudioStreamRangedDescription), for (int i = 0; i < 4; i++) {
                AudioStreamRangedDescription *r = &((AudioStreamRangedDescription *)buf)[i];
                fillASBD(&r->mFormat, kRates[i], a->mSelector == kAudioStreamPropertyAvailablePhysicalFormats);
                r->mSampleRateRange.mMinimum = kRates[i]; r->mSampleRateRange.mMaximum = kRates[i]; });
        }
        return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareBadObjectError;
}

static int rateAllowed(Float64 r) { for (int i = 0; i < 4; i++) if (kRates[i] == r) return 1; return 0; }

// ---------- driver interface ----------

static ULONG gRefCount = 1;
static AudioServerPlugInDriverInterface gIface;
static AudioServerPlugInDriverInterface *gIfacePtr = &gIface;
static AudioServerPlugInDriverRef gDriver = &gIfacePtr;
static pthread_once_t gOnce = PTHREAD_ONCE_INIT;

static HRESULT QI(void *d, REFIID iid, LPVOID *out) {
    (void)d;
    CFUUIDRef u = CFUUIDCreateFromUUIDBytes(NULL, iid);
    HRESULT r = E_NOINTERFACE;
    if (CFEqual(u, IUnknownUUID) || CFEqual(u, kAudioServerPlugInDriverInterfaceUUID)) { gRefCount++; *out = gDriver; r = S_OK; }
    CFRelease(u);
    return r;
}
static ULONG AddRef(void *d) { (void)d; return ++gRefCount; }
static ULONG Release(void *d) { (void)d; return --gRefCount; }

static OSStatus Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef host) {
    (void)d; gHost = host;
    mach_timebase_info(&gTb);
    gHostHz = 1e9 * gTb.denom / gTb.numer;
    pthread_t t; pthread_create(&t, NULL, connectThread, NULL); pthread_detach(t);
    LOG("Initialize");
    return kAudioHardwareNoError;
}
static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *o) { (void)d; (void)desc; (void)c; (void)o; return kAudioHardwareUnsupportedOperationError; }
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID o) { (void)d; (void)o; return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) { (void)d; (void)o; (void)c; return kAudioHardwareNoError; }
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) { (void)d; (void)o; (void)c; return kAudioHardwareNoError; }

static OSStatus PerformChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 action, void *info) {
    (void)d; (void)info;
    if (o != kObjDevice || (action != kChangeRate && action != kChangeRefresh)) return kAudioHardwareBadObjectError;
    GsrRingHeader *h = hdr();
    // A client asked for a rate: the HAL has stopped the IO, so this is the place to wait (up to 8 s) until gsrd has switched the card
    // and publishes a fresh clock at that rate. One clean reconfiguration instead of a gap followed by a second restart.
    uint32_t asked = atomic_exchange(&gRateRequested, 0);
    if (asked && h && hdrOk(h)) {
        for (int i = 0; i < 160; i++) {
            if (atomic_load(&h->sampleRate) == asked && atomic_load(&h->state) == GSR_STATE_STREAMING && anchorFresh(h)) break;
            usleep(50000);
        }
        LOG("rate change to %u: %s", asked, atomic_load(&h->sampleRate) == asked ? "card switched" : "the card did not follow (timeout)");
    }
    if (h && hdrOk(h)) {
        gPubSafetyIn = h->safetyIn; gPubSafetyOut = h->safetyOut; gPubInLat = h->inLatencyFrames; gPubOutLat = h->outLatencyFrames;
        Float64 r = (Float64)atomic_load(&h->sampleRate);
        if (rateAllowed(r) && r != atomic_load(&gRate)) { atomic_store(&gRate, r); gVirtHost = 0; atomic_fetch_add(&gVirtSeed, 1); }
    }
    notifyDeviceTiming();
    AudioObjectPropertyAddress sp[1] = { { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain } };
    gHost->PropertiesChanged(gHost, kObjStreamIn, 1, sp);
    gHost->PropertiesChanged(gHost, kObjStreamOut, 1, sp);
    LOG("rate now %.0f", atomic_load(&gRate));
    return kAudioHardwareNoError;
}
static OSStatus AbortChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void *i) { (void)d; (void)o; (void)a; (void)i; return kAudioHardwareNoError; }

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a) {
    (void)d; (void)pid; UInt32 sz = 0;
    return Prop(o, a, P_SIZE, 0, &sz, NULL, 0, NULL) == kAudioHardwareNoError;
}
static OSStatus IsSettable(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *s) {
    (void)d; (void)pid; UInt32 sz = 0;
    OSStatus r = Prop(o, a, P_SIZE, 0, &sz, NULL, 0, NULL);
    if (r) return r;
    *s = (o == kObjDevice && a->mSelector == kAudioDevicePropertyNominalSampleRate) ||
         ((o == kObjStreamIn || o == kObjStreamOut) && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat));
    return kAudioHardwareNoError;
}
static OSStatus GetSize(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *sz) {
    (void)d; (void)pid;
    return Prop(o, a, P_SIZE, 0, sz, NULL, qs, q);
}
static OSStatus GetData(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 in, UInt32 *out, void *data) {
    (void)d; (void)pid;
    return Prop(o, a, P_GET, in, out, data, qs, q);
}
static OSStatus SetData(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 sz, const void *data) {
    (void)d; (void)pid; (void)qs; (void)q;
    Float64 want = 0;
    if (o == kObjDevice && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (sz != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        want = *(const Float64 *)data;
    } else if ((o == kObjStreamIn || o == kObjStreamOut) && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (sz != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription *f = data;
        int phys = a->mSelector == kAudioStreamPropertyPhysicalFormat;
        if (f->mFormatID != kAudioFormatLinearPCM || f->mChannelsPerFrame != GSR_MAX_CH) return kAudioDeviceUnsupportedFormatError;
        if (phys ? (f->mBitsPerChannel != 24 || !(f->mFormatFlags & kAudioFormatFlagIsSignedInteger) || f->mBytesPerFrame != GSR_MAX_CH * 3)
                 : (f->mBitsPerChannel != 32 || !(f->mFormatFlags & kAudioFormatFlagIsFloat))) return kAudioDeviceUnsupportedFormatError;
        want = f->mSampleRate;
    } else return kAudioHardwareUnsupportedOperationError;
    if (!rateAllowed(want)) return kAudioDeviceUnsupportedFormatError;
    GsrRingHeader *h = hdr();
    if (!(h && hdrOk(h))) return kAudioHardwareIllegalOperationError;       // only gsrd can change the card's rate
    if ((Float64)atomic_load(&h->sampleRate) != want) {
        atomic_store(&h->requestedRate, (uint32_t)want);
        atomic_store(&gRateRequested, (uint32_t)want);
        if (gHost) gHost->RequestDeviceConfigurationChange(gHost, kObjDevice, kChangeRate, NULL);
    }
    return kAudioHardwareNoError;
}

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c) {
    (void)d; (void)o; (void)c;
    if (atomic_fetch_add(&gIoRunning, 1) == 0) gVirtHost = 0;
    GsrRingHeader *h = hdr(); if (h) atomic_fetch_add(&h->ioClients, 1);
    return kAudioHardwareNoError;
}
static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c) {
    (void)d; (void)o; (void)c;
    if (atomic_load(&gIoRunning)) atomic_fetch_sub(&gIoRunning, 1);
    GsrRingHeader *h = hdr(); if (h && atomic_load(&h->ioClients)) atomic_fetch_sub(&h->ioClients, 1);
    return kAudioHardwareNoError;
}

static OSStatus GetZero(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, Float64 *sampleTime, UInt64 *hostTime, UInt64 *seed) {
    (void)d; (void)o; (void)c;
    Float64 fn; uint64_t sd, f0, h0; double tpf;
    clockNow(&fn, &sd, &tpf, &f0, &h0);
    Float64 zero = floor(fn / ZERO_PERIOD) * ZERO_PERIOD;
    *sampleTime = zero;
    *hostTime = h0 + (uint64_t)llround(((double)zero - (double)f0) * tpf);
    *seed = sd;
    return kAudioHardwareNoError;
}
static OSStatus WillDo(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, Boolean *w, Boolean *inPlace) {
    (void)d; (void)o; (void)c;
    *w = op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix;
    *inPlace = true;
    return kAudioHardwareNoError;
}
static OSStatus BeginIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *i) { (void)d; (void)o; (void)c; (void)op; (void)n; (void)i; return kAudioHardwareNoError; }

static OSStatus DoIO(AudioServerPlugInDriverRef d, AudioObjectID o, AudioObjectID stream, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *info, void *main, void *sec) {
    (void)d; (void)o; (void)c; (void)sec;
    GsrRingHeader *h = hdr();
    int ok = h && hdrOk(h);
    if (op == kAudioServerPlugInIOOperationReadInput && stream == kObjStreamIn) {
        uint8_t *dst = main;                                            // native format: 24 bit signed, packed, 32 channels per frame
        const size_t fb = GSR_MAX_CH * 3;
        if (!ok) { memset(dst, 0, (size_t)n * fb); return kAudioHardwareNoError; }
        int64_t s0 = (int64_t)info->mInputTime.mSampleTime, mask = h->ringFrames - 1;
        int64_t written = (int64_t)atomic_load_explicit(&h->inWritten, memory_order_acquire);
        const float *ring = gsr_in_ring(h);
        uint64_t missing = 0;
        for (UInt32 f = 0; f < n; f++) {
            int64_t sf = s0 + f;
            uint8_t *o = dst + (size_t)f * fb;
            if (sf >= 0 && sf < written && sf + (int64_t)h->ringFrames > written) {
                const float *src = ring + (size_t)(sf & mask) * GSR_MAX_CH;
                for (int c = 0; c < GSR_MAX_CH; c++) {
                    float x = src[c];
                    if (x > 0.99999988f) x = 0.99999988f; else if (x < -1.0f) x = -1.0f;
                    int32_t v = (int32_t)lrintf(x * 8388608.0f);
                    if (v > 8388607) v = 8388607;
                    o[c * 3] = (uint8_t)v; o[c * 3 + 1] = (uint8_t)(v >> 8); o[c * 3 + 2] = (uint8_t)(v >> 16);
                }
            } else { memset(o, 0, fb); missing++; }
        }
        if (missing) atomic_fetch_add_explicit(&h->inLate, missing, memory_order_relaxed);
    } else if (op == kAudioServerPlugInIOOperationWriteMix && stream == kObjStreamOut) {
        if (!ok) return kAudioHardwareNoError;
        const uint8_t *src = main;                                      // native format: 24 bit signed, packed
        const size_t fb = GSR_MAX_CH * 3;
        int64_t s0 = (int64_t)info->mOutputTime.mSampleTime, mask = h->ringFrames - 1;
        float *ring = gsr_out_ring(h);
        for (UInt32 f = 0; f < n; f++) {
            int64_t sf = s0 + f;
            if (sf < 0) continue;
            const uint8_t *i3 = src + (size_t)f * fb;
            float *dst = ring + (size_t)(sf & mask) * GSR_MAX_CH;
            for (int c = 0; c < GSR_MAX_CH; c++) {
                int32_t v = (int32_t)((uint32_t)i3[c * 3] | (uint32_t)i3[c * 3 + 1] << 8 | (uint32_t)i3[c * 3 + 2] << 16);
                if (v & 0x800000) v -= 0x1000000;
                dst[c] = (float)v * (1.0f / 8388608.0f);
            }
        }
        uint64_t end = (uint64_t)(s0 + n), cur = atomic_load_explicit(&h->outWritten, memory_order_relaxed);
        while (end > cur && !atomic_compare_exchange_weak_explicit(&h->outWritten, &cur, end, memory_order_release, memory_order_relaxed)) {}
    }
    return kAudioHardwareNoError;
}
static OSStatus EndIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *i) { (void)d; (void)o; (void)c; (void)op; (void)n; (void)i; return kAudioHardwareNoError; }

static void setup(void) {
    gIface = (AudioServerPlugInDriverInterface){
        NULL, QI, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddDeviceClient, RemoveDeviceClient,
        PerformChange, AbortChange, HasProperty, IsSettable, GetSize, GetData, SetData,
        StartIO, StopIO, GetZero, WillDo, BeginIO, DoIO, EndIO };
}

void *GSR24MFactory(CFAllocatorRef alloc, CFUUIDRef typeUUID) {
    (void)alloc;
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    pthread_once(&gOnce, setup);
    return gDriver;
}
