// Test client for gsrd's shared ring, without CoreAudio: attaches to a ring file, optionally writes a tone into one output
// channel the way the plug-in would (ahead of the card, ioClients = 1), then reports every input channel:
// level, frequency, and the lag between two channels that carry the same signal (stream alignment check).
//
//   ringcheck PATH SECONDS [OUTCH FREQ]        OUTCH is 1..32
//   ringcheck PATH SECONDS --lag A B           also print the best lag between input channels A and B

#include "../hal/gsr_ring.h"

#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: ringcheck PATH SECONDS [OUTCH FREQ] [--lag A B]\n"); return 2; }
    int fd = open(argv[1], O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    GsrRingHeader *H = mmap(NULL, (size_t)gsr_ring_bytes(32768), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (H == MAP_FAILED || H->magic != GSR_RING_MAGIC) { fprintf(stderr, "not a gsrd ring\n"); return 1; }
    double secs = atof(argv[2]); int outch = 0; double freq = 0; int lagA = 0, lagB = 0;
    for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--lag") && i + 2 < argc) { lagA = atoi(argv[i + 1]); lagB = atoi(argv[i + 2]); i += 2; }
        else if (!outch && i + 1 < argc) { outch = atoi(argv[i]); freq = atof(argv[i + 1]); i++; }
    }
    unsigned rate = atomic_load(&H->sampleRate);
    printf("ring: state %u, rate %u, generation %u, safety in/out %u/%u, in written %llu\n", atomic_load(&H->state), rate, atomic_load(&H->generation),
           H->safetyIn, H->safetyOut, (unsigned long long)atomic_load(&H->inWritten));
    if (outch >= 1 && outch <= 32) atomic_store(&H->ioClients, 1);
    float *out = gsr_out_ring(H); uint32_t mask = H->ringFrames - 1;
    uint64_t wr = atomic_load(&H->inWritten);
    if (wr < 1) wr = 0;
    for (int ms = 0; ms < (int)(secs * 1000); ms += 5) {
        uint64_t n = atomic_load(&H->inWritten);
        if (outch >= 1 && outch <= 32) {
            uint64_t upto = n + (uint64_t)(0.120 * rate);                       // stay 120 ms ahead of the capture clock
            if (wr < n) wr = n;
            for (; wr < upto; wr++) {
                float *f = out + (size_t)(wr & mask) * GSR_MAX_CH;
                memset(f, 0, GSR_MAX_CH * sizeof(float));
                f[outch - 1] = 0.1f * sinf((float)(2 * M_PI * fmod(freq * (double)wr / rate, 1.0)));
            }
            atomic_store_explicit(&H->outWritten, wr, memory_order_release);
        }
        usleep(5000);
    }
    atomic_store(&H->ioClients, 0);
    uint64_t n = atomic_load(&H->inWritten);
    unsigned rate2 = atomic_load(&H->sampleRate);
    printf("after %.1f s: in written %llu (%.2f s), in late %llu, out late %llu, state %u, rate %u\n", secs, (unsigned long long)n, (double)n / rate2,
           (unsigned long long)atomic_load(&H->inLate), (unsigned long long)atomic_load(&H->outLate), atomic_load(&H->state), rate2);
    if (n < (uint64_t)rate2 * 2) { printf("not enough input to analyse\n"); return 1; }
    const float *in = gsr_in_ring(H);
    uint64_t from = n - rate2;            // last second
    for (int c = 0; c < GSR_MAX_CH; c++) {
        double s2 = 0, prev = 0; unsigned cross = 0;
        for (uint64_t i = 0; i < rate2; i++) {
            double v = in[((from + i) & mask) * GSR_MAX_CH + c];
            s2 += v * v; if (i && prev < 0 && v >= 0) cross++; prev = v;
        }
        double rms = sqrt(s2 / rate2);
        if (rms > 3e-5) printf("  in ch%2d: rms %6.1f dBFS, about %7.1f Hz  (%s)\n", c + 1, 20 * log10(rms), (double)cross, H->nameIn[c]);
    }
    if (lagA >= 1 && lagB >= 1) {
        int best = 0; double bc = -2;
        for (int lag = -24; lag <= 24; lag++) {
            double sab = 0, saa = 0, sbb = 0;
            for (uint64_t i = 100; i < 20000; i++) {
                double a = in[((from + i) & mask) * GSR_MAX_CH + lagA - 1], b = in[((from + i + lag) & mask) * GSR_MAX_CH + lagB - 1];
                sab += a * b; saa += a * a; sbb += b * b;
            }
            double cc = saa > 0 && sbb > 0 ? sab / sqrt(saa * sbb) : 0;
            if (cc > bc) { bc = cc; best = lag; }
        }
        printf("  channels %d and %d: best lag %d frames (correlation %.4f)\n", lagA, lagB, best, bc);
    }
    return 0;
}
