// SPDX-License-Identifier: Apache-2.0
// Tests of gsr_midi.c without the card: wire codec, port numbering, 31.25 kbaud pacing, idle-slot rule, counters.
// Build and run: clang -O1 -Wall -Wextra -arch arm64 -o midi_test midi_test.c gsr_midi.c && ./midi_test
#include "gsr_midi.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

#define BLOCK 68            // 17 quadlets
#define MIDI_OFF 64         // the MIDI quadlet is the 17th

static void idle(uint8_t *p, unsigned blocks) {
    memset(p, 0, (size_t)blocks * BLOCK);
    for (unsigned b = 0; b < blocks; b++) p[b * BLOCK + MIDI_OFF] = 0x80;
}

int main(void) {
    gsrm_init();

    // codec
    uint8_t q[4], out[3] = {0};
    const uint8_t one[1] = {0x90};
    gsrm_encode(q, one, 1);
    CHECK(q[0] == 0x81 && q[1] == 0x90 && q[2] == 0 && q[3] == 0, "encode one byte");
    CHECK(gsrm_decode(q, out) == 1 && out[0] == 0x90, "decode one byte");
    const uint8_t three[3] = {0x90, 0x01, 0x7F};
    gsrm_encode(q, three, 3);
    CHECK(gsrm_decode(q, out) == 3 && out[0] == 0x90 && out[1] == 0x01 && out[2] == 0x7F, "decode three bytes");
    const uint8_t idleq[4] = {0x80, 0, 0, 0}, bad[4] = {0x84, 1, 2, 3}, junk[4] = {0x00, 1, 2, 3};
    CHECK(gsrm_decode(idleq, out) == 0 && gsrm_decode(bad, out) == 0 && gsrm_decode(junk, out) == 0, "idle and invalid labels give no bytes");
    CHECK(gsrm_port_of(0) == 0 && gsrm_port_of(9) == 1 && gsrm_port_of(250) == 2 && gsrm_port_of(7) == 7, "port numbering is dbc mod 8");
    CHECK(gsrm_gap_for_rate(48000) == 16 && gsrm_gap_for_rate(96000) == 31 && gsrm_gap_for_rate(44100) == 15, "gap %u %u %u", gsrm_gap_for_rate(48000), gsrm_gap_for_rate(96000), gsrm_gap_for_rate(44100));

    // playback: a console message on port 0, paced
    gsrm_reset();
    const uint8_t msg[] = {0x90, 0x6D, 0x7F, 0x80, 0x6E, 0x00};
    CHECK(gsrm_send(0, msg, sizeof msg) == (int)sizeof msg, "bytes accepted");
    CHECK(gsrm_send(5, msg, 1) == 0, "no such port");
    enum { PACKETS = 40, BLK = 8 };
    static uint8_t pkt[BLK * BLOCK];
    uint64_t clock = 0; uint8_t dbc = 0;
    uint8_t seen[64]; unsigned nSeen = 0; uint64_t when[64];
    unsigned gap = gsrm_gap_for_rate(48000);
    for (unsigned p = 0; p < PACKETS; p++) {
        idle(pkt, BLK);
        uint64_t before = clock;
        gsrm_patch(pkt, BLOCK, MIDI_OFF, BLK, dbc, &clock, gap);
        CHECK(clock == before + BLK, "block clock advances by the number of blocks");
        for (unsigned b = 0; b < BLK; b++) {
            const uint8_t *s = pkt + b * BLOCK + MIDI_OFF;
            if (s[0] == 0x81 && nSeen < 64) { seen[nSeen] = s[1]; when[nSeen++] = before + b; CHECK(gsrm_port_of((uint32_t)dbc + b) == 0, "byte put on the wrong port"); }
            else CHECK(s[0] == 0x80, "an untouched slot changed");
        }
        dbc = (uint8_t)(dbc + BLK);
    }
    CHECK(nSeen == sizeof msg && memcmp(seen, msg, sizeof msg) == 0, "all bytes, in order (%u of %zu)", nSeen, sizeof msg);
    for (unsigned i = 1; i < nSeen; i++) CHECK(when[i] - when[i - 1] >= gap, "31.25 kbaud pacing broken between byte %u and %u (%llu blocks)", i - 1, i, (unsigned long long)(when[i] - when[i - 1]));
    CHECK(nSeen == 0 || when[0] < 16, "first byte goes out at once (block %llu)", (unsigned long long)when[0]);

    // a slot that already carries something is left alone, the byte waits for the next one
    gsrm_reset();
    const uint8_t b0[1] = {0xF8};
    gsrm_send(1, b0, 1);
    idle(pkt, BLK);
    for (unsigned b = 0; b < BLK; b++) pkt[b * BLOCK + MIDI_OFF] = 0x81;      // all taken
    clock = 0; gsrm_patch(pkt, BLOCK, MIDI_OFF, BLK, 0, &clock, gap);
    int stolen = 0; for (unsigned b = 0; b < BLK; b++) if (pkt[b * BLOCK + MIDI_OFF + 1] != 0) stolen++;
    CHECK(stolen == 0, "a busy slot was overwritten");
    idle(pkt, BLK);
    gsrm_patch(pkt, BLOCK, MIDI_OFF, BLK, 8, &clock, gap);
    CHECK(pkt[1 * BLOCK + MIDI_OFF] == 0x81 && pkt[1 * BLOCK + MIDI_OFF + 1] == 0xF8, "waiting byte sent in port 1's next slot");

    // two ports at once do not disturb each other
    gsrm_reset();
    const uint8_t a[2] = {0xB0, 0x01}, c[2] = {0xB1, 0x02};
    gsrm_send(0, a, 2); gsrm_send(2, c, 2);
    unsigned got0 = 0, got2 = 0; clock = 0; dbc = 0;
    for (unsigned p = 0; p < 20; p++) {
        idle(pkt, BLK);
        gsrm_patch(pkt, BLOCK, MIDI_OFF, BLK, dbc, &clock, gap);
        for (unsigned b = 0; b < BLK; b++) { const uint8_t *s = pkt + b * BLOCK + MIDI_OFF; if (s[0] == 0x81) { if (gsrm_port_of((uint32_t)dbc + b) == 0) got0++; else if (gsrm_port_of((uint32_t)dbc + b) == 2) got2++; } }
        dbc = (uint8_t)(dbc + BLK);
    }
    CHECK(got0 == 2 && got2 == 2, "two ports independent (%u, %u)", got0, got2);

    // capture side counters
    uint8_t rxq[4]; const uint8_t note[3] = {0x90, 0x01, 0x7F};
    gsrm_encode(rxq, note, 3);
    for (uint32_t d = 0; d < 8; d++) gsrm_rx(rxq, d);           // the same message on every port number, to see the counters
    usleep(50000);
    char json[512]; size_t n = gsrm_json(json, sizeof json - 1, 0); json[n] = 0;
    CHECK(strstr(json, "\"in\":[3,3,3,3,3,3,3,3]") != NULL, "capture counters: %s", json);

    printf(fails ? "midi_test: %d failure(s)\n" : "midi_test: all checks passed\n", fails);
    return fails ? 1 : 0;
}
