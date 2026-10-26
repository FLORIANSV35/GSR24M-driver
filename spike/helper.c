// Spike helper: stands in for gsrd. Publishes a "ring" in shared memory and answers one request on a Mach service,
// so we can see which ways of sharing memory work with a sandboxed AudioServerPlugIn.
//
// Three ways are offered to the plug-in:
//   A. XPC over the Mach service SVC; the reply carries an xpc_shmem object (the ring).
//   B. POSIX shared memory /gsr24m-spike.
//   C. A file /Library/Application Support/GSR24M/ring.bin that the plug-in can mmap read-only.
// Each ring starts with a header; a counter is incremented every millisecond so the reader can see it is live.
//
// Build: clang -O1 -Wall -o gsr24m-spike-helper helper.c

#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <xpc/xpc.h>

#define SVC "com.gsr24m.spike"
#define RING_BYTES (1u << 20)
#define MAGIC 0x47535231u   // 'GSR1'

typedef struct {
    uint32_t magic;
    uint32_t rate;
    uint32_t channels;
    uint32_t pad;
    _Atomic uint64_t counter;      // incremented every millisecond
    _Atomic uint64_t hostTime;     // mach_absolute_time at the last increment
    float data[];                  // 1 kHz test tone, interleaved
} Ring;

static Ring *gRingXpc, *gRingPosix, *gRingFile;

static void fill(Ring *r) {
    r->magic = MAGIC; r->rate = 96000; r->channels = 2;
    size_t n = (RING_BYTES - sizeof(Ring)) / sizeof(float) / 2;
    for (size_t i = 0; i < n; i++) { float v = 0.25f * sinf(2 * (float)M_PI * 1000.0f * (float)i / 96000.0f); r->data[2 * i] = v; r->data[2 * i + 1] = v; }
}

static void tick(Ring *r) {
    atomic_fetch_add(&r->counter, 1);
    atomic_store(&r->hostTime, mach_absolute_time());
}

static Ring *mapFile(const char *path) {
    int fd = open(path, O_RDWR | O_CREAT, 0644);
    if (fd < 0) { perror(path); return NULL; }
    fchmod(fd, 0644);
    if (ftruncate(fd, RING_BYTES)) { perror("ftruncate"); close(fd); return NULL; }
    Ring *r = mmap(NULL, RING_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    return r == MAP_FAILED ? NULL : r;
}

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    // A. anonymous memory handed over with xpc_shmem
    vm_address_t va = 0;
    if (vm_allocate(mach_task_self(), &va, RING_BYTES, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) { fprintf(stderr, "vm_allocate failed\n"); return 1; }
    gRingXpc = (Ring *)va; fill(gRingXpc);
    // B. POSIX shared memory
    int sfd = shm_open("/gsr24m-spike", O_RDWR | O_CREAT, 0644);
    if (sfd >= 0) { fchmod(sfd, 0644); if (ftruncate(sfd, RING_BYTES) == 0) { Ring *r = mmap(NULL, RING_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, sfd, 0); if (r != MAP_FAILED) { gRingPosix = r; fill(r); } } close(sfd); }
    else perror("shm_open");
    // C. file
    mkdir("/Library/Application Support/GSR24M", 0755);
    gRingFile = mapFile("/Library/Application Support/GSR24M/ring.bin");
    if (gRingFile) fill(gRingFile);
    printf("helper up: xpc ring %p, posix ring %p, file ring %p\n", (void *)gRingXpc, (void *)gRingPosix, (void *)gRingFile);

    dispatch_queue_t q = dispatch_queue_create("ticker", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_MSEC, 100 * NSEC_PER_USEC);
    dispatch_source_set_event_handler(t, ^{ tick(gRingXpc); if (gRingPosix) tick(gRingPosix); if (gRingFile) tick(gRingFile); });
    dispatch_resume(t);

    xpc_connection_t l = xpc_connection_create_mach_service(SVC, dispatch_get_main_queue(), XPC_CONNECTION_MACH_SERVICE_LISTENER);
    xpc_connection_set_event_handler(l, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
        printf("client connected (pid %d)\n", xpc_connection_get_pid(peer));
        xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
            if (xpc_get_type(msg) != XPC_TYPE_DICTIONARY) return;
            const char *op = xpc_dictionary_get_string(msg, "op");
            printf("request '%s' from pid %d\n", op ? op : "?", xpc_connection_get_pid(peer));
            xpc_object_t reply = xpc_dictionary_create_reply(msg);
            if (reply) {
                xpc_object_t shm = xpc_shmem_create(gRingXpc, RING_BYTES);
                xpc_dictionary_set_value(reply, "ring", shm);
                xpc_dictionary_set_uint64(reply, "size", RING_BYTES);
                xpc_connection_send_message(peer, reply);
            }
        });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(l);
    dispatch_main();
}
