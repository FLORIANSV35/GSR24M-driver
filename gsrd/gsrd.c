// SPDX-License-Identifier: Apache-2.0
//
// gsrd: owns the Allen & Heath GS-R24 card and moves audio between it and the shared rings read by the HAL plug-in.
// Engine derived from gsrcap/gsrloop.c (every sequence here was measured on the real card; see re/NOTES.md).
//
//   input ring  : both TX streams of the card (32 channels), float32, written as the packets arrive
//   output ring : written by the plug-in (host to card), read when the playback packets are built (40 ms ahead)
//   clock anchor: sample time (card frames since the stream started) against mach_absolute_time, from a delay-locked
//                 loop on the packet callbacks, republished at every capture callback
//
// Only volatile run-time registers are written: OWNER, CLOCK_SELECT, ENABLE, stream ISOCHRONOUS / SPEED / SEQ_START;
// all put back when streaming stops. Never firmware. Needs the card to have no other owner.
//
// Build: see build.sh.  Run: gsrd --file PATH [--rate N]   (ring in a file, for tests, no XPC)
//                            gsrd --xpc [--rate N]         (as the LaunchDaemon: ring over the Mach service)

#include "../hal/gsr_ring.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/firewire/IOFireWireFamilyCommon.h>
#include <IOKit/firewire/IOFireWireLib.h>
#include <IOKit/firewire/IOFireWireLibIsoch.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <inttypes.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <xpc/xpc.h>

#define BASE_HI 0xFFFF
#define BASE_LO 0xE0000000u
#define RING_SLOTS 640            // capture ring, packets (80 ms); multiple of 8
#define MAX_PKT 2048
#define HDR_BYTES 4
#define BATCH 8                   // slots per callback (1 ms)
#define RING_FRAMES 32768u
#define NSTREAM 2                 // card streams per direction (2 x 16 channels)
#define CH_PER_STREAM 16

// ---------- globals ----------

static IOFireWireLibDeviceRef gDev;
static io_object_t gSvc;
static UInt32 gGen, gGenAtStart;
static volatile sig_atomic_t gQuit, gBusReset;
static int gRetries;
static mach_timebase_info_data_t gTb;
static double gHostHz;

static GsrRingHeader *H;
static size_t gRingBytes;
static const char *gFilePath;
static int gUseXpc;
static unsigned gInitialRate;
static double gRunSeconds;                  // test: stop after this many seconds (0 = run forever)
static int gQuiet;

static UInt32 gGlobalOff, gTxOff, gRxOff, gEnableReg, gClockSelReg;
static UInt32 gNTx, gNRx, gTxBlkQ, gRxBlkQ;
static UInt32 gOrigClock;
static uint64_t gOwnerVal; static int gOwned;
static IOFireWireLibPseudoAddressSpaceRef gPas;
static unsigned gSid;
static unsigned gRate, gBlocks;
static const unsigned kRateTbl[] = {32000, 44100, 48000, 88200, 96000, 176400, 192000};

#include <stdarg.h>
static void logf2(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf2(const char *fmt, ...) {
    if (gQuiet) return;
    va_list ap; va_start(ap, fmt);
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    printf("[%9.3f] ", fmod(t, 100000.0));
    vprintf(fmt, ap); printf("\n"); fflush(stdout);
    va_end(ap);
}

// ---------- register access (fail fast once a bus reset was seen) ----------

static IOReturn rq(UInt32 off, UInt32 *v) {
    IOReturn r = kIOReturnError;
    for (int t = 0, n = gBusReset ? 1 : 10; t < n; t++) {
        UInt16 node; uint8_t b[4]; UInt32 sz = 4;
        (*gDev)->GetGenerationAndNodeID(gDev, &gGen, &node);
        FWAddress a = {0, BASE_HI, BASE_LO + off};
        r = (*gDev)->Read(gDev, gSvc, &a, b, &sz, true, gGen);
        if (r == kIOReturnSuccess) { *v = (UInt32)b[0] << 24 | (UInt32)b[1] << 16 | (UInt32)b[2] << 8 | b[3]; return r; }
        gRetries++; usleep(gBusReset ? 10000 : 50000);
    }
    return r;
}
static IOReturn wq(UInt32 off, UInt32 v) {
    IOReturn r = kIOReturnError;
    for (int t = 0, n = gBusReset ? 1 : 10; t < n; t++) {
        UInt16 node; UInt32 sz = 4;
        uint8_t b[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
        (*gDev)->GetGenerationAndNodeID(gDev, &gGen, &node);
        FWAddress a = {0, BASE_HI, BASE_LO + off};
        r = (*gDev)->Write(gDev, gSvc, &a, b, &sz, true, gGen);
        if (r == kIOReturnSuccess) return r;
        gRetries++; usleep(gBusReset ? 10000 : 50000);
    }
    return r;
}
static int lock64(UInt32 off, uint64_t cmp, uint64_t nw) {
    UInt16 node; (*gDev)->GetGenerationAndNodeID(gDev, &gGen, &node);
    FWAddress a = {0, BASE_HI, BASE_LO + off};
    IOFireWireLibCommandRef cmd = (*gDev)->CreateCompareSwapCommand(
        gDev, gSvc, &a, 0, 0, NULL, true, gGen, NULL, CFUUIDGetUUIDBytes(kIOFireWireCompareSwapCommandInterfaceID_v3));
    if (!cmd) return -1;
    IOFireWireLibCompareSwapCommandV3Ref c3 = (IOFireWireLibCompareSwapCommandV3Ref)cmd;
    (*c3)->SetValues64(c3, __builtin_bswap64(cmp), __builtin_bswap64(nw));   // the library passes 64-bit values in bus order
    IOReturn r = (*cmd)->Submit(cmd);
    int ok = (r == kIOReturnSuccess) && (*c3)->DidLock(c3);
    (*cmd)->Release(cmd);
    return ok ? 0 : (r ? (int)r : 1);
}
static uint64_t propNum(io_object_t svc, CFStringRef key) {
    uint64_t v = 0;
    CFTypeRef t = IORegistryEntrySearchCFProperty(svc, kIOServicePlane, key, kCFAllocatorDefault, kIORegistryIterateRecursively);
    if (t) { if (CFGetTypeID(t) == CFNumberGetTypeID()) CFNumberGetValue(t, kCFNumberSInt64Type, &v); CFRelease(t); }
    return v;
}
static void put32(uint8_t *p, uint32_t q) { p[0] = q >> 24; p[1] = q >> 16; p[2] = q >> 8; p[3] = q; }

// ---------- streams ----------

typedef struct {
    unsigned idx, pcm, midi, dbs;
    UInt32 isoReg, speedReg;
    uint8_t *buf;
    NuDCLRef dcl[RING_SLOTS];
    IOFireWireLibNuDCLPoolRef pool;
    IOFireWireLibLocalIsochPortRef local;
    IOFireWireLibRemoteIsochPortRef remote;
    IOFireWireLibIsochChannelRef chan;
    int allocated;
    // packet accounting
    uint64_t packets, data, empty, badCip, badDbs, dbcJumps, startup, shortPkt;
    uint32_t lastDbc; int haveDbc;
    CFAbsoluteTime t0, t1;
    // placement in the ring
    uint64_t fw;                 // frames received since this stream started
    int active;                  // writing into the ring
    int64_t base;                // sample time of frame index fw = fw + base
    int haveU0; double U0; uint64_t k0;   // first valid SYT (ticks) and the frame index it belongs to
} CapS;

typedef struct {
    unsigned idx, pcm, midi, dbs;
    UInt32 isoReg, seqReg;
    uint8_t *buf;
    uint32_t *slotLen, *stamp;
    NuDCLRef *dcl;
    IOFireWireLibNuDCLPoolRef pool;
    IOFireWireLibLocalIsochPortRef local;
    IOFireWireLibRemoteIsochPortRef remote;
    IOFireWireLibIsochChannelRef chan;
    int allocated;
    uint64_t seqNo, dataIdx, frame, synced, sent;
    uint32_t dbc;
} PlayS;

static CapS gC[NSTREAM];
static PlayS gP[NSTREAM];
static unsigned gL;                       // playback ring length in slots
static uint8_t *gKind;                    // per slot: 1 = data packet, 0 = empty
static unsigned gLeadMs = 80;             // playback is generated this far ahead of the DMA (ms); a scheduling stall longer than this is a glitch
static unsigned gLead = 640;              // the same in slots (8 per ms)
static double gLeadTicks = 12800.0;
static double gR = 4096.0, gT0tick;       // card SYT advance per data packet; first playback presentation time
static int gSyncStarted; static uint64_t gN0;
static double gPresBus; static uint64_t gP0; static int gHavePres;   // absolute bus time (ticks) of the first presented block

static int gPreEnabled, gMeasuring;
// card SYT timeline measured in the first pass
static uint64_t gRxCnt, gRxFirstCnt; static double gRxFirstU, gRxU; static uint32_t gRxPrevTicks; static int gRxHave;
static uint32_t gRxPrevSytTicks;
// output mapping
static int gOutCal; static int64_t gD;
static volatile int gOutActive;            // the plug-in has written output recently (not derived from ioClients, which can leak when a client dies)
static uint64_t gOutWSeen; static CFAbsoluteTime gOutWChanged;    // sample time of playback block p = p + gD
static CFAbsoluteTime gSessionStart;
static CFAbsoluteTime gLastCb, gMaxGap;

// delay-locked loop: sample time against host time
static int dllInit; static double dllT, dllTpf; static uint64_t dllN;
#define DLL_A 0.01
#define DLL_B (DLL_A * DLL_A / 4.0)

static void publishInput(uint64_t inW, uint64_t tNow) {
    if (!dllInit) { dllN = inW; dllT = (double)tNow; dllTpf = gHostHz / gRate; dllInit = 1; }
    else {
        double dn = (double)(inW - dllN);
        if (dn <= 0) return;
        double pred = dllT + dllTpf * dn, err = (double)tNow - pred;
        dllT = pred + DLL_A * err; dllTpf += DLL_B * err / dn; dllN = inW;
        double nom = gHostHz / gRate;
        if (dllTpf > nom * 1.001) dllTpf = nom * 1.001;
        if (dllTpf < nom * 0.999) dllTpf = nom * 0.999;
    }
    atomic_store_explicit(&H->inWritten, inW, memory_order_release);
    gsr_anchor_write(H, dllN, (uint64_t)dllT, dllTpf);
    if (atomic_load_explicit(&H->state, memory_order_relaxed) != GSR_STATE_STREAMING) atomic_store(&H->state, GSR_STATE_STREAMING);
}

// ---------- capture ----------

static void recvSlot(CapS *c, unsigned idx) {
    const uint8_t *p = c->buf + (size_t)idx * MAX_PKT;
    c->packets++;
    if (c->packets == 1) c->t0 = CFAbsoluteTimeGetCurrent();
    c->t1 = CFAbsoluteTimeGetCurrent();
    int startup = (c->t1 - c->t0) < 0.25;
    uint32_t len = (uint32_t)p[2] | (uint32_t)p[3] << 8;
    const uint8_t *q = p + HDR_BYTES;
    if (len < 8 || len > MAX_PKT - HDR_BYTES) { if (startup) c->startup++; else c->shortPkt++; return; }
    if ((q[0] & 0xC0) != 0x00 || (q[4] & 0xC0) != 0x80 || (q[4] & 0x3F) != 0x10) { c->badCip++; return; }
    uint32_t dbs = q[1], dbc = q[3];
    if (len == 8) { c->empty++; return; }
    if (dbs != c->dbs) { c->badDbs++; return; }
    uint32_t blocks = (len - 8) / (dbs * 4);
    if (c->haveDbc && (c->lastDbc & 0xFF) != dbc) { if (startup) c->startup++; else c->dbcJumps++; }
    c->lastDbc = dbc + blocks; c->haveDbc = 1;
    c->data++;
    uint32_t sy = (uint32_t)q[6] << 8 | q[7];
    if (sy != 0xFFFF) {
        uint32_t tk = ((sy >> 12) & 0xF) * 3072 + (sy & 0xFFF);
        if (gMeasuring && c->idx == 0) {
            if (!gRxHave) { gRxHave = 1; gRxU = tk; } else gRxU += (tk + 49152 - gRxPrevTicks) % 49152;
            gRxPrevTicks = tk;
            if (gRxCnt == 200) { gRxFirstCnt = gRxCnt; gRxFirstU = gRxU; }
            gRxCnt++;
        }
        gRxPrevSytTicks = tk;
        if (!c->haveU0) { c->haveU0 = 1; c->U0 = tk; c->k0 = c->fw; }
    }
    if (gMeasuring) { c->fw += blocks; return; }
    // stream alignment: when both streams know a presentation time, sample time 0 is the earlier of the two frame 0s
    if (!c->active && gC[0].haveU0 && gC[1].haveU0) {
        double tpf = 24576000.0 / gRate;
        double T0[2];
        for (int s = 0; s < NSTREAM; s++) T0[s] = gC[s].U0 - (double)gC[s].k0 * tpf;
        double d = fmod(T0[1] - T0[0] + 49152.0 * 3 + 24576.0, 49152.0) - 24576.0;   // frame 0 of stream 1 minus frame 0 of stream 0, ticks
        long ofs = lround(d / tpf);
        if (!getenv("GSR_ALIGN_SYT")) ofs = 0;       // measured: both TX streams start on the same card frame; the presentation time difference is not a usable offset (see re/NOTES.md)
        long b0 = ofs < 0 ? -ofs : 0, b1 = ofs > 0 ? ofs : 0;
        if (!gC[0].active && !gC[1].active) logf2("capture streams aligned: stream 1 starts %ld frames after stream 0", ofs);
        gC[0].base = b0; gC[1].base = b1;
        gC[0].active = gC[1].active = 1;
    }
    if (c->active) {
        float *ring = gsr_in_ring(H);
        const uint8_t *a = q + 8;
        uint32_t mask = H->ringFrames - 1;
        for (uint32_t b = 0; b < blocks; b++, a += dbs * 4) {
            int64_t S = (int64_t)(c->fw + b) + c->base;
            float *dst = ring + (size_t)((uint64_t)S & mask) * GSR_MAX_CH + c->idx * CH_PER_STREAM;
            for (unsigned ch = 0; ch < c->pcm && ch < CH_PER_STREAM; ch++) {
                int32_t v = (int32_t)((uint32_t)a[ch * 4 + 1] << 24 | (uint32_t)a[ch * 4 + 2] << 16 | (uint32_t)a[ch * 4 + 3] << 8);
                dst[ch] = (float)((double)v / 2147483648.0);
            }
        }
    }
    c->fw += blocks;
}

static void onRecv(void *refcon, NuDCLRef dcl) {
    (void)dcl;
    unsigned s = (unsigned)((uintptr_t)refcon >> 16), last = (unsigned)((uintptr_t)refcon & 0xFFFF);
    CapS *c = &gC[s];
    if (s >= NSTREAM || !c->buf) return;          // a callback of a session that was already torn down (queued on the run loop)
    for (unsigned k = 0; k < BATCH; k++) recvSlot(c, (last + RING_SLOTS - (BATCH - 1) + k) % RING_SLOTS);
    if (gMeasuring || s != 0) return;
    if (gC[0].active && gC[1].active) {
        int64_t e0 = (int64_t)gC[0].fw + gC[0].base, e1 = (int64_t)gC[1].fw + gC[1].base;
        int64_t e = e0 < e1 ? e0 : e1;
        if (e > 0) publishInput((uint64_t)e, mach_absolute_time());
    }
}

// ---------- playback ----------

static uint8_t *gOutRing; static uint32_t gOutMask;

static void buildPacket(PlayS *ps, uint64_t seq, double tSend, double sendBus) {
    unsigned slot = (unsigned)(seq % gL);
    uint8_t *p = ps->buf + (size_t)slot * MAX_PKT;
    int empty = !gKind[slot];
    p[0] = gSid & 0x3F; p[1] = (uint8_t)ps->dbs; p[2] = 0; p[3] = (uint8_t)ps->dbc;
    p[4] = 0x90; p[5] = (uint8_t)(gRate == 44100 ? 1 : gRate == 88200 ? 3 : gRate == 96000 ? 4 : 2);
    if (empty) { p[6] = 0xFF; p[7] = 0xFF; return; }
    uint32_t syt = 0xFFFF;
    if (tSend >= 0) {
        if (!gSyncStarted) {
            // first presentation time: first point of the card's grid at least gLeadTicks after the send time
            double target = fmod(tSend + gLeadTicks, 49152.0), tr = (double)gRxPrevSytTicks;
            unsigned m = 0;
            for (; m < 40; m++) if (fmod(tr + m * gR - target + 49152.0 * 4, 49152.0) < gR) break;
            gT0tick = fmod(tr + m * gR, 49152.0);
            gN0 = ps->dataIdx; gSyncStarted = 1;
            if (ps->idx == 0 && sendBus >= 0) {
                gPresBus = sendBus + fmod(gT0tick - tSend + 49152.0 * 4, 49152.0);
                gP0 = ps->frame; gHavePres = 1;
            }
        }
        double tout = gT0tick + (double)(ps->dataIdx - gN0) * gR;
        uint32_t tk = (uint32_t)fmod(tout, 49152.0);
        syt = ((tk / 3072) & 0xF) << 12 | (tk % 3072);
        ps->synced++;
    }
    p[6] = syt >> 8; p[7] = syt;
    uint8_t *q = p + 8;
    int clients = gOutActive && gOutCal;
    uint64_t outW = clients ? atomic_load_explicit(&H->outWritten, memory_order_acquire) : 0;
    const float *ring = (const float *)gOutRing;
    for (unsigned b = 0; b < gBlocks; b++, ps->frame++) {
        int have = 0; const float *src = NULL;
        if (clients) {
            int64_t S = (int64_t)ps->frame + gD;
            if (S >= 0 && (uint64_t)S < outW && (uint64_t)S + H->ringFrames > outW) { src = ring + (size_t)((uint64_t)S & gOutMask) * GSR_MAX_CH + ps->idx * CH_PER_STREAM; have = 1; }
            else if (S >= 0 && ps->idx == 0) atomic_fetch_add_explicit(&H->outLate, 1, memory_order_relaxed);
        }
        for (unsigned c = 0; c < ps->pcm; c++, q += 4) {
            int32_t x = 0;
            if (have && c < CH_PER_STREAM) {
                float f = src[c];
                if (f > 1.0f) f = 1.0f; else if (f < -1.0f) f = -1.0f;
                x = (int32_t)lrintf(f * 8388608.0f);
                if (x > 8388607) x = 8388607;
            }
            put32(q, (uint32_t)x);          // DICE wire format: 24 bit sample sign-extended in the 32 bit slot, no label
        }
        if (ps->midi) { put32(q, 0x80000000u); q += 4; }
    }
    if (ps->idx == 0) atomic_store_explicit(&H->outRead, ps->frame, memory_order_relaxed);
    ps->dbc = (ps->dbc + gBlocks) & 0xFF;
    ps->dataIdx++;
}

static void onSent(void *refcon, NuDCLRef dcl) {
    (void)dcl;
    unsigned si = (unsigned)((uintptr_t)refcon >> 16), slot = (unsigned)((uintptr_t)refcon & 0xFFFF);
    PlayS *ps = &gP[si];
    if (si >= NSTREAM || !ps->stamp || !ps->buf || slot >= gL) return;     // stale callback of a torn down session: this crashed the daemon at every session end
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gLastCb > 0 && now - gLastCb > gMaxGap) gMaxGap = now - gLastCb;
    gLastCb = now;
    ps->sent += BATCH;
    uint32_t st = ps->stamp[slot];
    uint64_t base = ps->seqNo;
    for (unsigned k = 0; k < BATCH; k++) {
        double tSend = -1, sendBus = -1;
        if (st) {
            uint32_t sec = (st >> 25) & 0x7F, cyc = (st >> 12) & 0x1FFF, off = st & 0xFFF;
            long c = (long)cyc - (long)(BATCH - 1 - k) + (long)gLead;
            sendBus = (double)sec * 24576000.0 + (double)cyc * 3072.0 + off + (double)((long)gLead - (long)(BATCH - 1 - k)) * 3072.0;
            c = ((c % 16) + 16) % 16;
            tSend = (double)(c * 3072 + off);
        }
        buildPacket(ps, base + k + gLead, tSend, sendBus);
    }
    ps->seqNo += BATCH;
}

// ---------- remote ports ----------

static IOFireWireLibRemoteIsochPortRef remoteOf(int play, unsigned i) { return play ? gP[i].remote : gC[i].remote; }
static IOReturn rpGetSupported(IOFireWireLibIsochPortRef self, IOFWSpeed *sp, UInt64 *ch) { (void)self; *sp = kFWSpeed400MBit; *ch = 0xFFFFFFFFFFFFFFFFULL; return kIOReturnSuccess; }
static IOReturn rpAllocate(IOFireWireLibIsochPortRef self, IOFWSpeed speed, UInt32 chan) {
    for (unsigned i = 0; i < NSTREAM; i++) {
        if ((void *)remoteOf(1, i) == (void *)self) { IOReturn r = wq(gP[i].isoReg, chan); return r ? r : wq(gP[i].seqReg, 0); }
        if ((void *)remoteOf(0, i) == (void *)self) { IOReturn r = wq(gC[i].isoReg, chan); return r ? r : wq(gC[i].speedReg, (UInt32)speed); }
    }
    return kIOReturnError;
}
static IOReturn rpRelease(IOFireWireLibIsochPortRef self) {
    for (unsigned i = 0; i < NSTREAM; i++) {
        if ((void *)remoteOf(1, i) == (void *)self) wq(gP[i].isoReg, 0xFFFFFFFFu);
        if ((void *)remoteOf(0, i) == (void *)self) wq(gC[i].isoReg, 0xFFFFFFFFu);
    }
    return kIOReturnSuccess;
}
static IOReturn rpStart(IOFireWireLibIsochPortRef self) { (void)self; if (gPreEnabled) return kIOReturnSuccess; usleep(2000); return wq(gEnableReg, 1); }
static IOReturn rpStop(IOFireWireLibIsochPortRef self) { (void)self; return wq(gEnableReg, 0); }

// ---------- card open / prepare / shutdown ----------

static void onBusReset(IOFireWireLibDeviceRef self, FWClientCommandID id) {
    gBusReset = 1;
    (*self)->ClientCommandIsComplete(self, id, kIOReturnSuccess);
    CFRunLoopStop(CFRunLoopGetMain());
}
static void onBusResetDone(IOFireWireLibDeviceRef self, FWClientCommandID id) { (*self)->ClientCommandIsComplete(self, id, kIOReturnSuccess); }

static void releasePort(void *p) { if (p) { IUnknownVTbl **u = (IUnknownVTbl **)p; (*u)->Release(u); } }

static int openCard(void) {
    io_iterator_t it;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFireWireDevice"), &it);
    io_object_t svc, chosen = 0;
    while ((svc = IOIteratorNext(it))) {
        uint64_t guid = propNum(svc, CFSTR("GUID"));
        if (!chosen && ((guid >> 40) == 0x0004C4 || propNum(svc, CFSTR("Unit_Spec_ID")) == 1220) && ((guid >> 22) & 0x3FF) == 1) {
            chosen = svc; continue;
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    if (!chosen) return 0;
    IOCFPlugInInterface **plug = NULL; SInt32 score;
    if (IOCreatePlugInInterfaceForService(chosen, kIOFireWireLibTypeID, kIOCFPlugInInterfaceID, &plug, &score) ||
        (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOFireWireDeviceInterfaceID_v9), (LPVOID *)&gDev) != S_OK) { IOObjectRelease(chosen); return 0; }
    (*plug)->Release(plug);
    gSvc = chosen;
    IOReturn r = (*gDev)->Open(gDev);
    for (int i = 0; r == kIOReturnExclusiveAccess && i < 200; i++) { usleep(1000); r = (*gDev)->Open(gDev); }
    if (r) { (*gDev)->Release(gDev); gDev = NULL; IOObjectRelease(chosen); gSvc = 0; return 0; }
    (*gDev)->AddCallbackDispatcherToRunLoop(gDev, CFRunLoopGetMain());
    (*gDev)->AddIsochCallbackDispatcherToRunLoop(gDev, CFRunLoopGetMain());
    (*gDev)->SetBusResetHandler(gDev, onBusReset);
    (*gDev)->SetBusResetDoneHandler(gDev, onBusResetDone);
    gBusReset = 0;
    UInt16 ln = 0; (*gDev)->GetLocalNodeID(gDev, &ln); gSid = ln & 0x3F;
    return 1;
}

static void closeCard(void) {
    if (gDev) { (*gDev)->Close(gDev); (*gDev)->Release(gDev); gDev = NULL; }
    if (gSvc) { IOObjectRelease(gSvc); gSvc = 0; }
    releasePort(gPas); gPas = NULL; gOwned = 0;
}

static int readLayout(void) {
    UInt32 t[6];
    for (int i = 0; i < 6; i++) if (rq(i * 4, &t[i])) return 0;
    gGlobalOff = t[0] * 4; gTxOff = t[2] * 4; gRxOff = t[4] * 4;
    if (rq(gTxOff, &gNTx) || rq(gTxOff + 4, &gTxBlkQ) || rq(gRxOff, &gNRx) || rq(gRxOff + 4, &gRxBlkQ)) return 0;
    gEnableReg = gGlobalOff + 0x50; gClockSelReg = gGlobalOff + 0x4C;
    return gNTx >= NSTREAM && gNRx >= NSTREAM;
}

// Put the registers this program writes back to idle (also used on a card left dirty by a bus reset).
static void cleanCard(void) {
    UInt32 en = 0; rq(gEnableReg, &en);
    if (en) wq(gEnableReg, 0);
    for (UInt32 i = 0; i < gNTx; i++) { UInt32 a = gTxOff + 8 + i * gTxBlkQ * 4, v = 0; if (!rq(a, &v) && v != 0xFFFFFFFFu) wq(a, 0xFFFFFFFFu); }
    for (UInt32 i = 0; i < gNRx; i++) { UInt32 a = gRxOff + 8 + i * gRxBlkQ * 4, v = 0; if (!rq(a, &v) && v != 0xFFFFFFFFu) wq(a, 0xFFFFFFFFu); }
}

static int takeOwner(void) {
    UInt32 o0 = 0, o1 = 0; rq(gGlobalOff, &o0); rq(gGlobalOff + 4, &o1);
    if (o0 != 0xFFFF0000u || o1 != 0) { logf2("OWNER is taken by another host (0x%08x%08x): not touching the card", o0, o1); return 0; }
    static uint8_t backing[64];
    gPas = (*gDev)->CreatePseudoAddressSpace(gDev, sizeof backing, NULL, 0, backing, kFWAddressSpaceAutoWriteReply | kFWAddressSpaceAutoReadReply, CFUUIDGetUUIDBytes(kIOFireWirePseudoAddressSpaceInterfaceID));
    if (!gPas) return 0;
    FWAddress na; (*gPas)->GetFWAddress(gPas, &na);
    UInt16 ln = 0; (*gDev)->GetLocalNodeID(gDev, &ln);
    uint64_t ov = (uint64_t)ln << 48 | (uint64_t)na.addressHi << 32 | na.addressLo;
    int lr = lock64(gGlobalOff, 0xFFFF000000000000ULL, ov);
    if (lr) { logf2("could not take OWNER (%d)", lr); return 0; }
    gOwnerVal = ov; gOwned = 1;
    return 1;
}

static void releaseOwner(void) {
    if (gOwned && !gBusReset) { int lr = lock64(gGlobalOff, gOwnerVal, 0xFFFF000000000000ULL); logf2("OWNER released (%s)", lr == 0 ? "ok" : "failed"); }
    gOwned = 0;
}

static unsigned gSourceIdx = 12;          // wanted clock source: 12 = internal, 7 = word clock (the two the GS-R24 offers)
static int setClock(unsigned rate, unsigned src) {
    unsigned code = 99;
    for (unsigned i = 0; i < 7; i++) if (kRateTbl[i] == rate) code = i;
    UInt32 caps = 0, cs = 0; rq(gGlobalOff + 0x64, &caps);
    if (code == 99 || !(caps & (1u << code)) || (rate != 44100 && rate != 48000 && rate != 88200 && rate != 96000)) return 0;
    if (src != 12 && src != 7) return 0;
    if (rq(gClockSelReg, &cs)) return 0;
    UInt32 want = (cs & ~0xFFFFu) | (code << 8) | src, st = 0;
    if (want != cs && wq(gClockSelReg, want)) return 0;
    // with word clock the card only locks if the signal is at this rate: no lock means the caller goes back to the internal clock
    for (int t = 0; t < 3000; t += 20) { if (!rq(gGlobalOff + 0x54, &st) && (st & 1) && ((st >> 8) & 0xFF) == code) return 1; usleep(20000); }
    return 0;
}

// ---------- information for the app, channel names ----------

typedef struct {
    int haveCard; uint64_t guid;
    char vendor[64], model[64]; uint32_t vendorID, modelID, unitSpecID;
    char nick[68], clockSource[16], dice[24];
    unsigned rate; int locked; uint32_t ext;
    unsigned rates[8], nRates; char sources[16][12]; unsigned nSources;
    char clockLabel[13][24];
    struct { int iso; unsigned pcm, midi; char speed[8]; char names[16][GSR_NAME_LEN]; } tx[NSTREAM], rx[NSTREAM];
} Info;
static Info gInfo;
static pthread_mutex_t gInfoLock = PTHREAD_MUTEX_INITIALIZER;
static char gCardIn[GSR_MAX_CH][GSR_NAME_LEN], gCardOut[GSR_MAX_CH][GSR_NAME_LEN];       // names the card announces (before the '/')
static char gCustomIn[GSR_MAX_CH][GSR_NAME_LEN], gCustomOut[GSR_MAX_CH][GSR_NAME_LEN];   // names chosen by the user (empty = card name)
static const char *gNamesFile = "/Library/Application Support/GSR24M/names.json";
static volatile int gRestartWanted;
static unsigned gSessions, gBusResets; static CFAbsoluteTime gStartedAt;
static char gLastError[96];
static const char *kSourceId[13] = {"aes1", "aes2", "aes3", "aes4", "aes_any", "adat", "tdif", "wc", "arx1", "arx2", "arx3", "arx4", "internal"};

static void applyNames(void) {
    for (int k = 0; k < GSR_MAX_CH; k++) {
        snprintf(H->nameIn[k], GSR_NAME_LEN, "%s", gCustomIn[k][0] ? gCustomIn[k] : (gCardIn[k][0] ? gCardIn[k] : ""));
        snprintf(H->nameOut[k], GSR_NAME_LEN, "%s", gCustomOut[k][0] ? gCustomOut[k] : (gCardOut[k][0] ? gCardOut[k] : ""));
        if (!H->nameIn[k][0]) snprintf(H->nameIn[k], GSR_NAME_LEN, "CH%d", k + 1);
        if (!H->nameOut[k][0]) snprintf(H->nameOut[k], GSR_NAME_LEN, "CH%d", k + 1);
    }
    atomic_fetch_add(&H->namesRevision, 1);
}

static void jesc(char *dst, size_t cap, const char *src) {          // JSON string content: escapes " and \ and drops control characters
    size_t n = 0;
    for (; *src && n + 3 < cap; src++) {
        unsigned char c = (unsigned char)*src;
        if (c == '"' || c == '\\') { dst[n++] = '\\'; dst[n++] = (char)c; }
        else if (c >= 32) dst[n++] = (char)c;
    }
    dst[n] = 0;
}

static void saveNames(void) {
    char dir[256]; snprintf(dir, sizeof dir, "%s", gNamesFile);
    char *sl = strrchr(dir, '/'); if (sl) { *sl = 0; mkdir(dir, 0755); }
    char tmp[300]; snprintf(tmp, sizeof tmp, "%s.tmp", gNamesFile);
    FILE *f = fopen(tmp, "w"); if (!f) { logf2("could not write %s", tmp); return; }
    for (int d = 0; d < 2; d++) {
        fprintf(f, "%s\"%s\":[", d ? ",\n" : "{\n", d ? "out" : "in");
        for (int k = 0; k < GSR_MAX_CH; k++) { char e[2 * GSR_NAME_LEN + 4]; jesc(e, sizeof e, d ? gCustomOut[k] : gCustomIn[k]); fprintf(f, "%s\"%s\"", k ? "," : "", e); }
        fprintf(f, "]");
    }
    fprintf(f, "\n}\n"); fclose(f);
    chmod(tmp, 0644); rename(tmp, gNamesFile);
}

static void loadNames(void) {                                       // tiny reader for the file written above: two arrays of strings
    FILE *f = fopen(gNamesFile, "r"); if (!f) return;
    char buf[8192]; size_t n = fread(buf, 1, sizeof buf - 1, f); fclose(f); buf[n] = 0;
    for (int d = 0; d < 2; d++) {
        char *p = strstr(buf, d ? "\"out\"" : "\"in\""); if (!p) continue;
        p = strchr(p, '['); if (!p) continue; p++;
        for (int k = 0; k < GSR_MAX_CH; k++) {
            p = strchr(p, '"'); if (!p) break; p++;
            char tmp[GSR_NAME_LEN] = {0}; size_t m = 0;
            while (*p && *p != '"') { if (*p == '\\' && p[1]) p++; if (m + 1 < sizeof tmp) tmp[m++] = *p; p++; }
            if (*p == '"') p++;
            snprintf(d ? gCustomOut[k] : gCustomIn[k], GSR_NAME_LEN, "%s", tmp);
        }
    }
}

static void readText(UInt32 off, size_t bytes, char *out) {          // text registers come byte-swapped inside each quadlet
    for (size_t i = 0; i < bytes; i += 4) {
        UInt32 w = 0; if (rq(off + (UInt32)i, &w)) w = 0;
        out[i] = (char)(w >> 24); out[i + 1] = (char)(w >> 16); out[i + 2] = (char)(w >> 8); out[i + 3] = (char)w;
    }
    for (size_t i = 0; i + 3 < bytes; i += 4) { char t0 = out[i], t1 = out[i + 1]; out[i] = out[i + 3]; out[i + 1] = out[i + 2]; out[i + 2] = t1; out[i + 3] = t0; }
    out[bytes - 1] = 0;
}

// Reads what the app displays. Main thread only (register access); the XPC thread only reads the copy.
static void collectStatic(void) {
    Info n; memset(&n, 0, sizeof n);
    n.haveCard = 1;
    n.guid = propNum(gSvc, CFSTR("GUID"));
    CFTypeRef t = IORegistryEntrySearchCFProperty(gSvc, kIOServicePlane, CFSTR("FireWire Vendor Name"), kCFAllocatorDefault, kIORegistryIterateRecursively);
    if (t) { if (CFGetTypeID(t) == CFStringGetTypeID()) CFStringGetCString(t, n.vendor, sizeof n.vendor, kCFStringEncodingUTF8); CFRelease(t); }
    t = IORegistryEntrySearchCFProperty(gSvc, kIOServicePlane, CFSTR("FireWire Product Name"), kCFAllocatorDefault, kIORegistryIterateRecursively);
    if (t) { if (CFGetTypeID(t) == CFStringGetTypeID()) CFStringGetCString(t, n.model, sizeof n.model, kCFStringEncodingUTF8); CFRelease(t); }
    n.vendorID = (uint32_t)propNum(gSvc, CFSTR("Vendor_ID")); n.unitSpecID = (uint32_t)propNum(gSvc, CFSTR("Unit_Spec_ID"));
    n.modelID = (uint32_t)propNum(gSvc, CFSTR("Model_ID"));
    if (!n.modelID) n.modelID = (uint32_t)((n.guid >> 22) & 0x3FF);
    char txt[260];
    readText(gGlobalOff + 0xC, 64, txt); snprintf(n.nick, sizeof n.nick, "%s", txt);
    UInt32 cs = 0, st = 0, ver = 0, caps = 0, ext = 0;
    rq(gClockSelReg, &cs); rq(gGlobalOff + 0x54, &st); rq(gGlobalOff + 0x58, &ext); rq(gGlobalOff + 0x60, &ver); rq(gGlobalOff + 0x64, &caps);
    unsigned src = cs & 0xFF; snprintf(n.clockSource, sizeof n.clockSource, "%s", src < 13 ? kSourceId[src] : "?");
    unsigned rc = (cs >> 8) & 0xFF; n.rate = rc < 7 ? kRateTbl[rc] : 0; n.locked = st & 1; n.ext = ext;
    snprintf(n.dice, sizeof n.dice, "%u.%u.%u.%u", ver >> 24, (ver >> 16) & 0xFF, (ver >> 8) & 0xFF, ver & 0xFF);
    for (unsigned i = 0; i < 7; i++) if (caps & (1u << i)) n.rates[n.nRates++] = kRateTbl[i];
    for (unsigned i = 0; i < 13; i++) if ((caps >> 16) & (1u << i)) snprintf(n.sources[n.nSources++], 12, "%s", kSourceId[i]);
    readText(gGlobalOff + 0x68, 256, txt);
    { int idx = 0; char *tok = txt; for (char *e = txt; idx < 13; e++) { if (*e == '\\' || *e == 0) { char sv = *e; *e = 0; snprintf(n.clockLabel[idx++], 24, "%s", tok); if (!sv) break; tok = e + 1; } } }
    for (int dir = 0; dir < 2; dir++) {
        UInt32 off = dir == 0 ? gTxOff : gRxOff, blkQ = dir == 0 ? gTxBlkQ : gRxBlkQ;
        for (unsigned s = 0; s < NSTREAM; s++) {
            UInt32 b = off + 8 + s * blkQ * 4, iso = 0, pcm = 0, midi = 0, sp = 0;
            rq(b, &iso); rq(b + (dir == 0 ? 4 : 8), &pcm); rq(b + (dir == 0 ? 8 : 0xC), &midi);
            if (dir == 0) rq(b + 0xC, &sp);
            readText(b + 0x10, 256, txt);
            typeof(n.tx[0]) *o = dir == 0 ? &n.tx[s] : &n.rx[s];
            o->iso = (int)iso; o->pcm = pcm; o->midi = midi;
            if (dir == 0) snprintf(o->speed, sizeof o->speed, "%s", sp == 0 ? "S100" : sp == 1 ? "S200" : sp == 2 ? "S400" : sp == 3 ? "S800" : "?");
            int ch = 0; char *tok = txt;
            for (char *e = txt; ch < 16; e++) { if (*e == '\\' || *e == 0) { char sv = *e; *e = 0; if (*tok) snprintf(o->names[ch++], GSR_NAME_LEN, "%s", tok); if (!sv) break; tok = e + 1; } }
        }
    }
    pthread_mutex_lock(&gInfoLock); gInfo = n; pthread_mutex_unlock(&gInfoLock);
}

static void refreshLive(void) {
    UInt32 cs = 0, st = 0, ext = 0;
    if (rq(gClockSelReg, &cs) || rq(gGlobalOff + 0x54, &st) || rq(gGlobalOff + 0x58, &ext)) return;
    pthread_mutex_lock(&gInfoLock);
    unsigned rc = (cs >> 8) & 0xFF; if (rc < 7) gInfo.rate = kRateTbl[rc];
    gInfo.locked = st & 1; gInfo.ext = ext;
    unsigned src = cs & 0xFF; if (src < 13) snprintf(gInfo.clockSource, sizeof gInfo.clockSource, "%s", kSourceId[src]);
    pthread_mutex_unlock(&gInfoLock);
}

static size_t jappend(char *buf, size_t cap, size_t n, const char *fmt, ...) __attribute__((format(printf, 4, 5)));
static size_t jappend(char *buf, size_t cap, size_t n, const char *fmt, ...) {
    if (n >= cap) return n;
    va_list ap; va_start(ap, fmt); int m = vsnprintf(buf + n, cap - n, fmt, ap); va_end(ap);
    return m < 0 ? n : (n + (size_t)m < cap ? n + (size_t)m : cap);
}

// JSON for the app (built in the XPC thread from the copy and from counters that only grow).
static size_t buildInfoJson(char *buf, size_t cap) {
    Info n; pthread_mutex_lock(&gInfoLock); n = gInfo; pthread_mutex_unlock(&gInfoLock);
    size_t o = 0; char e[160];
    o = jappend(buf, cap, o, "{\"version\":1,\"state\":%u,\"generation\":%u,\"haveCard\":%s,\"owned\":%s", atomic_load(&H->state), atomic_load(&H->generation), n.haveCard ? "true" : "false", gOwned ? "true" : "false");
    o = jappend(buf, cap, o, ",\"sessions\":%u,\"busResets\":%u,\"uptime\":%.0f,\"leadMs\":%u,\"ioClients\":%u", gSessions, gBusResets, CFAbsoluteTimeGetCurrent() - gStartedAt, gLeadMs, atomic_load(&H->ioClients));
    o = jappend(buf, cap, o, ",\"inLate\":%llu,\"outLate\":%llu,\"inWritten\":%llu", (unsigned long long)atomic_load(&H->inLate), (unsigned long long)atomic_load(&H->outLate), (unsigned long long)atomic_load(&H->inWritten));
    o = jappend(buf, cap, o, ",\"cipErrors\":%llu,\"dbcJumps\":%llu,\"maxGapMs\":%.1f", (unsigned long long)(gC[0].badCip + gC[1].badCip), (unsigned long long)(gC[0].dbcJumps + gC[1].dbcJumps), gMaxGap * 1000);
    jesc(e, sizeof e, gLastError); o = jappend(buf, cap, o, ",\"error\":\"%s\"", e);
    if (n.haveCard) {
        o = jappend(buf, cap, o, ",\"guid\":\"0x%016llX\"", (unsigned long long)n.guid);
        jesc(e, sizeof e, n.vendor); o = jappend(buf, cap, o, ",\"vendor\":\"%s\"", e);
        jesc(e, sizeof e, n.model); o = jappend(buf, cap, o, ",\"model\":\"%s\"", e);
        o = jappend(buf, cap, o, ",\"vendorID\":%u,\"modelID\":%u,\"unitSpecID\":%u", n.vendorID, n.modelID, n.unitSpecID);
        jesc(e, sizeof e, n.nick); o = jappend(buf, cap, o, ",\"nickName\":\"%s\"", e);
        o = jappend(buf, cap, o, ",\"clockSource\":\"%s\",\"rate\":%u,\"locked\":%s,\"ext\":%u,\"dice\":\"%s\"", n.clockSource, n.rate, n.locked ? "true" : "false", n.ext, n.dice);
        o = jappend(buf, cap, o, ",\"rates\":["); for (unsigned i = 0; i < n.nRates; i++) o = jappend(buf, cap, o, "%s%u", i ? "," : "", n.rates[i]);
        o = jappend(buf, cap, o, "],\"sources\":["); for (unsigned i = 0; i < n.nSources; i++) o = jappend(buf, cap, o, "%s\"%s\"", i ? "," : "", n.sources[i]);
        o = jappend(buf, cap, o, "],\"clockSources\":[");
        for (unsigned i = 0; i < 13; i++) { jesc(e, sizeof e, n.clockLabel[i]); o = jappend(buf, cap, o, "%s{\"id\":\"%s\",\"label\":\"%s\"}", i ? "," : "", kSourceId[i], e); }
        o = jappend(buf, cap, o, "]");
        for (int dir = 0; dir < 2; dir++) {
            o = jappend(buf, cap, o, ",\"%s\":[", dir == 0 ? "tx" : "rx");
            for (unsigned s = 0; s < NSTREAM; s++) {
                typeof(n.tx[0]) *x = dir == 0 ? &n.tx[s] : &n.rx[s];
                o = jappend(buf, cap, o, "%s{\"index\":%u,\"iso\":%d,\"pcm\":%u,\"midi\":%u,\"speed\":\"%s\",\"names\":[", s ? "," : "", s, x->iso, x->pcm, x->midi, x->speed);
                for (unsigned k = 0; k < 16 && x->names[k][0]; k++) { jesc(e, sizeof e, x->names[k]); o = jappend(buf, cap, o, "%s\"%s\"", k ? "," : "", e); }
                o = jappend(buf, cap, o, "]}");
            }
            o = jappend(buf, cap, o, "]");
        }
    }
    for (int d = 0; d < 2; d++) {
        o = jappend(buf, cap, o, ",\"%s\":[", d ? "customOut" : "customIn");
        for (int k = 0; k < GSR_MAX_CH; k++) { jesc(e, sizeof e, d ? gCustomOut[k] : gCustomIn[k]); o = jappend(buf, cap, o, "%s\"%s\"", k ? "," : "", e); }
        o = jappend(buf, cap, o, "]");
    }
    o = jappend(buf, cap, o, "}");
    return o;
}

static void readNames(void) {
    for (int dir = 0; dir < 2; dir++) {
        UInt32 off = dir == 0 ? gTxOff : gRxOff, blkQ = dir == 0 ? gTxBlkQ : gRxBlkQ;
        for (unsigned s = 0; s < NSTREAM; s++) {
            UInt32 b0 = off + 8 + s * blkQ * 4;
            char raw[256];
            for (int i = 0; i < 64; i++) { UInt32 w = 0; if (rq(b0 + 0x10 + i * 4, &w)) w = 0; raw[i*4] = (char)(w >> 24); raw[i*4+1] = (char)(w >> 16); raw[i*4+2] = (char)(w >> 8); raw[i*4+3] = (char)w; }
            for (int i = 0; i + 3 < 256; i += 4) { char t0 = raw[i], t1 = raw[i+1]; raw[i] = raw[i+3]; raw[i+1] = raw[i+2]; raw[i+2] = t1; raw[i+3] = t0; }   // text comes byte-swapped per quadlet
            raw[255] = 0;
            char (*dst)[GSR_NAME_LEN] = dir == 0 ? gCardIn : gCardOut;
            int ch = 0; char *tok = raw;
            for (char *e = raw; ch < CH_PER_STREAM; e++) {
                if (*e == '\\' || *e == 0) {
                    char save = *e; *e = 0;
                    if (*tok) {
                        char *slash = strchr(tok, '/');                  // the card announces "CH16/CH15/16": channel name / stereo pair name
                        if (slash) *slash = 0;
                        snprintf(dst[s * CH_PER_STREAM + ch], GSR_NAME_LEN, "%s", tok); ch++;
                    }
                    if (!save) break;
                    tok = e + 1;
                }
            }
        }
    }
    applyNames();
}

// ---------- one streaming session ----------

typedef enum { END_QUIT, END_RATE, END_BUSRESET, END_ERROR } EndReason;

static void freeStreams(void) {
    for (unsigned i = 0; i < NSTREAM; i++) {
        CapS *c = &gC[i];
        if (c->chan) { if (c->allocated) (*c->chan)->ReleaseChannel(c->chan); releasePort(c->chan); }
        releasePort(c->local); releasePort(c->remote); releasePort(c->pool);
        free(c->buf);
        memset(c, 0, sizeof *c);
        PlayS *p = &gP[i];
        if (p->chan) { if (p->allocated) (*p->chan)->ReleaseChannel(p->chan); releasePort(p->chan); }
        releasePort(p->local); releasePort(p->remote); releasePort(p->pool);
        free(p->buf); free(p->slotLen); free(p->dcl);
        memset(p, 0, sizeof *p);
    }
    free(gKind); gKind = NULL;
}

static int buildCapture(CapS *c, unsigned idx, unsigned pcm, unsigned midi) {
    UInt32 b = gTxOff + 8 + idx * gTxBlkQ * 4;
    c->idx = idx; c->pcm = pcm; c->midi = midi; c->dbs = pcm + (midi ? 1 : 0); c->isoReg = b; c->speedReg = b + 0xC;
    c->pool = (*gDev)->CreateNuDCLPool(gDev, RING_SLOTS * 4, CFUUIDGetUUIDBytes(kIOFireWireNuDCLPoolInterfaceID));
    if (!c->pool) return 0;
    c->buf = calloc(RING_SLOTS, MAX_PKT);
    for (unsigned i = 0; i < RING_SLOTS; i++) {
        IOVirtualRange rg = {(IOVirtualAddress)(c->buf + (size_t)i * MAX_PKT), MAX_PKT};
        c->dcl[i] = (NuDCLRef)(*c->pool)->AllocateReceivePacket(c->pool, NULL, HDR_BYTES, 1, &rg);
        if (!c->dcl[i]) return 0;
        if (i % BATCH == BATCH - 1) { (*c->pool)->SetDCLRefcon(c->dcl[i], (void *)(uintptr_t)(idx << 16 | i)); (*c->pool)->SetDCLCallback(c->dcl[i], onRecv); }
    }
    for (unsigned i = 0; i < RING_SLOTS; i++) (*c->pool)->SetDCLBranch(c->dcl[i], c->dcl[(i + 1) % RING_SLOTS]);
    c->local = (*gDev)->CreateLocalIsochPort(gDev, false, (*c->pool)->GetProgram(c->pool), 0, 0, 0, NULL, 0, NULL, 0, CFUUIDGetUUIDBytes(kIOFireWireLocalIsochPortInterfaceID));
    c->remote = (*gDev)->CreateRemoteIsochPort(gDev, true, CFUUIDGetUUIDBytes(kIOFireWireRemoteIsochPortInterfaceID));
    if (!c->local || !c->remote) return 0;
    (*c->remote)->SetGetSupportedHandler(c->remote, rpGetSupported); (*c->remote)->SetAllocatePortHandler(c->remote, rpAllocate);
    (*c->remote)->SetReleasePortHandler(c->remote, rpRelease); (*c->remote)->SetStartHandler(c->remote, rpStart); (*c->remote)->SetStopHandler(c->remote, rpStop);
    c->chan = (*gDev)->CreateIsochChannel(gDev, true, 8 + gBlocks * c->dbs * 4, kFWSpeed400MBit, CFUUIDGetUUIDBytes(kIOFireWireIsochChannelInterfaceID));
    if (!c->chan) return 0;
    (*c->chan)->SetTalker(c->chan, (IOFireWireLibIsochPortRef)c->remote);
    (*c->chan)->AddListener(c->chan, (IOFireWireLibIsochPortRef)c->local);
    return 1;
}

static int buildPlayback(PlayS *ps, unsigned idx, unsigned pcm, unsigned midi) {
    UInt32 b = gRxOff + 8 + idx * gRxBlkQ * 4;
    ps->idx = idx; ps->pcm = pcm; ps->midi = midi; ps->dbs = pcm + (midi ? 1 : 0); ps->isoReg = b; ps->seqReg = b + 4;
    ps->pool = (*gDev)->CreateNuDCLPool(gDev, gL * 8, CFUUIDGetUUIDBytes(kIOFireWireNuDCLPoolInterfaceID));
    if (!ps->pool) return 0;
    (*ps->pool)->SetCurrentTagAndSync(ps->pool, 1, 0);
    size_t pktBytes = (size_t)gL * MAX_PKT;
    ps->buf = calloc(1, pktBytes + (size_t)gL * sizeof(uint32_t) + 4096);
    ps->stamp = (uint32_t *)(ps->buf + pktBytes);
    ps->slotLen = calloc(gL, sizeof(uint32_t)); ps->dcl = calloc(gL, sizeof(NuDCLRef));
    for (unsigned i = 0; i < gL; i++) {
        ps->slotLen[i] = gKind[i] ? 8 + gBlocks * ps->dbs * 4 : 8;
        IOVirtualRange rg = {(IOVirtualAddress)(ps->buf + (size_t)i * MAX_PKT), ps->slotLen[i]};
        ps->dcl[i] = (NuDCLRef)(*ps->pool)->AllocateSendPacket(ps->pool, NULL, 1, &rg);
        if (!ps->dcl[i]) return 0;
        if (i % BATCH == BATCH - 1) {
            (*ps->pool)->SetDCLRefcon(ps->dcl[i], (void *)(uintptr_t)(idx << 16 | i));
            (*ps->pool)->SetDCLCallback(ps->dcl[i], onSent);
            (*ps->pool)->SetDCLTimeStampPtr(ps->dcl[i], &ps->stamp[i]);
            (*ps->pool)->AppendDCLUpdateList(ps->dcl[i], ps->dcl[i]);
            (*ps->pool)->SetDCLFlags(ps->dcl[i], (1u << 1) | (1u << 2));       // dynamic + update before callback (values from IOFWDCL.h)
        }
    }
    for (unsigned i = 0; i < gL; i++) (*ps->pool)->SetDCLBranch(ps->dcl[i], ps->dcl[(i + 1) % gL]);
    ps->seqNo = 0; ps->dataIdx = 0; ps->dbc = 0; ps->frame = 0; ps->synced = 0;
    for (unsigned i = 0; i < gLead; i++) buildPacket(ps, i, -1, -1);              // start-up: data packets without presentation time
    IOVirtualRange whole = {(IOVirtualAddress)ps->buf, pktBytes + (size_t)gL * sizeof(uint32_t) + 4096};
    ps->local = (*gDev)->CreateLocalIsochPort(gDev, true, (*ps->pool)->GetProgram(ps->pool), 0, 0, 0, NULL, 0, &whole, 1, CFUUIDGetUUIDBytes(kIOFireWireLocalIsochPortInterfaceID));
    ps->remote = (*gDev)->CreateRemoteIsochPort(gDev, false, CFUUIDGetUUIDBytes(kIOFireWireRemoteIsochPortInterfaceID));
    if (!ps->local || !ps->remote) return 0;
    (*ps->remote)->SetGetSupportedHandler(ps->remote, rpGetSupported); (*ps->remote)->SetAllocatePortHandler(ps->remote, rpAllocate);
    (*ps->remote)->SetReleasePortHandler(ps->remote, rpRelease); (*ps->remote)->SetStartHandler(ps->remote, rpStart); (*ps->remote)->SetStopHandler(ps->remote, rpStop);
    ps->chan = (*gDev)->CreateIsochChannel(gDev, true, 8 + gBlocks * ps->dbs * 4, kFWSpeed400MBit, CFUUIDGetUUIDBytes(kIOFireWireIsochChannelInterfaceID));
    if (!ps->chan) return 0;
    (*ps->chan)->SetTalker(ps->chan, (IOFireWireLibIsochPortRef)ps->local);
    (*ps->chan)->AddListener(ps->chan, (IOFireWireLibIsochPortRef)ps->remote);
    return 1;
}

// Maps the bus cycle time onto the mach clock and places the first presented playback block on the capture sample time axis.
static void calibrateOutput(void) {
    gOutCal = 0;
    if (!gHavePres || !dllInit) { gD = 0; gOutCal = 1; logf2("output alignment: no presentation time recorded, offset 0"); return; }
    UInt32 ct = 0; UInt64 up = 0; double bestW = 1e18; UInt32 bct = 0; UInt64 bup = 0;
    for (int i = 0; i < 16; i++) {
        uint64_t a = mach_absolute_time();
        if ((*gDev)->GetCycleTimeAndUpTime(gDev, &ct, &up) != kIOReturnSuccess) continue;
        uint64_t b = mach_absolute_time();
        if ((double)(b - a) < bestW) { bestW = (double)(b - a); bct = ct; bup = up; }
    }
    if (bestW > 1e17) { gD = 0; gOutCal = 1; logf2("output alignment: cycle time unavailable, offset 0"); return; }
    double busNow = (double)((bct >> 25) & 0x7F) * 24576000.0 + (double)((bct >> 12) & 0x1FFF) * 3072.0 + (double)(bct & 0xFFF);
    // The DMA time stamps carry only 3 bits of bus seconds (OHCI time stamp), the cycle time register 7: compare modulo 8 s.
    const double W = 8.0 * 24576000.0;
    double x = fmod(gPresBus - busNow, W);
    if (x > W / 2) x -= W;
    if (x < -W / 2) x += W;
    double hostPres = (double)bup + x / 24576000.0 * gHostHz;      // upTime is in mach absolute time units (checked at run time below)
    double nPlay0 = (double)dllN + (hostPres - dllT) / dllTpf;
    gD = (int64_t)llround(nPlay0 - (double)gP0);
    gOutCal = 1;
    logf2("output alignment: first presented block %" PRIu64 " plays at capture sample time %.0f -> offset %" PRId64 " frames (%.2f ms); cycle-time read took %.0f us, upTime/mach delta %.0f us",
          gP0, nPlay0, gD, (double)gD / gRate * 1000.0, bestW * gTb.numer / gTb.denom / 1000.0,
          ((double)bup - (double)mach_absolute_time()) * gTb.numer / gTb.denom / 1000.0);
}

static EndReason runSession(unsigned rate, unsigned *nextRate) {
    EndReason reason = END_ERROR;
    int started = 0;
    memset(gC, 0, sizeof gC); memset(gP, 0, sizeof gP);
    gOutActive = 0; gOutWSeen = 0; gOutWChanged = 0;
    gSyncStarted = 0; gHavePres = 0; gRxCnt = 0; gRxHave = 0; gMeasuring = 0; gPreEnabled = 0; gOutCal = 0; gD = 0; dllInit = 0; gMaxGap = 0; gLastCb = 0;
    gRate = rate; gBlocks = rate <= 48000 ? 8 : 16;
    gLeadTicks = rate >= 88200 ? 4500.0 : 12800.0;
    atomic_store(&H->state, GSR_STATE_IDLE);

    gLastError[0] = 0;
    if (!setClock(rate, gSourceIdx)) {
        if (gSourceIdx != 12) {
            logf2("no lock on %s at %u Hz: back to the internal clock", kSourceId[gSourceIdx], rate);
            snprintf(gLastError, sizeof gLastError, "pas de signal %s à %u Hz : retour à l'horloge interne", gSourceIdx == 7 ? "Word Clock" : kSourceId[gSourceIdx], rate);
            gSourceIdx = 12;
            if (!setClock(rate, 12)) { logf2("the card did not lock at %u Hz even on the internal clock", rate); goto done; }
        } else { logf2("the card did not lock at %u Hz", rate); snprintf(gLastError, sizeof gLastError, "la carte ne verrouille pas à %u Hz", rate); goto done; }
    }
    unsigned pcmT[NSTREAM], midiT[NSTREAM], pcmR[NSTREAM], midiR[NSTREAM];
    for (unsigned i = 0; i < NSTREAM; i++) {
        UInt32 a = 0, m = 0, a2 = 0, m2 = 0;
        rq(gTxOff + 8 + i * gTxBlkQ * 4 + 4, &a); rq(gTxOff + 8 + i * gTxBlkQ * 4 + 8, &m);
        rq(gRxOff + 8 + i * gRxBlkQ * 4 + 8, &a2); rq(gRxOff + 8 + i * gRxBlkQ * 4 + 0xC, &m2);
        pcmT[i] = a; midiT[i] = m; pcmR[i] = a2; midiR[i] = m2;
        if (a != CH_PER_STREAM || a2 != CH_PER_STREAM) { logf2("unexpected stream layout (%u/%u channels)", a, a2); goto done; }
    }
    // header for this generation
    atomic_fetch_add(&H->generation, 1);
    atomic_store(&H->sampleRate, rate);
    H->channelsIn = H->channelsOut = GSR_MAX_CH;
    gLead = gLeadMs * 8;
    unsigned inMs = gLeadMs <= 40 ? 6 : gLeadMs <= 80 ? 10 : gLeadMs <= 160 ? 16 : 30;   // input arrives up to a callback gap late (5 to 6 ms seen): the safety offset has to cover it
    H->safetyIn = (uint32_t)lround(rate * inMs / 1000.0); H->safetyOut = (uint32_t)lround(rate * (gLeadMs + 3) / 1000.0);   // output data is read gLeadMs ahead of the card
    H->inLatencyFrames = 0; H->outLatencyFrames = 0;
    readNames();
    collectStatic(); gSessions++;
    memset(gsr_in_ring(H), 0, (size_t)H->ringFrames * GSR_MAX_CH * sizeof(float));
    memset(gsr_out_ring(H), 0, (size_t)H->ringFrames * GSR_MAX_CH * sizeof(float));
    atomic_store(&H->inWritten, 0); atomic_store(&H->outRead, 0); atomic_store(&H->outWritten, 0);
    atomic_store(&H->inLate, 0); atomic_store(&H->outLate, 0);
    gOutRing = (uint8_t *)gsr_out_ring(H); gOutMask = H->ringFrames - 1;

    for (unsigned i = 0; i < NSTREAM; i++) if (!buildCapture(&gC[i], i, pcmT[i], midiT[i])) { logf2("capture setup failed"); goto done; }

    // 1. listen to the card alone to learn how fast its presentation time advances
    gMeasuring = 1;
    {
        IOReturn r;
        if ((r = (*gC[0].chan)->AllocateChannel(gC[0].chan))) { logf2("AllocateChannel (measure) 0x%x", r); goto done; }
        gC[0].allocated = 1;
        if ((r = (*gC[0].chan)->Start(gC[0].chan))) { logf2("Start (measure) 0x%x", r); goto done; }
        CFAbsoluteTime tm = CFAbsoluteTimeGetCurrent();
        while (CFAbsoluteTimeGetCurrent() - tm < 0.6) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
        (*gC[0].chan)->Stop(gC[0].chan);
        wq(gEnableReg, 0); wq(gC[0].isoReg, 0xFFFFFFFFu);
        (*gC[0].chan)->ReleaseChannel(gC[0].chan); gC[0].allocated = 0;
    }
    gMeasuring = 0;
    if (gRxCnt < 1500) { logf2("not enough card packets to measure its timeline (%" PRIu64 ")", gRxCnt); goto done; }
    gR = (gRxU - gRxFirstU) / (double)(gRxCnt - 1 - gRxFirstCnt);
    logf2("rate %u: card presentation time advance %.4f ticks per data packet (%+.1f ppm against 4096)", rate, gR, (gR / 4096.0 - 1) * 1e6);
    usleep(300000);
    for (unsigned i = 0; i < NSTREAM; i++) { CapS *c = &gC[i]; c->packets = c->data = c->empty = c->badCip = c->badDbs = c->dbcJumps = c->startup = c->shortPkt = 0; c->haveDbc = 0; c->fw = 0; c->haveU0 = 0; c->active = 0; c->t0 = 0; }

    // 2. playback ring: a lap holds a whole number of data packets at the card's rate
    {
        unsigned bestL = 8000; double bestRes = 1e9;
        for (unsigned L = 6000; L <= 12000; L += 8) { double q = L * 3072.0 / gR, res = fabs(q - round(q)); if (res < bestRes) { bestRes = res; bestL = L; } }
        gL = bestL; gKind = calloc(gL, 1);
        double cr = gR * 0.5;
        for (unsigned i = 0; i < gL; i++) { cr += 3072.0; if (cr >= gR) { gKind[i] = 1; cr -= gR; } }
        if (gLead * 2 > gL) gLead = gL / 4;
    }
    for (unsigned i = 0; i < NSTREAM; i++) if (!buildPlayback(&gP[i], i, pcmR[i], midiR[i])) { logf2("playback setup failed"); goto done; }

    // 3. allocate everything, then the vendor start order: ENABLE once, 2 ms, send ports, then receive ports
    {
        IOReturn r = 0;
        for (unsigned i = 0; i < NSTREAM && !r; i++) { r = (*gC[i].chan)->AllocateChannel(gC[i].chan); if (!r) gC[i].allocated = 1; }
        for (unsigned i = 0; i < NSTREAM && !r; i++) { r = (*gP[i].chan)->AllocateChannel(gP[i].chan); if (!r) gP[i].allocated = 1; }
        if (r) { logf2("AllocateChannel 0x%x", r); goto done; }
        gSessionStart = CFAbsoluteTimeGetCurrent();
        (*gDev)->GetGenerationAndNodeID(gDev, &gGenAtStart, &(UInt16){0});
        started = 1;
        r = wq(gEnableReg, 1); usleep(2000); gPreEnabled = 1;
        for (unsigned i = 0; i < NSTREAM && !r; i++) r = (*gP[i].chan)->Start(gP[i].chan);
        for (unsigned i = 0; i < NSTREAM && !r; i++) r = (*gC[i].chan)->Start(gC[i].chan);
        if (r) { logf2("Start 0x%x", r); goto done; }
    }
    logf2("streaming at %u Hz: %u + %u capture channels, %u + %u playback channels", rate, pcmT[0], pcmT[1], pcmR[0], pcmR[1]);

    // 4. run
    {
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent(), lastStat = t0, lastLog = t0;
        UInt32 lastExt = 0xDEADBEEF; int calibrated = 0, unlockedPolls = 0;
        reason = END_ERROR;
        for (;;) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (gQuit) { reason = END_QUIT; break; }
            if (gRunSeconds > 0 && now - t0 > gRunSeconds) { gQuit = 1; reason = END_QUIT; break; }
            if (gBusReset) { reason = END_BUSRESET; break; }
            { UInt32 g = 0; UInt16 nd; (*gDev)->GetGenerationAndNodeID(gDev, &g, &nd); if (g != gGenAtStart) { gBusReset = 1; reason = END_BUSRESET; break; } }
            if (gRestartWanted) { gRestartWanted = 0; *nextRate = rate; reason = END_RATE; break; }
            uint32_t rr = atomic_load(&H->requestedRate);
            if (rr) {
                atomic_store(&H->requestedRate, 0);
                if (rr != rate && (rr == 44100 || rr == 48000 || rr == 88200 || rr == 96000)) { *nextRate = rr; reason = END_RATE; break; }
            }
            { uint64_t w = atomic_load_explicit(&H->outWritten, memory_order_acquire), in = atomic_load_explicit(&H->inWritten, memory_order_relaxed);
              if (w > in + 4ull * H->ringFrames) {              // a value left by an old time line of the client: forget it, the plug-in writes it again
                  logf2("output position %" PRIu64 " is far ahead of the input position %" PRIu64 ": reset", w, in);
                  atomic_store(&H->outWritten, 0); w = 0;
              }
              if (w != gOutWSeen) { gOutWSeen = w; gOutWChanged = now; }
              gOutActive = (now - gOutWChanged) < 0.25; }
            if (!calibrated && now - t0 > 1.5) { calibrated = 1; calibrateOutput(); }
            if (!calibrated && now - t0 > 4.0) { calibrated = 1; gD = 0; gOutCal = 1; }
            if (now - lastLog >= 30.0) {
                lastLog = now;
                logf2("stats: capture data packets %" PRIu64 "/%" PRIu64 " (CIP errors %" PRIu64 ", DBC jumps %" PRIu64 "), longest send callback gap %.1f ms, input late %" PRIu64 ", output late %" PRIu64 ", clients %u",
                      gC[0].data, gC[1].data, gC[0].badCip + gC[1].badCip, gC[0].dbcJumps + gC[1].dbcJumps, gMaxGap * 1000, (uint64_t)atomic_load(&H->inLate), (uint64_t)atomic_load(&H->outLate), atomic_load(&H->ioClients));
                gMaxGap = 0;
            }
            if (now - lastStat >= 1.0) {
                lastStat = now;
                UInt32 ext = 0;
                if (!rq(gGlobalOff + 0x58, &ext) && ext != lastExt) { logf2("EXTENDED_STATUS 0x%08x", ext); lastExt = ext; }
                refreshLive();
                { pthread_mutex_lock(&gInfoLock); int lk = gInfo.locked; pthread_mutex_unlock(&gInfoLock);
                  unlockedPolls = lk ? 0 : unlockedPolls + 1;
                  if (gSourceIdx != 12 && unlockedPolls >= 3) {
                      logf2("the card lost the external clock: back to the internal clock");
                      snprintf(gLastError, sizeof gLastError, "signal %s perdu : retour à l'horloge interne", gSourceIdx == 7 ? "Word Clock" : "externe");
                      gSourceIdx = 12; gRestartWanted = 1; unlockedPolls = 0;
                  } }
            }
        }
    }
done:
    if (started || gC[0].allocated || gC[1].allocated || gP[0].allocated || gP[1].allocated) {
        for (unsigned i = 0; i < NSTREAM; i++) { if (gP[i].chan && gP[i].allocated) (*gP[i].chan)->Stop(gP[i].chan); }
        for (unsigned i = 0; i < NSTREAM; i++) { if (gC[i].chan && gC[i].allocated) (*gC[i].chan)->Stop(gC[i].chan); }
    }
    atomic_store(&H->state, GSR_STATE_IDLE);
    if (!gBusReset) cleanCard();
    uint64_t late = atomic_load(&H->outLate);
    if (started) logf2("session over: capture packets %" PRIu64 "/%" PRIu64 " (CIP errors %" PRIu64 ", DBC jumps %" PRIu64 "), playback sent %" PRIu64 "/%" PRIu64 ", input frames %" PRIu64 ", output frames late %" PRIu64 ", longest send callback gap %.1f ms",
        gC[0].data, gC[1].data, gC[0].badCip + gC[1].badCip, gC[0].dbcJumps + gC[1].dbcJumps, gP[0].sent, gP[1].sent, (uint64_t)atomic_load(&H->inWritten), late, gMaxGap * 1000);
    freeStreams();
    return reason;
}

// ---------- ring memory and XPC ----------

static void setupRing(void) {
    gRingBytes = (size_t)gsr_ring_bytes(RING_FRAMES);
    if (gFilePath) {
        int fd = open(gFilePath, O_RDWR | O_CREAT | O_TRUNC, 0644);
        if (fd < 0 || ftruncate(fd, (off_t)gRingBytes)) { perror("ring file"); exit(1); }
        H = mmap(NULL, gRingBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (H == MAP_FAILED) { perror("mmap"); exit(1); }
    } else {
        vm_address_t va = 0;
        if (vm_allocate(mach_task_self(), &va, gRingBytes, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) exit(1);
        H = (GsrRingHeader *)va;
    }
    memset(H, 0, 4096);
    H->magic = GSR_RING_MAGIC; H->version = GSR_RING_VERSION;
    atomic_store(&H->state, GSR_STATE_DOWN); atomic_store(&H->sampleRate, 48000);
    H->channelsIn = H->channelsOut = GSR_MAX_CH; H->ringFrames = RING_FRAMES;
    H->inOffset = 4096; H->outOffset = 4096 + (uint64_t)RING_FRAMES * GSR_MAX_CH * sizeof(float); H->totalBytes = gsr_ring_bytes(RING_FRAMES);
    for (int k = 0; k < GSR_MAX_CH; k++) { snprintf(H->nameIn[k], GSR_NAME_LEN, "CH%d", k + 1); snprintf(H->nameOut[k], GSR_NAME_LEN, "CH%d", k + 1); }
    H->safetyIn = 192; H->safetyOut = 2064;
    atomic_store(&H->generation, 1);
}

static void startXpc(void) {
    xpc_connection_t l = xpc_connection_create_mach_service(GSR_MACH_SERVICE, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), XPC_CONNECTION_MACH_SERVICE_LISTENER);
    xpc_connection_set_event_handler(l, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
        xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
            if (xpc_get_type(msg) != XPC_TYPE_DICTIONARY) return;
            xpc_object_t reply = xpc_dictionary_create_reply(msg);
            if (!reply) return;
            const char *op = xpc_dictionary_get_string(msg, "op");
            if (!op || !strcmp(op, "ring")) {
                xpc_dictionary_set_value(reply, "ring", xpc_shmem_create(H, gRingBytes));
                logf2("ring handed to pid %d", xpc_connection_get_pid(peer));
            } else if (!strcmp(op, "info")) {
                static char json[32768];                                   // one request at a time is enough for a polling app
                static pthread_mutex_t jl = PTHREAD_MUTEX_INITIALIZER;
                pthread_mutex_lock(&jl);
                size_t n = buildInfoJson(json, sizeof json - 1); json[n] = 0;
                xpc_dictionary_set_string(reply, "json", json);
                pthread_mutex_unlock(&jl);
            } else if (!strcmp(op, "setRate")) {
                uint64_t r = xpc_dictionary_get_uint64(msg, "rate");
                int ok = r == 44100 || r == 48000 || r == 88200 || r == 96000;
                if (ok) atomic_store(&H->requestedRate, (uint32_t)r);
                xpc_dictionary_set_bool(reply, "ok", ok);
                logf2("app asks for %llu Hz: %s", (unsigned long long)r, ok ? "accepted" : "refused");
            } else if (!strcmp(op, "setLead")) {
                uint64_t ms = xpc_dictionary_get_uint64(msg, "ms");
                int ok = ms >= 10 && ms <= 400;
                if (ok && ms != gLeadMs) { gLeadMs = (unsigned)ms; gRestartWanted = 1; }
                xpc_dictionary_set_bool(reply, "ok", ok);
                logf2("app asks for a playback lead of %llu ms: %s", (unsigned long long)ms, ok ? "accepted" : "refused");
            } else if (!strcmp(op, "setSource")) {
                const char *id = xpc_dictionary_get_string(msg, "id");
                unsigned idx = 99;
                if (id) for (unsigned i = 0; i < 13; i++) if (!strcmp(id, kSourceId[i])) idx = i;
                int supported = 0;
                pthread_mutex_lock(&gInfoLock);
                for (unsigned i = 0; i < gInfo.nSources; i++) if (id && !strcmp(gInfo.sources[i], id)) supported = 1;
                pthread_mutex_unlock(&gInfoLock);
                int ok = (idx == 12 || idx == 7) && supported;
                if (ok && idx != gSourceIdx) { gSourceIdx = idx; gRestartWanted = 1; }
                xpc_dictionary_set_bool(reply, "ok", ok);
                logf2("app asks for the clock source %s: %s", id ? id : "?", ok ? "accepted" : "refused");
            } else if (!strcmp(op, "setNames")) {
                xpc_object_t in = xpc_dictionary_get_value(msg, "in"), out = xpc_dictionary_get_value(msg, "out");
                int ok = in && out && xpc_get_type(in) == XPC_TYPE_ARRAY && xpc_get_type(out) == XPC_TYPE_ARRAY && xpc_array_get_count(in) == GSR_MAX_CH && xpc_array_get_count(out) == GSR_MAX_CH;
                if (ok) {
                    for (int k = 0; k < GSR_MAX_CH; k++) {
                        const char *a = xpc_array_get_string(in, k), *b = xpc_array_get_string(out, k);
                        snprintf(gCustomIn[k], GSR_NAME_LEN, "%s", a ? a : ""); snprintf(gCustomOut[k], GSR_NAME_LEN, "%s", b ? b : "");
                    }
                    applyNames(); saveNames();
                    logf2("channel names updated by the app");
                }
                xpc_dictionary_set_bool(reply, "ok", ok);
            } else xpc_dictionary_set_bool(reply, "ok", false);
            xpc_connection_send_message(peer, reply);
        });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(l);
}

static void onSignal(int s) { (void)s; gQuit = 1; CFRunLoopStop(CFRunLoopGetMain()); }

static void makeRealtime(void) {
    thread_time_constraint_policy_data_t p;
    p.period = (uint32_t)(gHostHz * 0.001); p.computation = (uint32_t)(gHostHz * 0.0002); p.constraint = (uint32_t)(gHostHz * 0.0006); p.preemptible = 1;
    kern_return_t r = thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&p, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    logf2("real-time policy %s", r == KERN_SUCCESS ? "set" : "FAILED");
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--file") && i + 1 < argc) gFilePath = argv[++i];
        else if (!strcmp(argv[i], "--xpc")) gUseXpc = 1;
        else if (!strcmp(argv[i], "--rate") && i + 1 < argc) gInitialRate = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) gRunSeconds = atof(argv[++i]);
        else if (!strcmp(argv[i], "--quiet")) gQuiet = 1;
        else if (!strcmp(argv[i], "--lead-ms") && i + 1 < argc) { gLeadMs = (unsigned)atoi(argv[++i]); if (gLeadMs < 10) gLeadMs = 10; if (gLeadMs > 400) gLeadMs = 400; }
    }
    if (!gFilePath && !gUseXpc) { fprintf(stderr, "usage: gsrd --file PATH | --xpc  [--rate N] [--seconds S]\n"); return 2; }
    mach_timebase_info(&gTb); gHostHz = 1e9 * gTb.denom / gTb.numer;
    gStartedAt = CFAbsoluteTimeGetCurrent();
    setupRing();
    loadNames(); applyNames();
    signal(SIGINT, onSignal); signal(SIGTERM, onSignal);
    if (gUseXpc) startXpc();
    makeRealtime();
    unsigned want = gInitialRate;
    int cardEverOpened = 0;
    while (!gQuit) {
        atomic_store(&H->state, GSR_STATE_DOWN);
        pthread_mutex_lock(&gInfoLock); gInfo.haveCard = 0; pthread_mutex_unlock(&gInfoLock);
        if (!openCard()) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false); continue; }
        logf2("card found");
        if (!readLayout()) { logf2("could not read the register map"); closeCard(); CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2.0, false); continue; }
        UInt32 cs = 0, st = 0; rq(gClockSelReg, &cs); rq(gGlobalOff + 0x54, &st);
        if (!cardEverOpened) { gOrigClock = cs; gSourceIdx = (cs & 0xFF) == 7 ? 7 : 12; }
        cardEverOpened = 1;
        // A card left dirty (streaming, or channels set) by an aborted run is cleaned only if nobody owns it.
        UInt32 o0 = 0, o1 = 0; rq(gGlobalOff, &o0); rq(gGlobalOff + 4, &o1);
        if (o0 != 0xFFFF0000u || o1 != 0) { logf2("card is owned by another host (0x%08x%08x); waiting", o0, o1); snprintf(gLastError, sizeof gLastError, "carte occupée par un autre pilote (OWNER 0x%08x%08x)", o0, o1); closeCard(); CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3.0, false); continue; }
        cleanCard();
        if (!takeOwner()) { closeCard(); CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3.0, false); continue; }
        if (!want) { unsigned code = (cs >> 8) & 0xFF; want = code < 7 ? kRateTbl[code] : 48000; if (want != 44100 && want != 48000 && want != 88200 && want != 96000) want = 48000; }
        int errors = 0;
        while (!gQuit && !gBusReset) {
            unsigned next = want;
            EndReason r = runSession(want, &next);
            if (r == END_QUIT) break;
            if (r == END_BUSRESET) { logf2("bus reset"); gBusResets++; snprintf(gLastError, sizeof gLastError, "reset du bus FireWire"); break; }
            if (r == END_RATE) { want = next; errors = 0; continue; }
            if (++errors >= 4) { logf2("giving up on this card for now"); break; }
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
        }
        if (!gBusReset) {
            cleanCard();
            if (gOrigClock) { wq(gClockSelReg, gOrigClock); logf2("clock put back to 0x%08x", gOrigClock); }
            releaseOwner();
        }
        closeCard();
        if (gBusReset) { logf2("waiting for the card to come back"); CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2.0, false); }
        gBusReset = 0;
    }
    atomic_store(&H->state, GSR_STATE_DOWN);
    logf2("stopped");
    return 0;
}
