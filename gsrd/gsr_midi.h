// SPDX-License-Identifier: Apache-2.0
//
// MIDI through the card: the 17th quadlet of every data block of stream 0 (both directions) carries the bytes of up to eight
// multiplexed MIDI ports (AM824 "MIDI conformant" data).
//
//   quadlet = label(8) d1(8) d2(8) d3(8). Label 0x80 = nothing, 0x81 / 0x82 / 0x83 = that many bytes follow (d1, d2, d3).
//   The port a quadlet belongs to is the data block counter (DBC) of its block modulo 8.            (to be checked on the real card)
//
// The card's MIDI is a 31.25 kbaud link, so bytes are paced: at most one byte per port every 320 us.
//
// This module keeps three things apart so that none of them blocks the isochronous thread:
//   - capture: gsrm_rx() is called from the isochronous callback with the quadlet of a block; bytes go into a lock-free queue and
//     a dispatch source delivers them, as XPC messages, to the connections that subscribed;
//   - playback: gsrm_send() (any thread) fills a per-port byte queue; gsrm_patch() (isochronous thread) writes the next bytes into the
//     MIDI slots of packets that have not been sent yet;
//   - state for the app: gsrm_json().

#ifndef GSR_MIDI_H
#define GSR_MIDI_H

#include <stddef.h>
#include <stdint.h>
#include <xpc/xpc.h>

#define GSRM_PORTS 3                 // ports the card has on stream 0
#define GSRM_MUX 8                   // ports multiplexed in the slot

// ---- wire codec (pure functions, tested without hardware) ----

// Bytes carried by one MIDI quadlet (wire order). Returns 0 for "nothing" or an invalid label.
static inline int gsrm_decode(const uint8_t q[4], uint8_t out[3]) {
    if (q[0] < 0x81 || q[0] > 0x83) return 0;
    int n = q[0] & 3;
    for (int i = 0; i < n; i++) out[i] = q[1 + i];
    return n;
}

static inline void gsrm_encode(uint8_t q[4], const uint8_t *b, int n) {
    q[0] = (uint8_t)(0x80 + n);
    q[1] = n > 0 ? b[0] : 0; q[2] = n > 1 ? b[1] : 0; q[3] = n > 2 ? b[2] : 0;
}

// Port of the block with this data block counter.
static inline unsigned gsrm_port_of(uint32_t dbc) { return dbc & (GSRM_MUX - 1); }

// ---- engine ----

void gsrm_init(void);                                                    // once, before anything else
void gsrm_reset(void);                                                   // new stream session: forget queued output and pacing

// capture side, isochronous thread: the MIDI quadlet of the block whose data block counter is `dbc`
void gsrm_rx(const uint8_t *quadlet, uint32_t dbc);

// playback side
int gsrm_send(unsigned port, const uint8_t *data, size_t n);              // any thread; returns the number of bytes accepted
// Isochronous thread: put pending bytes into the idle MIDI slots of `nBlocks` consecutive blocks of one packet.
//   blocks: first block of the packet payload, blockBytes: size of a block, midiOffset: offset of the MIDI quadlet in a block,
//   dbc: data block counter of the first block, blockClock: running block count of the stream (advanced by nBlocks),
//   gap: blocks between two bytes of the same port (31.25 kbaud).
void gsrm_patch(uint8_t *blocks, unsigned blockBytes, unsigned midiOffset, unsigned nBlocks, uint8_t dbc, uint64_t *blockClock, unsigned gap);
unsigned gsrm_gap_for_rate(unsigned rate);                                // blocks per 320 us

// XPC: "midiSubscribe", "midiUnsubscribe", "midiSend". Returns 1 if `op` was one of them.
int gsrm_xpc(const char *op, xpc_object_t msg, xpc_object_t reply, xpc_connection_t peer);
void gsrm_peer_gone(xpc_connection_t peer);

// Counters for the app, as a JSON object fragment: "midi":{...}. Returns the new length.
size_t gsrm_json(char *buf, size_t cap, size_t n);

#endif
