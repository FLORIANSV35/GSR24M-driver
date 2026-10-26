// Spike AudioServerPlugIn: no device. At Initialize it tries three ways of reading memory shared by the helper
// (xpc_shmem over a Mach service, POSIX shm, a mmap'd file) and logs what a sandboxed plug-in is allowed to do.
// Results go to the unified log with the tag GSRSPIKE (public strings):
//   log show --last 5m --info --predicate 'eventMessage CONTAINS "GSRSPIKE"'
//
// Build: see build.sh

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <xpc/xpc.h>

#define SVC "com.gsr24m.spike"
#define RING_BYTES (1u << 20)
#define MAGIC 0x47535231u

typedef struct {
    uint32_t magic, rate, channels, pad;
    _Atomic uint64_t counter;
    _Atomic uint64_t hostTime;
    float data[];
} Ring;

#define LOG(...) do { char _b[400]; snprintf(_b, sizeof _b, __VA_ARGS__); os_log(OS_LOG_DEFAULT, "GSRSPIKE %{public}s", _b); } while (0)

// Reads the counter twice 50 ms apart: it must have moved by about 50 if the memory is live.
static void probe(const char *what, const Ring *r) {
    if (r->magic != MAGIC) { LOG("%s: mapped but magic is 0x%08x (expected 0x%08x)", what, r->magic, MAGIC); return; }
    uint64_t c0 = atomic_load(&r->counter), h0 = atomic_load(&r->hostTime);
    usleep(50000);
    uint64_t c1 = atomic_load(&r->counter), h1 = atomic_load(&r->hostTime);
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double ms = (double)(h1 - h0) * tb.numer / tb.denom / 1e6;
    LOG("%s: OK, live. counter %llu -> %llu in 50 ms (%llu ticks over %.1f ms of host time), rate %u, channels %u, first samples %.3f %.3f",
        what, (unsigned long long)c0, (unsigned long long)c1, (unsigned long long)(c1 - c0), ms, r->rate, r->channels, r->data[0], r->data[1]);
}

static void *testThread(void *arg) {
    (void)arg;
    sleep(2);
    LOG("tests start in pid %d, uid %d", getpid(), getuid());
    // A. xpc over the Mach service
    {
        xpc_connection_t c = xpc_connection_create_mach_service(SVC, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), 0);
        if (!c) LOG("A xpc: could not create the connection");
        else {
            xpc_connection_set_event_handler(c, ^(xpc_object_t e) { (void)e; });
            xpc_connection_resume(c);
            xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
            xpc_dictionary_set_string(m, "op", "ring");
            xpc_object_t rep = xpc_connection_send_message_with_reply_sync(c, m);
            if (xpc_get_type(rep) == XPC_TYPE_ERROR) LOG("A xpc: error reply: %s", xpc_dictionary_get_string(rep, XPC_ERROR_KEY_DESCRIPTION));
            else {
                xpc_object_t shm = xpc_dictionary_get_value(rep, "ring");
                void *addr = NULL;
                size_t sz = shm ? xpc_shmem_map(shm, &addr) : 0;
                if (!sz) LOG("A xpc: reply has no usable shmem");
                else { LOG("A xpc: mapped %zu bytes", sz); probe("A xpc_shmem", (const Ring *)addr); }
            }
        }
    }
    // B. POSIX shared memory
    {
        int fd = shm_open("/gsr24m-spike", O_RDONLY, 0);
        if (fd < 0) LOG("B posix shm: shm_open failed, errno %d (%s)", errno, strerror(errno));
        else {
            void *p = mmap(NULL, RING_BYTES, PROT_READ, MAP_SHARED, fd, 0);
            if (p == MAP_FAILED) LOG("B posix shm: mmap failed, errno %d (%s)", errno, strerror(errno));
            else probe("B posix shm", (const Ring *)p);
            close(fd);
        }
    }
    // C. file
    {
        int fd = open("/Library/Application Support/GSR24M/ring.bin", O_RDONLY);
        if (fd < 0) LOG("C file: open failed, errno %d (%s)", errno, strerror(errno));
        else {
            void *p = mmap(NULL, RING_BYTES, PROT_READ, MAP_SHARED, fd, 0);
            if (p == MAP_FAILED) LOG("C file: mmap failed, errno %d (%s)", errno, strerror(errno));
            else probe("C file mmap", (const Ring *)p);
            close(fd);
        }
    }
    LOG("tests done");
    return NULL;
}

// ---- minimal driver: a plug-in object with no devices ----

static ULONG gRefCount = 1;
static AudioServerPlugInHostRef gHost;
static AudioServerPlugInDriverInterface gIface;
static AudioServerPlugInDriverInterface *gIfacePtr = &gIface;
static AudioServerPlugInDriverRef gDriver = &gIfacePtr;
static pthread_once_t gOnce = PTHREAD_ONCE_INIT;

static HRESULT QI(void *d, REFIID iid, LPVOID *out) {
    CFUUIDRef u = CFUUIDCreateFromUUIDBytes(NULL, iid);
    HRESULT r = E_NOINTERFACE;
    if (CFEqual(u, IUnknownUUID) || CFEqual(u, kAudioServerPlugInDriverInterfaceUUID)) { gRefCount++; *out = gDriver; r = S_OK; }
    CFRelease(u); (void)d; return r;
}
static ULONG AddRef(void *d) { (void)d; return ++gRefCount; }
static ULONG Release(void *d) { (void)d; return --gRefCount; }
static OSStatus Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef host) {
    (void)d; gHost = host;
    pthread_t t; pthread_create(&t, NULL, testThread, NULL); pthread_detach(t);
    LOG("Initialize called");
    return kAudioHardwareNoError;
}
static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *o) { (void)d; (void)desc; (void)c; (void)o; return kAudioHardwareUnsupportedOperationError; }
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID o) { (void)d; (void)o; return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) { (void)d; (void)o; (void)c; return kAudioHardwareNoError; }
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) { (void)d; (void)o; (void)c; return kAudioHardwareNoError; }
static OSStatus PerformChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void *i) { (void)d; (void)o; (void)a; (void)i; return kAudioHardwareNoError; }
static OSStatus AbortChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void *i) { (void)d; (void)o; (void)a; (void)i; return kAudioHardwareNoError; }

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a) {
    (void)d; (void)pid;
    if (o != kAudioObjectPlugInObject) return false;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList:
    case kAudioPlugInPropertyTranslateUIDToDevice: return true;
    }
    return false;
}
static OSStatus IsSettable(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *s) { (void)d; (void)o; (void)pid; (void)a; *s = false; return kAudioHardwareNoError; }
static OSStatus GetSize(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *sz) {
    (void)d; (void)pid; (void)qs; (void)q;
    if (o != kAudioObjectPlugInObject) return kAudioHardwareBadObjectError;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: *sz = sizeof(AudioClassID); return 0;
    case kAudioObjectPropertyOwner: case kAudioPlugInPropertyTranslateUIDToDevice: *sz = sizeof(AudioObjectID); return 0;
    case kAudioObjectPropertyManufacturer: *sz = sizeof(CFStringRef); return 0;
    case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList: *sz = 0; return 0;
    }
    return kAudioHardwareUnknownPropertyError;
}
static OSStatus GetData(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 in, UInt32 *out, void *data) {
    (void)d; (void)pid; (void)qs; (void)q; (void)in;
    if (o != kAudioObjectPlugInObject) return kAudioHardwareBadObjectError;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: *(AudioClassID *)data = kAudioObjectClassID; *out = sizeof(AudioClassID); return 0;
    case kAudioObjectPropertyClass: *(AudioClassID *)data = kAudioPlugInClassID; *out = sizeof(AudioClassID); return 0;
    case kAudioObjectPropertyOwner: case kAudioPlugInPropertyTranslateUIDToDevice: *(AudioObjectID *)data = kAudioObjectUnknown; *out = sizeof(AudioObjectID); return 0;
    case kAudioObjectPropertyManufacturer: *(CFStringRef *)data = CFSTR("GSR24M spike"); *out = sizeof(CFStringRef); return 0;
    case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList: *out = 0; return 0;
    }
    return kAudioHardwareUnknownPropertyError;
}
static OSStatus SetData(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 sz, const void *data) { (void)d; (void)o; (void)pid; (void)a; (void)qs; (void)q; (void)sz; (void)data; return kAudioHardwareUnsupportedOperationError; }
static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c) { (void)d; (void)o; (void)c; return kAudioHardwareUnsupportedOperationError; }
static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c) { (void)d; (void)o; (void)c; return kAudioHardwareUnsupportedOperationError; }
static OSStatus GetZero(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, Float64 *s, UInt64 *h, UInt64 *seed) { (void)d; (void)o; (void)c; (void)s; (void)h; (void)seed; return kAudioHardwareUnsupportedOperationError; }
static OSStatus WillDo(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, Boolean *w, Boolean *inPlace) { (void)d; (void)o; (void)c; (void)op; *w = false; *inPlace = true; return kAudioHardwareNoError; }
static OSStatus BeginIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *i) { (void)d; (void)o; (void)c; (void)op; (void)n; (void)i; return kAudioHardwareNoError; }
static OSStatus DoIO(AudioServerPlugInDriverRef d, AudioObjectID o, AudioObjectID s, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *i, void *m, void *sec) { (void)d; (void)o; (void)s; (void)c; (void)op; (void)n; (void)i; (void)m; (void)sec; return kAudioHardwareNoError; }
static OSStatus EndIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *i) { (void)d; (void)o; (void)c; (void)op; (void)n; (void)i; return kAudioHardwareNoError; }

static void setup(void) {
    gIface = (AudioServerPlugInDriverInterface){
        NULL, QI, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddDeviceClient, RemoveDeviceClient,
        PerformChange, AbortChange, HasProperty, IsSettable, GetSize, GetData, SetData,
        StartIO, StopIO, GetZero, WillDo, BeginIO, DoIO, EndIO };
}

void *GSRSpikeFactory(CFAllocatorRef alloc, CFUUIDRef typeUUID) {
    (void)alloc;
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    pthread_once(&gOnce, setup);
    return gDriver;
}
