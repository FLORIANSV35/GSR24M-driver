// Command line client for gsrd's control operations (same Mach service the app uses).
//   gsrctl info                      print the JSON the app receives
//   gsrctl rate 96000                ask for a sample rate
//   gsrctl lead 80                   playback lead in ms
//   gsrctl source internal|wc        clock source (the card goes back to internal if there is no word clock)
//   gsrctl name in|out N "text"      set (or clear with "") the custom name of channel N (1..32); other names are kept
#include "../hal/gsr_ring.h"
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

static xpc_connection_t conn(void) {
    xpc_connection_t c = xpc_connection_create_mach_service(GSR_MACH_SERVICE, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), 0);
    xpc_connection_set_event_handler(c, ^(xpc_object_t e) { (void)e; });
    xpc_connection_resume(c);
    return c;
}
static xpc_object_t call(xpc_connection_t c, xpc_object_t m) { return xpc_connection_send_message_with_reply_sync(c, m); }

// Extracts the JSON array of strings "customIn" / "customOut" from the info JSON (same tiny reader idea as the daemon).
static void customNames(const char *json, const char *key, char names[GSR_MAX_CH][GSR_NAME_LEN]) {
    memset(names, 0, GSR_MAX_CH * GSR_NAME_LEN);
    char pat[32]; snprintf(pat, sizeof pat, "\"%s\":[", key);
    const char *p = strstr(json, pat); if (!p) return; p += strlen(pat);
    for (int k = 0; k < GSR_MAX_CH; k++) {
        p = strchr(p, '"'); if (!p) return; p++;
        size_t m = 0;
        while (*p && *p != '"') { if (*p == '\\' && p[1]) p++; if (m + 1 < GSR_NAME_LEN) names[k][m++] = *p; p++; }
        if (*p == '"') p++;
    }
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: gsrctl info | rate N | lead MS | name in|out N TEXT\n"); return 2; }
    xpc_connection_t c = conn();
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
    if (!strcmp(argv[1], "info")) {
        xpc_dictionary_set_string(m, "op", "info");
        xpc_object_t r = call(c, m);
        if (xpc_get_type(r) != XPC_TYPE_DICTIONARY) { fprintf(stderr, "no reply\n"); return 1; }
        printf("%s\n", xpc_dictionary_get_string(r, "json"));
    } else if (!strcmp(argv[1], "rate") && argc > 2) {
        xpc_dictionary_set_string(m, "op", "setRate"); xpc_dictionary_set_uint64(m, "rate", strtoull(argv[2], NULL, 10));
        xpc_object_t r = call(c, m); printf("%s\n", xpc_get_type(r) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_bool(r, "ok") ? "accepted" : "refused");
    } else if (!strcmp(argv[1], "lead") && argc > 2) {
        xpc_dictionary_set_string(m, "op", "setLead"); xpc_dictionary_set_uint64(m, "ms", strtoull(argv[2], NULL, 10));
        xpc_object_t r = call(c, m); printf("%s\n", xpc_get_type(r) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_bool(r, "ok") ? "accepted" : "refused");
    } else if (!strcmp(argv[1], "source") && argc > 2) {
        xpc_dictionary_set_string(m, "op", "setSource"); xpc_dictionary_set_string(m, "id", argv[2]);
        xpc_object_t r = call(c, m); printf("%s\n", xpc_get_type(r) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_bool(r, "ok") ? "accepted" : "refused");
    } else if (!strcmp(argv[1], "name") && argc > 4) {
        int out = !strcmp(argv[2], "out"), n = atoi(argv[3]);
        if (n < 1 || n > GSR_MAX_CH) { fprintf(stderr, "channel 1..32\n"); return 2; }
        xpc_dictionary_set_string(m, "op", "info");
        xpc_object_t r = call(c, m);
        if (xpc_get_type(r) != XPC_TYPE_DICTIONARY) { fprintf(stderr, "no reply\n"); return 1; }
        const char *json = xpc_dictionary_get_string(r, "json");
        char in[GSR_MAX_CH][GSR_NAME_LEN], ou[GSR_MAX_CH][GSR_NAME_LEN];
        customNames(json, "customIn", in); customNames(json, "customOut", ou);
        snprintf(out ? ou[n - 1] : in[n - 1], GSR_NAME_LEN, "%s", argv[4]);
        xpc_object_t m2 = xpc_dictionary_create(NULL, NULL, 0), a = xpc_array_create(NULL, 0), b = xpc_array_create(NULL, 0);
        xpc_dictionary_set_string(m2, "op", "setNames");
        for (int k = 0; k < GSR_MAX_CH; k++) { xpc_array_set_string(a, XPC_ARRAY_APPEND, in[k]); xpc_array_set_string(b, XPC_ARRAY_APPEND, ou[k]); }
        xpc_dictionary_set_value(m2, "in", a); xpc_dictionary_set_value(m2, "out", b);
        xpc_object_t r2 = call(c, m2); printf("%s\n", xpc_get_type(r2) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_bool(r2, "ok") ? "names updated" : "refused");
    } else { fprintf(stderr, "unknown command\n"); return 2; }
    return 0;
}
