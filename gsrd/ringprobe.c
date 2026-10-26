// Connects to gsrd over its Mach service (as the plug-in does) and prints the ring header. Test tool.
#include "../hal/gsr_ring.h"
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <xpc/xpc.h>
int main(int argc, char **argv) {
    xpc_connection_t c = xpc_connection_create_mach_service(GSR_MACH_SERVICE, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), 0);
    xpc_connection_set_event_handler(c, ^(xpc_object_t e) { (void)e; });
    xpc_connection_resume(c);
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(m, "op", "ring");
    xpc_object_t rep = xpc_connection_send_message_with_reply_sync(c, m);
    if (xpc_get_type(rep) != XPC_TYPE_DICTIONARY) { printf("no reply: %s\n", xpc_dictionary_get_string(rep, XPC_ERROR_KEY_DESCRIPTION)); return 1; }
    void *addr = NULL; size_t sz = xpc_shmem_map(xpc_dictionary_get_value(rep, "ring"), &addr);
    GsrRingHeader *H = addr;
    printf("mapped %zu bytes; expected %llu\n", sz, (unsigned long long)gsr_ring_bytes(H->ringFrames));
    if (argc > 1 && !strcmp(argv[1], "--reset-out")) { atomic_store(&H->outWritten, 0); printf("outWritten reset to 0\n"); }
    for (int i = 0; i < 3; i++) {
        printf("magic %08x version %u state %u rate %u gen %u ringFrames %u ch %u/%u totalBytes %llu safety %u/%u inWritten %llu outWritten %llu ioClients %u inLate %llu outLate %llu\n",
               H->magic, H->version, atomic_load(&H->state), atomic_load(&H->sampleRate), atomic_load(&H->generation), H->ringFrames, H->channelsIn, H->channelsOut,
               (unsigned long long)H->totalBytes, H->safetyIn, H->safetyOut, (unsigned long long)atomic_load(&H->inWritten), (unsigned long long)atomic_load(&H->outWritten),
               atomic_load(&H->ioClients), (unsigned long long)atomic_load(&H->inLate), (unsigned long long)atomic_load(&H->outLate));
        usleep(500000);
    }
    return 0;
}
