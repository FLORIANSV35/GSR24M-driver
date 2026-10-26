// SPDX-License-Identifier: Apache-2.0
//
// gsrloop: milestone M3 test, playback to the card AND capture at the same time. The GS-R24 console returns
// card inputs 1 to 24 on the same channel numbers, so what we send comes back. The tool sends tones to the
// card's RX stream (one frequency per channel with --sweep, otherwise one tone on one channel), records the
// card's TX stream of the same index, then reports which tone came back on which channel, crosstalk, level
// and continuity.
//
// Packets sent follow the blocking AM824 cadence of the vendor driver: three data packets of one SYT
// interval of frames in every four bus cycles, the fourth packet empty (8 bytes, SYT 0xFFFF). Data packets
// carry a presentation time of send time + 0x2E00 ticks, advancing by 4096 ticks per data packet.
//
// Only volatile run-time registers are written (RX and TX stream ISOCHRONOUS, RX SEQ_START, TX SPEED, then
// GLOBAL ENABLE), all put back on exit, also on Ctrl-C. Never firmware. Level is limited to -10 dBFS.
//
// Build: clang -O1 -Wall -o gsrloop gsrloop.c -framework IOKit -framework CoreFoundation -lm
// Usage: ./gsrloop                       plan only
//        ./gsrloop --go [--sweep] [-c channel] [-l dBFS] [-t seconds] [-f Hz] [-s stream]

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/firewire/IOFireWireFamilyCommon.h>
#include <IOKit/firewire/IOFireWireLib.h>
#include <IOKit/firewire/IOFireWireLibIsoch.h>

#include <inttypes.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BASE_HI 0xFFFF
#define BASE_LO 0xE0000000u
#define RING 640                  // 80 ms; multiple of 4 so slot kind matches the cadence
#define MAX_PKT 2048
#define HDR_BYTES 4
#define MAX_CH 32
#define MAX_SECONDS 12

static IOFireWireLibDeviceRef gDev;
static io_object_t gSvc;
static UInt32 gGen;
static int gRetries;
static volatile sig_atomic_t gBusReset;   // set by the bus reset handler: stop, release everything, restore only if the card answers again
static int gBusResets, gCardGone;
static UInt32 gGenAtStart;             // bus generation when the streams were started; any change = bus reset
static double gForceResetAt = -1;      // test: ask the bus for a bus reset this many seconds after the start
static CFAbsoluteTime gBusResetAt;

static IOReturn rq(UInt32 off, UInt32 *v) {
    IOReturn r = kIOReturnError;
    for (int t = 0, n = gBusReset ? 2 : 10; t < n; t++) {
        UInt16 node; uint8_t b[4]; UInt32 sz = 4;
        (*gDev)->GetGenerationAndNodeID(gDev, &gGen, &node);
        FWAddress a = {0, BASE_HI, BASE_LO + off};
        r = (*gDev)->Read(gDev, gSvc, &a, b, &sz, true, gGen);
        if (r == kIOReturnSuccess) { *v = (UInt32)b[0] << 24 | (UInt32)b[1] << 16 | (UInt32)b[2] << 8 | b[3]; return r; }
        gRetries++; usleep(gBusReset ? 20000 : 50000);
    }
    return r;
}
static IOReturn wq(UInt32 off, UInt32 v) {
    IOReturn r = kIOReturnError;
    for (int t = 0, n = gBusReset ? 2 : 10; t < n; t++) {
        UInt16 node; UInt32 sz = 4;
        uint8_t b[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
        (*gDev)->GetGenerationAndNodeID(gDev, &gGen, &node);
        FWAddress a = {0, BASE_HI, BASE_LO + off};
        r = (*gDev)->Write(gDev, gSvc, &a, b, &sz, true, gGen);
        if (r == kIOReturnSuccess) return r;
        gRetries++; usleep(gBusReset ? 20000 : 50000);
    }
    return r;
}
static uint64_t propNum(io_object_t svc, CFStringRef key) {
    uint64_t v = 0;
    CFTypeRef t = IORegistryEntrySearchCFProperty(svc, kIOServicePlane, key, kCFAllocatorDefault,
                                                  kIORegistryIterateRecursively);
    if (t) { if (CFGetTypeID(t) == CFNumberGetTypeID()) CFNumberGetValue(t, kCFNumberSInt64Type, &v); CFRelease(t); }
    return v;
}

static const unsigned rateTable[] = {32000, 44100, 48000, 88200, 96000, 176400, 192000};

// ---- shared state --------------------------------------------------------------------------------------

static UInt32 gGlobalOff, gEnableReg;
static UInt32 gTxIso, gTxSpeed;      // capture stream register offsets
static int gTouched;
static volatile sig_atomic_t gStop;
static unsigned gRate, gSid;

// playback: one entry per RX stream of the card (stream 0 = inputs 1 to 16, stream 1 = 17 to 32)
typedef struct {
    unsigned idx, pcm, midi, dbs;
    UInt32 iso, seqReg;
    uint8_t *buf;
    uint32_t *slotLen;
    NuDCLRef *dcl;
    uint32_t *stamp;                 // cycle time stamp written by the DMA when a slot has been sent
    uint64_t seqNo, dataIdx, frame;
    uint64_t synced;                 // data packets sent with a computed SYT
    uint32_t dbc;
    uint64_t sent;
    IOFireWireLibRemoteIsochPortRef remote;
} PStream;
static PStream gP[2];
static unsigned gNP = 1;
static unsigned gBlocks;
static unsigned gL;                  // playback ring length in slots (one slot = one bus cycle)
static unsigned gLead = 320;         // slots generated ahead of the DMA (40 ms)
static uint8_t *gKind;               // per slot: 1 = data packet, 0 = empty packet (shared by all streams)
static int gSmux;                       // test: two consecutive samples of a channel in two adjacent slots
static unsigned gBlocksOverride;        // test: frames per data packet
static double gToneRate;                // test: rate used for the tone phase (default: card rate)
static int gFdfOverride = -1;          // test: force the FDF byte of the data packets
static int gLeadGiven;
static const char *gWavPath;          // --wav: save the captured channels (32-bit float WAV, short runs only)
static double gLeadTicks = 12800.0;   // wanted presentation time minus send time of the first synchronised packet
static int gSyncStarted;             // first synchronised data packet has been placed
static uint64_t gN0;                 // data packet number (same for every stream) that carries gT0tick
static double gAmp, gSecs;
static double gFreq[MAX_CH + 1];     // by global channel number 1..32
static int gTone[MAX_CH + 1];
static CFAbsoluteTime gLastCb, gMaxGap, gFirstSend, gStartCall;
static struct { double t, gap; } gBigGaps[10]; static unsigned gNBig;

// capture
static unsigned gCPcm, gCMidi, gCDbs;
static uint8_t *gCBuf;
static NuDCLRef gCDcl[RING];
static float *gCap[MAX_CH];
static uint64_t gCapFrames, gCapCap;
static uint64_t gCPackets, gCData, gCEmpty, gCBadCip, gCBadDbs, gCDbcJumps, gCStartup, gCShort;
static uint32_t gCLastDbc; static int gCHaveDbc;
static CFAbsoluteTime gCT0, gCT1;
// The card's own SYT timeline (ticks, unwrapped), used to align the playback stream to its sample grid.
static uint64_t gRxCnt;                  // data packets with a valid SYT seen so far
static uint64_t gRxFirstCnt; static double gRxFirstU, gRxU;
static uint32_t gRxPrevTicks; static int gRxHave;
static uint64_t gWinCnt[40]; static double gWinU[40]; static unsigned gWinN; static double gWinNext = 5.0;   // 5 s windows of the card SYT advance
static double gR = 4096.0, gT0tick;       // playback SYT(k) = gT0tick + k * gR  (ticks, modulo 49152)

static UInt32 gClockSelReg, gOrigClock;
static int gOwned;                     // we hold the card OWNER register (test option --owner)
static int gClockChanged;
static const unsigned rateTbl[] = {32000, 44100, 48000, 88200, 96000, 176400, 192000};

// Streaming level monitor on the last two captured channels (card 31 and 32): for every sent tone, amplitude per
// 0.5 s block (an integer number of cycles of every tone, 250 Hz x N, so no leakage). No raw audio is stored.
#define BLK_MAX 480
static int gStore;                     // keep raw samples (short runs only)
static unsigned gBlkLen;               // frames per block
static double *gCosT, *gSinT;          // [tone slot][frame in block]
static unsigned gMonTone[MAX_CH + 1], gMonN;
static double gAcc[2][MAX_CH + 1][2];
static unsigned gBlkPos, gBlkCnt;
static float gBlkLvl[2][MAX_CH + 1][BLK_MAX];

// 64-bit compare-swap on a card register (OWNER only accepts lock transactions).
static uint64_t gOwnerVal;
static int lock64(UInt32 off, uint64_t cmp, uint64_t nw) {
    UInt16 node; (*gDev)->GetGenerationAndNodeID(gDev, &gGen, &node);
    FWAddress a = {0, BASE_HI, BASE_LO + off};
    IOFireWireLibCommandRef cmd = (*gDev)->CreateCompareSwapCommand(
        gDev, gSvc, &a, 0, 0, NULL, true, gGen, NULL, CFUUIDGetUUIDBytes(kIOFireWireCompareSwapCommandInterfaceID_v3));
    if (!cmd) return -1;
    IOFireWireLibCompareSwapCommandV3Ref c3 = (IOFireWireLibCompareSwapCommandV3Ref)cmd;
    // The library passes 64-bit lock values through in bus order: give it the byte-swapped numbers.
    (*c3)->SetValues64(c3, __builtin_bswap64(cmp), __builtin_bswap64(nw));
    IOReturn r = (*cmd)->Submit(cmd);
    int ok = (r == kIOReturnSuccess) && (*c3)->DidLock(c3);
    (*cmd)->Release(cmd);
    return ok ? 0 : (r ? (int)r : 1);
}

static int gPreEnabled;   // vendor order: ENABLE already written before any DMA starts, so the port start handlers do nothing
static int gCleanup;     // --cleanup --go: put back what an aborted run left (stream channels -1, ENABLE 0, rate 48 kHz); nothing else
static int gKeepRate;    // --keeprate: leave the card at the requested rate at the end (used to put a card back after an aborted run)
static int gKeepClock;   // 1 during the SYT measurement pass: stop the streams but leave the card at the requested rate
static void restoreCard(void) {
    if (!gDev || !gTouched) return;
    if (gBusReset && !gCardGone) {
        // The bus was reset: give the card a few seconds to answer again, otherwise write nothing.
        UInt32 t = 0; int ok = 0;
        for (int i = 0; i < 15 && !ok; i++) { if (rq(gGlobalOff + 0x54, &t) == kIOReturnSuccess) ok = 1; else usleep(200000); }
        if (!ok) { gCardGone = 1; printf("  card does not answer after the bus reset: no register restored (ENABLE, channels, clock and owner were left as they were)\n"); }
    }
    if (gCardGone) { gClockChanged = 0; gOwned = 0; gTouched = 0; return; }
    wq(gEnableReg, 0);
    for (unsigned i = 0; i < gNP; i++) if (gP[i].iso) wq(gP[i].iso, 0xFFFFFFFFu);
    if (gTxIso) wq(gTxIso, 0xFFFFFFFFu);
    if (gOwned && !gKeepClock) { int lr = lock64(gGlobalOff, gOwnerVal, 0xFFFF000000000000ULL); gOwned = 0; printf("  OWNER released (%s)\n", lr == 0 ? "ok" : "failed"); }
    if (gClockChanged && gKeepRate && !gKeepClock) gClockChanged = 0;
    if (gClockChanged && !gKeepClock) {
        wq(gClockSelReg, gOrigClock);
        UInt32 code = (gOrigClock >> 8) & 0xFF, st = 0; int ok = 0;
        for (int t = 0; t < 3000 && !ok; t += 20) { if (!rq(gGlobalOff + 0x54, &st) && (st & 1) && ((st >> 8) & 0xFF) == code) ok = 1; else usleep(20000); }
        printf("  rate restored: %s\n", ok ? "locked" : "NOT LOCKED, check the card");
        gClockChanged = 0;
    }
    gTouched = gClockChanged ? 1 : 0;
}
static void onBusReset(IOFireWireLibDeviceRef self, FWClientCommandID id) {
    if (!gBusReset) gBusResetAt = CFAbsoluteTimeGetCurrent();
    gBusReset = 1; gBusResets++; gStop = 1;
    (*self)->ClientCommandIsComplete(self, id, kIOReturnSuccess);   // let the kernel finish its bus reset handling
    CFRunLoopStop(CFRunLoopGetMain());
}
static void onBusResetDone(IOFireWireLibDeviceRef self, FWClientCommandID id) {
    (*self)->ClientCommandIsComplete(self, id, kIOReturnSuccess);
}
static void onSignal(int s) { (void)s; gStop = 1; CFRunLoopStop(CFRunLoopGetMain()); }
static void put32(uint8_t *p, uint32_t q) { p[0] = q >> 24; p[1] = q >> 16; p[2] = q >> 8; p[3] = q; }

// ---- playback packets ------------------------------------------------------------------------------------

// Builds the packet for absolute slot number `seq`. `tSend` is its expected send time in ticks modulo
// 49152 (16 cycles), or a negative value while the send time is not known (start-up): data packets then
// carry SYT 0xFFFF, as ASFW does before it has the device clock.
static void buildPacket(PStream *ps, uint64_t seq, double tSend) {
    unsigned slot = (unsigned)(seq % gL);
    uint8_t *p = ps->buf + (size_t)slot * MAX_PKT;
    int empty = !gKind[slot];
    p[0] = gSid & 0x3F; p[1] = (uint8_t)ps->dbs; p[2] = 0; p[3] = (uint8_t)ps->dbc;
    p[4] = 0x90; p[5] = (uint8_t)(gFdfOverride >= 0 ? gFdfOverride : (gRate == 44100 ? 1 : gRate == 88200 ? 3 : gRate == 96000 ? 4 : 2));
    if (empty) { p[6] = 0xFF; p[7] = 0xFF; return; }
    uint32_t syt = 0xFFFF;
    if (tSend >= 0) {
        if (!gSyncStarted) {
            // first presentation time: first point of the card's grid at least 12800 ticks after the send time
            double target = fmod(tSend + gLeadTicks, 49152.0), tr = (double)gRxPrevTicks;
            unsigned m = 0;
            for (; m < 40; m++) if (fmod(tr + m * gR - target + 49152.0 * 4, 49152.0) < gR) break;
            gT0tick = fmod(tr + m * gR, 49152.0);
            gN0 = ps->dataIdx; gSyncStarted = 1;
        }
        // Same data packet number gives the same presentation time on every stream.
        double tout = gT0tick + (double)(ps->dataIdx - gN0) * gR;
        uint32_t tk = (uint32_t)fmod(tout, 49152.0);
        syt = ((tk / 3072) & 0xF) << 12 | (tk % 3072);
        ps->synced++;
    }
    p[6] = syt >> 8; p[7] = syt;
    uint8_t *q = p + 8;
    double fade = gRate * 0.1, total = gSecs * gRate;
    for (unsigned b = 0; b < gBlocks; b++, ps->frame++) {
        double t = (double)ps->frame, env = 1.0;
        if (t < fade) env = t / fade;
        if (t > total - fade) env = fmax(0.0, (total - t) / fade);
        if (t > total) env = 0;
        for (unsigned c = 0; c < ps->pcm; c++, q += 4) {
            unsigned g = ps->idx * 16 + c + 1;
            int32_t x = 0;
            if (gSmux) {
                // slots 2k and 2k+1 carry samples 2n and 2n+1 of one channel; the pair is driven by the odd numbered channel
                unsigned gg = ps->idx * 16 + (c & ~1u) + 1;
                double ts = 2.0 * t + (double)(c & 1);
                if (gg <= MAX_CH && gTone[gg]) x = (int32_t)lrint(gAmp * env * sin(2 * M_PI * gFreq[gg] * ts / (gToneRate > 0 ? gToneRate : (double)gRate)) * 8388607.0);
            } else if (g <= MAX_CH && gTone[g]) x = (int32_t)lrint(gAmp * env * sin(2 * M_PI * gFreq[g] * t / (gToneRate > 0 ? gToneRate : (double)gRate)) * 8388607.0);
            // DICE wire format as the TCAT drivers send it: 24-bit sample sign-extended over the whole
            // 32-bit slot, no AM824 label (negative samples start with 0xFF).
            put32(q, (uint32_t)x);
        }
        if (ps->midi) { put32(q, 0x80000000u); q += 4; }
    }
    ps->dbc = (ps->dbc + gBlocks) & 0xFF;
    ps->dataIdx++;
}

#define BATCH 8                                   // slots handled per callback (1 ms)
static void onSent(void *refcon, NuDCLRef dcl) {
    (void)dcl;
    unsigned si = (unsigned)((uintptr_t)refcon >> 16), slot = (unsigned)((uintptr_t)refcon & 0xFFFF);
    PStream *ps = &gP[si];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gLastCb > 0 && now - gLastCb > gMaxGap) gMaxGap = now - gLastCb;
    if (gLastCb > 0 && now - gLastCb > 0.03 && gNBig < 10) { gBigGaps[gNBig].t = now - gStartCall; gBigGaps[gNBig].gap = now - gLastCb; gNBig++; }
    gLastCb = now;
    if (gFirstSend == 0) gFirstSend = now;
    ps->sent += BATCH;
    // This callback is on the last slot of a batch of BATCH slots that have just gone out. The DMA wrote the cycle
    // time of that last slot into its stamp (seconds(7) cycle(13) offset(12)); slot (last - BATCH + 1 + k) went
    // out k cycles after the first one of the batch, and the packet for the slot gLead ahead of it goes out gLead
    // cycles after it.
    uint32_t st = ps->stamp[slot];
    uint64_t base = ps->seqNo;                         // absolute number of the first slot of this batch
    for (unsigned k = 0; k < BATCH; k++) {
        double tSend = -1;
        if (st) {
            uint32_t cyc = (st >> 12) & 0x1FFF, off = st & 0xFFF;
            long c = (long)cyc - (long)(BATCH - 1 - k) + (long)gLead;      // cycle at which the new packet goes out
            c = ((c % 16) + 16) % 16;
            tSend = (double)(c * 3072 + off);
        }
        buildPacket(ps, base + k + gLead, tSend);
    }
    ps->seqNo += BATCH;
}

// ---- capture packets ---------------------------------------------------------------------------------------

static void recvSlot(unsigned idx) {
    const uint8_t *p = gCBuf + (size_t)idx * MAX_PKT;
    gCPackets++;
    if (gCPackets == 1) gCT0 = CFAbsoluteTimeGetCurrent();
    gCT1 = CFAbsoluteTimeGetCurrent();
    int startup = (gCT1 - gCT0) < 0.25;
    uint32_t len = (uint32_t)p[2] | (uint32_t)p[3] << 8;
    const uint8_t *q = p + HDR_BYTES;
    if (len < 8 || len > MAX_PKT - HDR_BYTES) { if (startup) gCStartup++; else gCShort++; return; }
    if ((q[0] & 0xC0) != 0x00 || (q[4] & 0xC0) != 0x80 || (q[4] & 0x3F) != 0x10) { gCBadCip++; return; }
    uint32_t dbs = q[1], dbc = q[3];
    if (len == 8) { gCEmpty++; return; }
    if (dbs != gCDbs) { gCBadDbs++; return; }
    uint32_t blocks = (len - 8) / (dbs * 4);
    if (gCHaveDbc && (gCLastDbc & 0xFF) != dbc) { if (startup) gCStartup++; else gCDbcJumps++; }
    gCLastDbc = dbc + blocks; gCHaveDbc = 1;
    gCData++;
    {
        uint32_t sy = (uint32_t)q[6] << 8 | q[7];
        if (sy != 0xFFFF) {
            uint32_t tk = ((sy >> 12) & 0xF) * 3072 + (sy & 0xFFF);
            if (!gRxHave) { gRxHave = 1; gRxU = tk; }
            else gRxU += (tk + 49152 - gRxPrevTicks) % 49152;
            gRxPrevTicks = tk;
            if (gCT1 - gCT0 >= gWinNext && gWinN < 40) { gWinCnt[gWinN] = gRxCnt; gWinU[gWinN] = gRxU; gWinN++; gWinNext += 5.0; }
            if (gRxCnt == 200) { gRxFirstCnt = gRxCnt; gRxFirstU = gRxU; }   // skip the start-up packets
            gRxCnt++;
        }
    }
    const uint8_t *a = q + 8;
    for (uint32_t b = 0; b < blocks; b++, a += dbs * 4) {
        if (gBlkLen && gCPcm >= 2 && gBlkCnt < BLK_MAX) {
            for (unsigned ch = 0; ch < 2; ch++) {
                uint32_t c = gCPcm - 2 + ch;
                int32_t v = (int32_t)((uint32_t)a[c * 4 + 1] << 24 | (uint32_t)a[c * 4 + 2] << 16 | (uint32_t)a[c * 4 + 3] << 8);
                double x = (double)v / 2147483648.0;
                for (unsigned t = 0; t < gMonN; t++) {
                    gAcc[ch][t][0] += x * gCosT[(size_t)t * gBlkLen + gBlkPos];
                    gAcc[ch][t][1] += x * gSinT[(size_t)t * gBlkLen + gBlkPos];
                }
            }
            if (++gBlkPos == gBlkLen) {
                for (unsigned ch = 0; ch < 2; ch++)
                    for (unsigned t = 0; t < gMonN; t++) {
                        double re = gAcc[ch][t][0], im = gAcc[ch][t][1];
                        double amp = 2 * sqrt(re * re + im * im) / gBlkLen;
                        gBlkLvl[ch][t][gBlkCnt] = (float)(amp > 0 ? 20 * log10(amp) : -200);
                        gAcc[ch][t][0] = gAcc[ch][t][1] = 0;
                    }
                gBlkPos = 0; gBlkCnt++;
            }
        }
        if (gStore && gCapFrames < gCapCap)
            for (uint32_t c = 0; c < gCPcm && c < MAX_CH; c++) {
                int32_t v = (int32_t)((uint32_t)a[c * 4 + 1] << 24 | (uint32_t)a[c * 4 + 2] << 16 | (uint32_t)a[c * 4 + 3] << 8);
                gCap[c][gCapFrames] = (float)((double)v / 2147483648.0);
            }
        gCapFrames++;
    }
}

static void onRecv(void *refcon, NuDCLRef dcl) {
    (void)dcl;
    unsigned last = (unsigned)(uintptr_t)refcon;       // last slot of a batch of 8
    for (unsigned k = 0; k < 8; k++) recvSlot((last + RING - 7 + k) % RING);
}

// ---- remote ports ---------------------------------------------------------------------------------------------

static IOFireWireLibRemoteIsochPortRef gTxRemote;
static PStream *psOf(IOFireWireLibIsochPortRef self) {
    for (unsigned i = 0; i < gNP; i++) if ((void *)gP[i].remote == (void *)self) return &gP[i];
    return NULL;
}
static IOReturn rpGetSupported(IOFireWireLibIsochPortRef self, IOFWSpeed *sp, UInt64 *ch) {
    (void)self; *sp = kFWSpeed400MBit; *ch = 0xFFFFFFFFFFFFFFFFULL; return kIOReturnSuccess;
}
static IOReturn rpAllocate(IOFireWireLibIsochPortRef self, IOFWSpeed speed, UInt32 chan) {
    gTouched = 1;
    PStream *ps = psOf(self);
    if (ps) {
        printf("  playback stream %u: channel %u allocated\n", ps->idx, chan);
        IOReturn r = wq(ps->iso, chan);
        return r ? r : wq(ps->seqReg, 0);
    }
    printf("  capture channel %u allocated\n", chan);
    IOReturn r = wq(gTxIso, chan);
    return r ? r : wq(gTxSpeed, (UInt32)speed);
}
static IOReturn rpRelease(IOFireWireLibIsochPortRef self) {
    PStream *ps = psOf(self);
    wq(ps ? ps->iso : gTxIso, 0xFFFFFFFFu); return kIOReturnSuccess;
}
static IOReturn rpStart(IOFireWireLibIsochPortRef self) { (void)self; if (gPreEnabled) return kIOReturnSuccess; usleep(2000); gTouched = 1; return wq(gEnableReg, 1); }
static IOReturn rpStop(IOFireWireLibIsochPortRef self) { (void)self; return wq(gEnableReg, 0); }

static int die(const char *what, IOReturn r) {
    fprintf(stderr, "FAILED: %s (IOReturn 0x%08x)\n", what, (unsigned)r);
    restoreCard();
    return 1;
}

// ---- analysis ------------------------------------------------------------------------------------------------------

// Amplitude (0..1 full scale) of frequency f in x[from, from+n), Hann windowed, by direct correlation.
static double toneAmp(const float *x, uint64_t from, uint64_t n, double f, unsigned rate) {
    double re = 0, im = 0, wsum = 0;
    double w0 = 2 * M_PI * f / rate;
    for (uint64_t i = 0; i < n; i++) {
        double w = 0.5 - 0.5 * cos(2 * M_PI * (double)i / (double)n);
        double v = x[from + i] * w;
        re += v * cos(w0 * (double)i); im += v * sin(w0 * (double)i); wsum += w;
    }
    return 2 * sqrt(re * re + im * im) / wsum;
}
static double db(double v) { return v > 0 ? 20 * log10(v) : -200; }

int main(int argc, char **argv) {
    int go = 0, sweep = 0, noplay = 0, showNames = 0, takeOwner = 1, ourOrder = 0; unsigned reqRate = 0, cidx = 99, toneCh = 0, upto = 0, sidx = 0; double level = -40; gSecs = 3; double freq1 = 1000;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--go")) go = 1;
        else if (!strcmp(argv[i], "--sweep")) sweep = 1;
        else if (!strcmp(argv[i], "--noplay")) noplay = 1;
        else if (!strcmp(argv[i], "-r") && i + 1 < argc) reqRate = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--lead") && i + 1 < argc) { gLeadTicks = atof(argv[++i]); gLeadGiven = 1; }
        else if (!strcmp(argv[i], "--wav") && i + 1 < argc) gWavPath = argv[++i];
        else if (!strcmp(argv[i], "--names")) showNames = 1;
        else if (!strcmp(argv[i], "--owner")) takeOwner = 1;
        else if (!strcmp(argv[i], "--busreset-at") && i + 1 < argc) gForceResetAt = atof(argv[++i]);
        else if (!strcmp(argv[i], "--keeprate")) gKeepRate = 1;
        else if (!strcmp(argv[i], "--cleanup")) gCleanup = 1;
        else if (!strcmp(argv[i], "--noowner")) takeOwner = 0;       // default is to take OWNER like the vendor driver
        else if (!strcmp(argv[i], "--ourorder")) ourOrder = 1;       // old start order: capture first, ENABLE from the port start handler
        else if (!strcmp(argv[i], "--fdf") && i + 1 < argc) gFdfOverride = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--smux")) gSmux = 1;
        else if (!strcmp(argv[i], "--blocks") && i + 1 < argc) gBlocksOverride = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--tonerate") && i + 1 < argc) gToneRate = atof(argv[++i]);
        else if (!strcmp(argv[i], "--upto") && i + 1 < argc) upto = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "-c") && i + 1 < argc) toneCh = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "-l") && i + 1 < argc) level = atof(argv[++i]);
        else if (!strcmp(argv[i], "-t") && i + 1 < argc) gSecs = atof(argv[++i]);
        else if (!strcmp(argv[i], "-f") && i + 1 < argc) freq1 = atof(argv[++i]);
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) sidx = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "-C") && i + 1 < argc) cidx = (unsigned)atoi(argv[++i]);
    }
    if (!gLeadGiven && reqRate >= 88200) gLeadTicks = 4500.0;   // 88.2/96 kHz: the card accepts only a short lead (3000 to 6000 ticks, measured)
    if (level > -10) level = -10;
    if (gSecs > 150) gSecs = 150;
    gStore = gSecs <= 20;                           // raw samples only for short runs; long runs use the streaming monitor
    gAmp = pow(10.0, level / 20.0);
    if (sweep && !upto) upto = 16;
    if (upto > MAX_CH) upto = MAX_CH;
    gNP = upto > 16 ? 2 : 1;                         // --upto 17 or more plays to both RX streams
    if (noplay) gNP = 0;                              // capture only, to compare the card state

    io_iterator_t it;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFireWireDevice"), &it);
    io_object_t svc, chosen = 0;
    while ((svc = IOIteratorNext(it))) {
        uint64_t guid = propNum(svc, CFSTR("GUID"));
        if (!chosen && ((guid >> 40) == 0x0004C4 || propNum(svc, CFSTR("Unit_Spec_ID")) == 1220) &&
            ((guid >> 22) & 0x3FF) == 1) { chosen = svc; continue; }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    if (!chosen) { fprintf(stderr, "No GS-R24 found on the FireWire bus.\n"); return 2; }

    IOCFPlugInInterface **plug = NULL; SInt32 score;
    if (IOCreatePlugInInterfaceForService(chosen, kIOFireWireLibTypeID, kIOCFPlugInInterfaceID, &plug, &score) ||
        (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOFireWireDeviceInterfaceID_v9), (LPVOID *)&gDev) != S_OK)
        return die("open device interface", 0);
    (*plug)->Release(plug);
    gSvc = chosen;
    IOReturn r = (*gDev)->Open(gDev);
    for (int i = 0; r == kIOReturnExclusiveAccess && i < 200; i++) { usleep(1000); r = (*gDev)->Open(gDev); }
    if (r) return die("Open", r);
    signal(SIGINT, onSignal); signal(SIGTERM, onSignal);

    UInt32 t[6];
    for (int i = 0; i < 6; i++) if ((r = rq(i * 4, &t[i]))) return die("read section table", r);
    gGlobalOff = t[0] * 4; UInt32 txOff = t[2] * 4, rxOff = t[4] * 4;
    UInt32 nTx, nRx, txBlkQ, rxBlkQ, enable, status, clkSel;
    if (rq(txOff, &nTx) || rq(txOff + 4, &txBlkQ) || rq(rxOff, &nRx) || rq(rxOff + 4, &rxBlkQ)) return die("read stream headers", 0);
    gEnableReg = gGlobalOff + 0x50;
    rq(gEnableReg, &enable); rq(gGlobalOff + 0x54, &status); rq(gGlobalOff + 0x4C, &clkSel);
    if (gCleanup) {
        // Only registers this tool writes: ISOCHRONOUS of every stream, ENABLE, and the rate field of CLOCK_SELECT.
        printf("Cleanup: ENABLE %u, CLOCK_SELECT 0x%08x\n", enable, clkSel);
        if (!go) { printf("Dry run. Add --go to write: ISOCHRONOUS = -1 on %u TX and %u RX streams, ENABLE = 0, rate 48 kHz.\n", nTx, nRx); return 0; }
        gTouched = 0;
        if (enable) wq(gEnableReg, 0);
        for (UInt32 i = 0; i < nTx; i++) { UInt32 v = 0, a = txOff + 8 + i * txBlkQ * 4; rq(a, &v); printf("  TX %u ISOCHRONOUS 0x%08x -> -1\n", i, v); if (v != 0xFFFFFFFFu) wq(a, 0xFFFFFFFFu); }
        for (UInt32 i = 0; i < nRx; i++) { UInt32 v = 0, a = rxOff + 8 + i * rxBlkQ * 4; rq(a, &v); printf("  RX %u ISOCHRONOUS 0x%08x -> -1\n", i, v); if (v != 0xFFFFFFFFu) wq(a, 0xFFFFFFFFu); }
        if (((clkSel >> 8) & 0xFF) != 2) { wq(gGlobalOff + 0x4C, (clkSel & ~0xFF00u) | (2u << 8)); printf("  rate -> 48 kHz\n"); }
        usleep(500000);
        UInt32 st = 0, cs = 0; rq(gGlobalOff + 0x54, &st); rq(gGlobalOff + 0x4C, &cs);
        printf("After: STATUS 0x%08x CLOCK_SELECT 0x%08x\n", st, cs);
        return 0;
    }
    if (cidx == 99) cidx = sidx;
    if (cidx >= nTx || gNP > nRx) { fprintf(stderr, "Stream does not exist.\n"); return 3; }
    unsigned first = 0;                                   // first RX stream used
    if (!upto) first = toneCh ? (toneCh - 1) / 16 : sidx;
    for (unsigned i = 0; i < gNP; i++) {
        PStream *ps = &gP[i];
        UInt32 rb = rxOff + 8 + (first + i) * rxBlkQ * 4, iso = 0, pcm = 0, midi = 0;
        rq(rb, &iso); rq(rb + 8, &pcm); rq(rb + 0xC, &midi);     // RX block: ISO, SEQ_START, AUDIO, MIDI
        ps->idx = first + i; ps->iso = rb; ps->seqReg = rb + 4;
        ps->pcm = pcm; ps->midi = midi; ps->dbs = pcm + (midi ? 1 : 0);
        if (iso != 0xFFFFFFFFu) { fprintf(stderr, "RX stream %u is already configured; not touching the card.\n", ps->idx); return 3; }
        if (pcm == 0 || pcm > MAX_CH) { fprintf(stderr, "Unexpected RX stream layout.\n"); return 3; }
    }
    UInt32 tb = txOff + 8 + cidx * txBlkQ * 4, txIsoV = 0, txPcm = 0, txMidi = 0;
    rq(tb, &txIsoV); rq(tb + 4, &txPcm); rq(tb + 8, &txMidi);   // TX block: ISO, AUDIO, MIDI, SPEED
    gTxIso = tb; gTxSpeed = tb + 0xC;
    gCPcm = txPcm; gCMidi = txMidi; gCDbs = txPcm + (txMidi ? 1 : 0);
    unsigned rateIdx = (clkSel >> 8) & 0xFF;
    gRate = rateIdx < 7 ? rateTable[rateIdx] : 0;
    gBlocks = gRate <= 48000 ? 8 : gRate <= 96000 ? 16 : 32;

    unsigned nTones = 0;
    if (upto) { for (unsigned g = 1; g <= upto; g++) { gTone[g] = 1; gFreq[g] = 250.0 * g; nTones++; } }
    else if (toneCh >= 1 && toneCh <= MAX_CH) { gTone[toneCh] = 1; gFreq[toneCh] = freq1; nTones = 1; }

    printf("GS-R24 found. Rate %u Hz, locked=%s.\n", gRate, (status & 1) ? "yes" : "no");
    for (unsigned i = 0; i < gNP; i++)
        printf("  playback RX stream %u: %u PCM + %u MIDI (DBS %u), card inputs %u to %u\n", gP[i].idx, gP[i].pcm, gP[i].midi, gP[i].dbs, gP[i].idx * 16 + 1, gP[i].idx * 16 + gP[i].pcm);
    printf("  capture TX stream %u: %u PCM + %u MIDI (DBS %u), card channels %u to %u\n", cidx, gCPcm, txMidi, gCDbs, cidx * 16 + 1, cidx * 16 + gCPcm);
    if (upto) printf("Plan: %u tones, channel N at 250 Hz x N, %.0f dBFS each, %.1f s with 0.1 s fades. Registers written: RX and TX stream ISOCHRONOUS, RX SEQ_START, TX SPEED, ENABLE; all put back.\n", nTones, level, gSecs);
    else printf("Plan: one tone of %.0f Hz on channel %u at %.0f dBFS for %.1f s. Registers written: RX and TX stream ISOCHRONOUS, RX SEQ_START, TX SPEED, ENABLE; all put back.\n", freq1, toneCh, level, gSecs);
    if (!go) { printf("Dry run. Add --go to do it. Turn the monitors down first.\n"); return 0; }
    if (enable != 0 || txIsoV != 0xFFFFFFFFu) { fprintf(stderr, "Card is already streaming or configured; not touching it.\n"); return 3; }
    if (gRate != 44100 && gRate != 48000 && gRate != 88200 && gRate != 96000) { fprintf(stderr, "Rate not supported here.\n"); return 3; }
    if (gCPcm == 0 || gCPcm > MAX_CH) { fprintf(stderr, "Unexpected capture stream layout.\n"); return 3; }

    // Test option: take the OWNER register like the vendor driver does (owner = node id and a notification
    // address; the card writes its notifications there). The address space answers writes automatically.
    if (takeOwner) {
        static uint8_t backing[64];
        IOFireWireLibPseudoAddressSpaceRef pas = (*gDev)->CreatePseudoAddressSpace(
            gDev, sizeof backing, NULL, 0, backing, kFWAddressSpaceAutoWriteReply | kFWAddressSpaceAutoReadReply,
            CFUUIDGetUUIDBytes(kIOFireWirePseudoAddressSpaceInterfaceID));
        if (!pas) return die("CreatePseudoAddressSpace", 0);
        (*gDev)->AddCallbackDispatcherToRunLoop(gDev, CFRunLoopGetMain());
        FWAddress na; (*pas)->GetFWAddress(pas, &na);
        UInt32 o0 = 0, o1 = 0; rq(gGlobalOff, &o0); rq(gGlobalOff + 4, &o1);
        if (o0 != 0xFFFF0000u || o1 != 0) { fprintf(stderr, "OWNER is already taken (0x%08x%08x).\n", o0, o1); return 3; }
        UInt16 ln = 0; (*gDev)->GetLocalNodeID(gDev, &ln);                 // full 16-bit local node id, as the vendor driver stores
        printf("  notification address space: node 0x%04x, address 0x%04x:%08x; local node id 0x%04x\n", na.nodeID, na.addressHi, na.addressLo, ln);
        uint64_t ov = (uint64_t)ln << 48 | (uint64_t)na.addressHi << 32 | na.addressLo;
        gTouched = 1;
        int lr = lock64(gGlobalOff, 0xFFFF000000000000ULL, ov);
        if (lr) return die("lock OWNER", (IOReturn)lr);
        gOwnerVal = ov; gOwned = 1;
        rq(gGlobalOff, &o0); rq(gGlobalOff + 4, &o1);
        printf("OWNER taken: 0x%08x%08x (notification address %04x:%04x:%08x)\n", o0, o1, na.nodeID, na.addressHi, na.addressLo);
    }
    // Optional change of the card's sample rate (CLOCK_SELECT), put back at the end.
    if (reqRate && reqRate != gRate) {
        unsigned code = 99;
        for (unsigned i = 0; i < 7; i++) if (rateTbl[i] == reqRate) code = i;
        UInt32 caps = 0; rq(gGlobalOff + 0x64, &caps);
        if (code == 99 || !(caps & (1u << code)) || (reqRate != 44100 && reqRate != 48000 && reqRate != 88200 && reqRate != 96000)) { fprintf(stderr, "Rate %u Hz not available or not supported here.\n", reqRate); return 3; }
        gClockSelReg = gGlobalOff + 0x4C; gOrigClock = clkSel; gTouched = 1; gClockChanged = 1;
        if ((r = wq(gClockSelReg, (clkSel & ~0xFF00u) | (code << 8)))) return die("write CLOCK_SELECT", r);
        int ok = 0; UInt32 st = 0;
        for (int t = 0; t < 3000 && !ok; t += 20) { if (!rq(gGlobalOff + 0x54, &st) && (st & 1) && ((st >> 8) & 0xFF) == code) ok = 1; else usleep(20000); }
        if (!ok) { fprintf(stderr, "The card did not lock at %u Hz.\n", reqRate); restoreCard(); return 3; }
        gRate = reqRate; gBlocks = gRate <= 48000 ? 8 : gRate <= 96000 ? 16 : 32;
        if (gBlocksOverride) gBlocks = gBlocksOverride;
        for (unsigned i = 0; i < gNP; i++) {
            UInt32 pcm = 0, midi = 0; rq(gP[i].iso + 8, &pcm); rq(gP[i].iso + 0xC, &midi);
            gP[i].pcm = pcm; gP[i].midi = midi; gP[i].dbs = pcm + (midi ? 1 : 0);
        }
        UInt32 cp = 0, cm = 0; rq(gTxIso + 4, &cp); rq(gTxIso + 8, &cm);
        gCPcm = cp; gCMidi = cm; gCDbs = cp + (cm ? 1 : 0);
        unsigned oc = (gOrigClock >> 8) & 0xFF, oldRate = oc < 7 ? rateTbl[oc] : 0;
        printf("Card locked at %u Hz (it will be put back to %u Hz). Playback streams: %u PCM + %u MIDI and %u PCM + %u MIDI; capture %u PCM + %u MIDI.\n",
               gRate, oldRate, gNP > 0 ? gP[0].pcm : 0, gNP > 0 ? gP[0].midi : 0, gNP > 1 ? gP[1].pcm : 0, gNP > 1 ? gP[1].midi : 0, gCPcm, gCMidi);
        if (gCPcm < 2 || (gNP > 0 && gP[0].pcm == 0)) { fprintf(stderr, "Unexpected layout at this rate.\n"); restoreCard(); return 3; }
    }
    if (showNames) {
        // Channel names the card announces at the current rate, for every stream block (text is byte-swapped in each quadlet).
        for (int dir = 0; dir < 2; dir++) {
            UInt32 off = dir == 0 ? txOff : rxOff, blkQ2 = dir == 0 ? txBlkQ : rxBlkQ, n = dir == 0 ? nTx : nRx;
            for (UInt32 si2 = 0; si2 < n; si2++) {
                UInt32 b0 = off + 8 + si2 * blkQ2 * 4, aud = 0, mid = 0;
                rq(b0 + (dir == 0 ? 4 : 8), &aud); rq(b0 + (dir == 0 ? 8 : 0xC), &mid);
                uint8_t raw[256];
                for (int i = 0; i < 64; i++) { UInt32 w = 0; rq(b0 + 0x10 + i * 4, &w); raw[i*4] = w >> 24; raw[i*4+1] = w >> 16; raw[i*4+2] = w >> 8; raw[i*4+3] = w; }
                for (int i = 0; i + 3 < 256; i += 4) { uint8_t t0 = raw[i], t1 = raw[i+1]; raw[i] = raw[i+3]; raw[i+1] = raw[i+2]; raw[i+2] = t1; raw[i+3] = t0; }
                raw[255] = 0;
                printf("  %s stream %u at %u Hz: %u audio, %u midi. Names: ", dir == 0 ? "TX" : "RX", si2, gRate, aud, mid);
                for (int i = 0; i < 256 && raw[i]; i++) putchar(raw[i] == '\\' ? '|' : raw[i]);
                printf("\n");
            }
        }
    }
    // Streaming monitor tables: 0.5 s blocks, one cos/sin table per sent tone.
    gBlkLen = gRate / 2; gMonN = 0;
    for (unsigned g = 1; g <= MAX_CH; g++) if (gTone[g]) gMonTone[gMonN++] = g;
    gCosT = malloc((size_t)(gMonN ? gMonN : 1) * gBlkLen * sizeof(double));
    gSinT = malloc((size_t)(gMonN ? gMonN : 1) * gBlkLen * sizeof(double));
    for (unsigned t = 0; t < gMonN; t++)
        for (unsigned i = 0; i < gBlkLen; i++) {
            double ph = 2 * M_PI * gFreq[gMonTone[t]] * (double)i / gRate;
            gCosT[(size_t)t * gBlkLen + i] = cos(ph); gSinT[(size_t)t * gBlkLen + i] = sin(ph);
        }

    UInt16 localNode = 0; (*gDev)->GetLocalNodeID(gDev, &localNode); gSid = localNode & 0x3F;
    (*gDev)->AddCallbackDispatcherToRunLoop(gDev, CFRunLoopGetMain());
    (*gDev)->AddIsochCallbackDispatcherToRunLoop(gDev, CFRunLoopGetMain());
    (*gDev)->SetBusResetHandler(gDev, onBusReset);
    (*gDev)->SetBusResetDoneHandler(gDev, onBusResetDone);

    // capture ring and storage
    gCapCap = gStore ? (uint64_t)(gSecs + 3.5) * gRate : 0;
    if (gStore) for (unsigned c = 0; c < gCPcm; c++) gCap[c] = calloc(gCapCap, sizeof(float));
    IOFireWireLibNuDCLPoolRef cpool = (*gDev)->CreateNuDCLPool(gDev, RING * 4, CFUUIDGetUUIDBytes(kIOFireWireNuDCLPoolInterfaceID));
    if (!cpool) return die("CreateNuDCLPool (capture)", 0);
    gCBuf = calloc(RING, MAX_PKT);
    for (unsigned i = 0; i < RING; i++) {
        IOVirtualRange rg = {(IOVirtualAddress)(gCBuf + (size_t)i * MAX_PKT), MAX_PKT};
        gCDcl[i] = (NuDCLRef)(*cpool)->AllocateReceivePacket(cpool, NULL, HDR_BYTES, 1, &rg);
        if (!gCDcl[i]) return die("AllocateReceivePacket", i);
        if (i % 8 == 7) {
            (*cpool)->SetDCLRefcon(gCDcl[i], (void *)(uintptr_t)i);
            (*cpool)->SetDCLCallback(gCDcl[i], onRecv);
        }
    }
    for (unsigned i = 0; i < RING; i++) (*cpool)->SetDCLBranch(gCDcl[i], gCDcl[(i + 1) % RING]);
    IOFireWireLibLocalIsochPortRef cLocal = (*gDev)->CreateLocalIsochPort(
        gDev, false, (*cpool)->GetProgram(cpool), 0, 0, 0, NULL, 0, NULL, 0, CFUUIDGetUUIDBytes(kIOFireWireLocalIsochPortInterfaceID));
    if (!cLocal) return die("CreateLocalIsochPort (capture)", 0);
    gTxRemote = (*gDev)->CreateRemoteIsochPort(gDev, true, CFUUIDGetUUIDBytes(kIOFireWireRemoteIsochPortInterfaceID));
    if (!gTxRemote) return die("CreateRemoteIsochPort (capture)", 0);
    (*gTxRemote)->SetGetSupportedHandler(gTxRemote, rpGetSupported);
    (*gTxRemote)->SetAllocatePortHandler(gTxRemote, rpAllocate);
    (*gTxRemote)->SetReleasePortHandler(gTxRemote, rpRelease);
    (*gTxRemote)->SetStartHandler(gTxRemote, rpStart);
    (*gTxRemote)->SetStopHandler(gTxRemote, rpStop);
    IOFireWireLibIsochChannelRef cChan = (*gDev)->CreateIsochChannel(gDev, true, 8 + gBlocks * gCDbs * 4, kFWSpeed400MBit,
                                                                     CFUUIDGetUUIDBytes(kIOFireWireIsochChannelInterfaceID));
    if (!cChan) return die("CreateIsochChannel (capture)", 0);
    (*cChan)->SetTalker(cChan, (IOFireWireLibIsochPortRef)gTxRemote);
    (*cChan)->AddListener(cChan, (IOFireWireLibIsochPortRef)cLocal);

    // ---- 1. Listen to the card alone for 0.6 s to measure how fast its SYT timeline really advances.
    // The playback ring is then built so that its data/empty pattern follows that rate exactly.
    if (gNP) {
        printf("Measuring the card's SYT timeline...\n");
        if ((r = (*cChan)->AllocateChannel(cChan))) { restoreCard(); return die("AllocateChannel (measure)", r); }
        if ((r = (*cChan)->Start(cChan))) { (*cChan)->ReleaseChannel(cChan); restoreCard(); return die("Start (measure)", r); }
        CFAbsoluteTime tm = CFAbsoluteTimeGetCurrent();
        while (CFAbsoluteTimeGetCurrent() - tm < 0.6) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
        (*cChan)->Stop(cChan); gKeepClock = 1; restoreCard(); gKeepClock = 0; (*cChan)->ReleaseChannel(cChan);
        if (gRxCnt < 1500) return die("not enough card packets to measure its SYT timeline", (IOReturn)gRxCnt);
        gR = (gRxU - gRxFirstU) / (double)(gRxCnt - 1 - gRxFirstCnt);
        printf("  card SYT advance: %.4f ticks per data packet (%+.1f ppm against 4096)\n", gR, (gR / 4096.0 - 1) * 1e6);
        usleep(300000);
        // capture counters restart for the real run
        gCPackets = gCData = gCEmpty = gCBadCip = gCBadDbs = gCDbcJumps = gCStartup = gCShort = 0;
        gCHaveDbc = 0; gCapFrames = 0; gRxHave = 0; gCT0 = 0;
    }

    // ---- 2. Ring length and slot pattern: a lap of gL cycles holds a whole number of data packets at the card's
    // rate, so the pattern repeats without drift. DDA: a cycle adds 3072 ticks of credit, a data packet costs gR.
    if (gNP) {
        unsigned bestL = 8000; double bestRes = 1e9;
        for (unsigned L = 6000; L <= 12000; L += 8) {
            double q = L * 3072.0 / gR, res = fabs(q - round(q));
            if (res < bestRes) { bestRes = res; bestL = L; }
        }
        gL = bestL;
        gKind = calloc(gL, 1);
        double cr = gR * 0.5; unsigned nData = 0;      // half a packet of credit so each lap has round(q) packets
        for (unsigned i = 0; i < gL; i++) { cr += 3072.0; if (cr >= gR) { gKind[i] = 1; cr -= gR; nData++; } }
        printf("  playback ring: %u cycles (%.3f s), %u data packets per lap (%.2f per second), residual %.3f packets\n",
               gL, gL / 8000.0, nData, nData * 8000.0 / gL, bestRes);
        if (gLead * 2 > gL) gLead = gL / 4;
    }

    // ---- 3. Playback rings.
    IOFireWireLibIsochChannelRef pChan[2] = {NULL, NULL};
    for (unsigned si = 0; si < gNP; si++) {
        PStream *ps = &gP[si];
        IOFireWireLibNuDCLPoolRef pool = (*gDev)->CreateNuDCLPool(gDev, gL * 8, CFUUIDGetUUIDBytes(kIOFireWireNuDCLPoolInterfaceID));
        if (!pool) return die("CreateNuDCLPool", si);
        (*pool)->SetCurrentTagAndSync(pool, 1, 0);
        size_t pktBytes = (size_t)gL * MAX_PKT;
        ps->buf = calloc(1, pktBytes + (size_t)gL * sizeof(uint32_t) + 4096);   // packets, then the stamp array
        ps->stamp = (uint32_t *)(ps->buf + pktBytes);
        ps->slotLen = calloc(gL, sizeof(uint32_t));
        ps->dcl = calloc(gL, sizeof(NuDCLRef));
        for (unsigned i = 0; i < gL; i++) {
            ps->slotLen[i] = gKind[i] ? 8 + gBlocks * ps->dbs * 4 : 8;
            IOVirtualRange rg = {(IOVirtualAddress)(ps->buf + (size_t)i * MAX_PKT), ps->slotLen[i]};
            ps->dcl[i] = (NuDCLRef)(*pool)->AllocateSendPacket(pool, NULL, 1, &rg);
            if (!ps->dcl[i]) return die("AllocateSendPacket", i);
            if (i % BATCH == BATCH - 1) {
                (*pool)->SetDCLRefcon(ps->dcl[i], (void *)(uintptr_t)(si << 16 | i));
                (*pool)->SetDCLCallback(ps->dcl[i], onSent);
                (*pool)->SetDCLTimeStampPtr(ps->dcl[i], &ps->stamp[i]);
                (*pool)->AppendDCLUpdateList(ps->dcl[i], ps->dcl[i]);       // its callback refreshes its own stamp
                (*pool)->SetDCLFlags(ps->dcl[i], (1u << 1) | (1u << 2));    // dynamic + update before callback (values from IOFWDCL.h, not in the SDK headers)
            }
        }
        for (unsigned i = 0; i < gL; i++) (*pool)->SetDCLBranch(ps->dcl[i], ps->dcl[(i + 1) % gL]);
        ps->seqNo = 0; ps->dataIdx = 0; ps->dbc = 0; ps->frame = 0; ps->synced = 0;
        for (unsigned i = 0; i < gLead; i++) buildPacket(ps, i, -1);     // start-up: data packets without SYT
        IOVirtualRange whole = {(IOVirtualAddress)ps->buf, pktBytes + (size_t)gL * sizeof(uint32_t) + 4096};
        IOFireWireLibLocalIsochPortRef pLocal = (*gDev)->CreateLocalIsochPort(
            gDev, true, (*pool)->GetProgram(pool), 0, 0, 0, NULL, 0, &whole, 1,
            CFUUIDGetUUIDBytes(kIOFireWireLocalIsochPortInterfaceID));
        if (!pLocal) return die("CreateLocalIsochPort (playback)", si);
        ps->remote = (*gDev)->CreateRemoteIsochPort(gDev, false, CFUUIDGetUUIDBytes(kIOFireWireRemoteIsochPortInterfaceID));
        if (!ps->remote) return die("CreateRemoteIsochPort (playback)", si);
        (*ps->remote)->SetGetSupportedHandler(ps->remote, rpGetSupported);
        (*ps->remote)->SetAllocatePortHandler(ps->remote, rpAllocate);
        (*ps->remote)->SetReleasePortHandler(ps->remote, rpRelease);
        (*ps->remote)->SetStartHandler(ps->remote, rpStart);
        (*ps->remote)->SetStopHandler(ps->remote, rpStop);
        pChan[si] = (*gDev)->CreateIsochChannel(gDev, true, 8 + gBlocks * ps->dbs * 4, kFWSpeed400MBit,
                                                CFUUIDGetUUIDBytes(kIOFireWireIsochChannelInterfaceID));
        if (!pChan[si]) return die("CreateIsochChannel (playback)", si);
        (*pChan[si])->SetTalker(pChan[si], (IOFireWireLibIsochPortRef)pLocal);
        (*pChan[si])->AddListener(pChan[si], (IOFireWireLibIsochPortRef)ps->remote);
    }

    // ---- 4. Allocate everything first, so all streams are configured before ENABLE is written, then start.
    printf("Allocating channels...\n");
    if ((r = (*cChan)->AllocateChannel(cChan))) { restoreCard(); return die("AllocateChannel (capture)", r); }
    for (unsigned si = 0; si < gNP; si++)
        if ((r = (*pChan[si])->AllocateChannel(pChan[si]))) {
            for (unsigned j = 0; j < si; j++) (*pChan[j])->ReleaseChannel(pChan[j]);
            (*cChan)->ReleaseChannel(cChan); restoreCard(); return die("AllocateChannel (playback)", r);
        }
    printf("Starting...\n");
    gStartCall = CFAbsoluteTimeGetCurrent();
    if (ourOrder) {
        r = (*cChan)->Start(cChan);
        for (unsigned si = 0; si < gNP && !r; si++) r = (*pChan[si])->Start(pChan[si]);
    } else {
        // Vendor driver order (StartStreams): channels and speeds are in the card, ENABLE = 1 once, 2 ms, then the
        // send ports start, then the receive port.
        gTouched = 1;
        r = (IOReturn)wq(gEnableReg, 1);
        usleep(2000);
        gPreEnabled = 1;
        for (unsigned si = 0; si < gNP && !r; si++) r = (*pChan[si])->Start(pChan[si]);
        if (!r) r = (*cChan)->Start(cChan);
    }
    if (r) {
        for (unsigned si = 0; si < gNP; si++) (*pChan[si])->ReleaseChannel(pChan[si]);
        (*cChan)->ReleaseChannel(cChan); restoreCard(); return die("Start", r);
    }

    { UInt16 nd; (*gDev)->GetGenerationAndNodeID(gDev, &gGenAtStart, &nd); }
    // Run, and watch the card's own lock flags: EXTENDED_STATUS bit n (low half) = clock source n locked,
    // high half = slipped. Sources 8 to 11 (arx1 to arx4) are the card's receivers of the host streams.
    {
        static const char *srcId[] = {"aes1", "aes2", "aes3", "aes4", "aes_any", "adat", "tdif", "wc",
                                      "arx1", "arx2", "arx3", "arx4", "internal"};
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        UInt32 lastExt = 0xDEADBEEF, lastSt = 0xDEADBEEF;
        while (!gStop && CFAbsoluteTimeGetCurrent() - t0 < gSecs + 2.5) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
            if (gForceResetAt >= 0 && CFAbsoluteTimeGetCurrent() - t0 >= gForceResetAt) { gForceResetAt = -1; printf("  asking for a bus reset now\n"); (*gDev)->BusReset(gDev); }
            { UInt32 g = 0; UInt16 nd; (*gDev)->GetGenerationAndNodeID(gDev, &g, &nd);
              if (g != gGenAtStart && !gBusReset) { gBusReset = 1; gBusResets++; gStop = 1; gBusResetAt = CFAbsoluteTimeGetCurrent(); } }
            if (gBusReset) break;
            UInt32 ext = 0, st = 0;
            if (rq(gGlobalOff + 0x58, &ext) || rq(gGlobalOff + 0x54, &st)) continue;
            if (ext != lastExt || st != lastSt) {
                printf("  %.2f s: STATUS 0x%08x EXTENDED_STATUS 0x%08x  locked:", CFAbsoluteTimeGetCurrent() - t0, st, ext);
                for (int i = 0; i < 13; i++) if (ext & (1u << i)) printf(" %s", srcId[i]);
                printf("  slipped:");
                for (int i = 0; i < 13; i++) if (ext & (1u << (16 + i))) printf(" %s", srcId[i]);
                printf("\n");
                lastExt = ext; lastSt = st;
            }
        }
    }
    if (gBusReset) printf("BUS RESET detected %.2f s after the start: stopping the streams and releasing the resources.\n", gBusResetAt - gStartCall);
    printf("Stopping...\n");
    for (unsigned si = 0; si < gNP; si++) (*pChan[si])->Stop(pChan[si]);
    (*cChan)->Stop(cChan);
    restoreCard();
    for (unsigned si = 0; si < gNP; si++) (*pChan[si])->ReleaseChannel(pChan[si]);
    (*cChan)->ReleaseChannel(cChan);

    UInt32 en = 99, st2 = 0; if (!gCardGone) { rq(gEnableReg, &en); rq(gGlobalOff + 0x54, &st2); }
    uint64_t sentTotal = 0; for (unsigned i = 0; i < gNP; i++) sentTotal += gP[i].sent;
    printf("\nPlayback: %" PRIu64 " packets sent on %u stream(s), longest gap between send callbacks %.1f ms (ring 80 ms)\n", sentTotal, gNP, gMaxGap * 1000);
    for (unsigned i = 0; i < gNBig; i++) printf("  send callback gap of %.0f ms at %.2f s after Start()\n", gBigGaps[i].gap * 1000, gBigGaps[i].t);
    if (gFirstSend) printf("First playback packet sent %.0f ms after Start() (start cycle was requested 700 ms after the cycle-time read)\n", (gFirstSend - gStartCall) * 1000);
    if (gNP && gP[0].stamp) printf("DMA stamps of the first slots (raw): %u %u %u %u %u; synchronised data packets sent: %" PRIu64 "\n",
        gP[0].stamp[0], gP[0].stamp[1], gP[0].stamp[2], gP[0].stamp[3], gP[0].stamp[4], gP[0].synced);
    printf("Capture : %" PRIu64 " packets (data %" PRIu64 ", empty %" PRIu64 "), CIP errors %" PRIu64 ", DBS mismatches %" PRIu64
           ", DBC discontinuities %" PRIu64 ", short %" PRIu64 " (start-up events ignored: %" PRIu64 "), frames %" PRIu64 "\n",
           gCPackets, gCData, gCEmpty, gCBadCip, gCBadDbs, gCDbcJumps, gCShort, gCStartup, gCapFrames);

    // Look for every sent tone on every captured channel: strongest amplitude over 0.5 s blocks.
    if (gStore) {
    uint64_t nF = gCapFrames < gCapCap ? gCapFrames : gCapCap;
    uint64_t blk = gRate / 2;
    if (gWavPath) {
        FILE *wf = fopen(gWavPath, "wb");
        if (wf) {
            uint32_t ch = gCPcm, rate = (uint32_t)gRate, dataBytes = (uint32_t)(nF * ch * 4), riff = 36 + dataBytes;
            uint16_t fmt = 3, nch = (uint16_t)ch, align = (uint16_t)(ch * 4), bits = 32; uint32_t brate = rate * ch * 4, f16 = 16;
            fwrite("RIFF", 1, 4, wf); fwrite(&riff, 4, 1, wf); fwrite("WAVEfmt ", 1, 8, wf); fwrite(&f16, 4, 1, wf);
            fwrite(&fmt, 2, 1, wf); fwrite(&nch, 2, 1, wf); fwrite(&rate, 4, 1, wf); fwrite(&brate, 4, 1, wf); fwrite(&align, 2, 1, wf); fwrite(&bits, 2, 1, wf);
            fwrite("data", 1, 4, wf); fwrite(&dataBytes, 4, 1, wf);
            for (uint64_t i = 0; i < nF; i++) for (unsigned c = 0; c < ch; c++) fwrite(&gCap[c][i], 4, 1, wf);
            fclose(wf); printf("Capture saved: %s (%u channels, %u Hz, %" PRIu64 " frames)\n", gWavPath, ch, rate, nF);
        }
    }
    printf("Looking for %u sent tone(s) on card channels %u to %u (best 0.5 s block, noise floor about -107 dBFS rms):\n",
           nTones, cidx * 16 + 1, cidx * 16 + gCPcm);
    int foundAny = 0;
    for (unsigned c = 0; c < gCPcm; c++) {
        double lvl[MAX_CH + 1]; unsigned nFound = 0;
        for (unsigned g = 1; g <= MAX_CH; g++) {
            lvl[g] = -200;
            if (!gTone[g]) continue;
            double best = 0;
            for (uint64_t from = gRate / 4; from + blk <= nF; from += blk) {
                double v = toneAmp(gCap[c], from, blk, gFreq[g], gRate);
                if (v > best) best = v;
            }
            lvl[g] = db(best);
            if (lvl[g] > -95) nFound++;
        }
        if (!nFound) continue;
        foundAny = 1;
        printf("  card channel %u: %u of %u tones found\n", cidx * 16 + c + 1, nFound, nTones);
        printf("    found  :");
        for (unsigned g = 1; g <= MAX_CH; g++) if (gTone[g] && lvl[g] > -95) printf(" %u(%.0f)", g, lvl[g]);
        printf("  [playback channel (dBFS)]\n");
        if (nFound < nTones) { printf("    missing:"); for (unsigned g = 1; g <= MAX_CH; g++) if (gTone[g] && lvl[g] <= -95) printf(" %u", g); printf("\n"); }
    }
    if (foundAny) {
        // Level of the first and last tone on the last captured channel, block by block, to show whether
        // the audio holds for the whole run (drift between the card clock and the Mac shows up here).
        unsigned cc = gCPcm - 1;
        for (int which = 0; which < 2; which++) {
            unsigned g = 0;
            if (which == 0) { for (unsigned k = 1; k <= MAX_CH; k++) if (gTone[k]) { g = k; break; } }
            else { for (unsigned k = MAX_CH; k >= 1; k--) if (gTone[k]) { g = k; break; } }
            if (!g) continue;
            printf("  level of tone %u (%.0f Hz) on card channel %u per 0.25 s:", g, gFreq[g], cidx * 16 + cc + 1);
            for (uint64_t from = 0; from + gRate / 4 <= nF; from += gRate / 4) printf(" %.0f", db(toneAmp(gCap[cc], from, gRate / 4, gFreq[g], gRate)));
            printf("\n");
        }
    }
    if (gStore) {
        // Strongest components on the last captured channel, scanned 100 Hz to 12 kHz in 50 Hz steps (0.5 s blocks)
        unsigned cc2 = gCPcm - 2; double amps[240]; for (int k = 0; k < 240; k++) { double f = 100 + 50.0 * k, best = 0; for (uint64_t from = gRate / 4; from + blk <= nF; from += blk) { double v = toneAmp(gCap[cc2], from, blk, f, gRate); if (v > best) best = v; } amps[k] = db(best); }
        printf("  peaks on channel %u (100 Hz to 12 kHz, 50 Hz steps):", cidx * 16 + cc2 + 1);
        for (int n = 0; n < 6; n++) { int bk = -1; for (int k = 0; k < 240; k++) if (amps[k] > -100 && (bk < 0 || amps[k] > amps[bk])) bk = k; if (bk < 0) break; printf("  %.0f Hz %.1f dBFS;", 100 + 50.0 * bk, amps[bk]); for (int k = (bk > 2 ? bk - 2 : 0); k <= bk + 2 && k < 240; k++) amps[k] = -200; }
        printf("\n");
    }
    if (nTones == 1 && gStore) {
        // Single tone: look at half, equal and double frequency, to see whether the card plays at the wrong speed.
        unsigned g1 = 0; for (unsigned g = 1; g <= MAX_CH; g++) if (gTone[g]) g1 = g;
        for (unsigned c = gCPcm - 2; c < gCPcm; c++) {
            printf("  channel %u, tone %u sent at %.0f Hz:", cidx * 16 + c + 1, g1, gFreq[g1]);
            const double mult[5] = {0.25, 0.5, 1.0, 2.0, 4.0};
            for (int k = 0; k < 5; k++) {
                double best = 0;
                for (uint64_t from = gRate / 4; from + blk <= nF; from += blk) { double v = toneAmp(gCap[c], from, blk, gFreq[g1] * mult[k], gRate); if (v > best) best = v; }
                printf("  at %.0f Hz: %.1f dBFS", gFreq[g1] * mult[k], db(best));
            }
            printf("\n");
        }
    }
    if (!foundAny) printf("  none found. Either the console does not route the FireWire return to these channels, or the card did not play the stream.\n");
    }   // gStore
    // Streaming report: for each sent tone on card channels 31 and 32, level per 0.5 s block over the whole run.
    if (gBlkCnt >= 6 && gMonN) {
        printf("Level monitor: %u blocks of 0.5 s on the last two captured channels.\n", gBlkCnt);
        unsigned pairs = 0, clean = 0, nDrop = 0; double worst = 0; int shown = 0;
        for (unsigned ch = 0; ch < 2; ch++)
            for (unsigned t = 0; t < gMonN; t++) {
                float *L = gBlkLvl[ch][t];
                int f = -1, l = -1;
                for (unsigned b = 0; b < gBlkCnt; b++) if (L[b] > -60) { if (f < 0) f = (int)b; l = (int)b; }
                pairs++;
                if (f < 0 || l - f < 4) { printf("  channel %u tone %u: not present\n", gCPcm - 2 + ch + 1 + cidx * 16, gMonTone[t]); continue; }
                double sorted[BLK_MAX]; unsigned n = 0;
                for (int b = f + 1; b < l; b++) sorted[n++] = L[b];
                for (unsigned i = 1; i < n; i++) { double v = sorted[i]; int j = (int)i - 1; while (j >= 0 && sorted[j] > v) { sorted[j + 1] = sorted[j]; j--; } sorted[j + 1] = v; }
                double med = sorted[n / 2], mn = sorted[0];
                unsigned drops = 0;
                for (int b = f + 1; b < l; b++) if (L[b] < med - 3.0) { drops++; if (shown < 12) { printf("  dropout: channel %u tone %u at %.1f s: %.1f dBFS (median %.1f)\n", gCPcm - 2 + ch + 1 + cidx * 16, gMonTone[t], (b + 0.5) * 0.5, L[b], med); shown++; } }
                if (!drops) clean++;
                nDrop += drops; if (mn < worst) worst = mn;
                if (ch == 0 && (t == 0 || t == gMonN - 1))
                    printf("  channel %u tone %u: present %.1f s, median %.1f dBFS, minimum %.1f dBFS, dropouts %u\n", gCPcm - 2 + ch + 1 + cidx * 16, gMonTone[t], (l - f + 1) * 0.5, med, mn, drops);
            }
        printf("  %u of %u tone/channel pairs without any dropout; %u dropout blocks in total (a dropout = a block more than 3 dB under the median of its tone)\n", clean, pairs, nDrop);
    }
    if (gWinN >= 2) {
        printf("Card SYT advance per 5 s window (ticks per data packet; ppm against the first window):");
        double r0 = 0;
        for (unsigned w = 1; w < gWinN; w++) {
            double r = (gWinU[w] - gWinU[w - 1]) / (double)(gWinCnt[w] - gWinCnt[w - 1]);
            if (w == 1) r0 = r;
            printf(" %.4f(%+.0f)", r, (r / r0 - 1) * 1e6);
        }
        printf("\n");
    }
    if (gBusReset) printf("VERDICT: BUS RESET (%d) during the run; card %s\n", gBusResets, gCardGone ? "did not answer afterwards, nothing restored" : "answered again and was restored");
    else printf("VERDICT: %s\n", gCDbcJumps == 0 && gCBadCip == 0 ? "capture counters clean" : "capture counters show errors");
    printf("Card after stop: ENABLE %u, STATUS 0x%08x (locked=%s), register retries %d\n", en, st2, (st2 & 1) ? "yes" : "no", gRetries);
    (*gDev)->Close(gDev);
    return gBusReset ? 4 : 0;
}
