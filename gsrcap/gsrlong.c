// SPDX-License-Identifier: Apache-2.0
//
// gsrlong: long capture test. Receives BOTH TX streams (card channels 1 to 32) of a GS-R24 at the same
// time for a given duration and checks them: packet and CIP counters, data block count continuity,
// per-second level and click detection on channels that carry a signal, clock lock, and the drift
// between the card's sample clock and the Mac's clock. No audio file is written unless -o is given.
//
// Same rules as gsrcap: only volatile run-time registers are written (CLOCK_SELECT when -r is used,
// stream ISOCHRONOUS and SPEED, GLOBAL ENABLE). Everything is put back on exit, also on Ctrl-C.
//
// Build: clang -O1 -Wall -o gsrlong gsrlong.c -framework IOKit -framework CoreFoundation
// Usage: ./gsrlong                 plan only
//        ./gsrlong --go [-t seconds] [-r rate] [-o prefix]

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
#include <time.h>
#include <pthread.h>
#include <pthread/qos.h>

#define BASE_HI 0xFFFF
#define BASE_LO 0xE0000000u
#define MAX_RING 2048
static unsigned gRing = 160;     // packets in the receive ring (160 = 20 ms, as the vendor driver)
#define HDR_BYTES 4
#define BUF_STRIDE 2048
#define MAX_SEC 3600
#define MAX_STREAMS 2

static IOFireWireLibDeviceRef gDev;
static io_object_t gSvc;
static UInt32 gGen;
static int gRetries;

static IOReturn rq(UInt32 off, UInt32 *v) {
    IOReturn r = kIOReturnError;
    for (int t = 0; t < 10; t++) {
        UInt16 node; uint8_t b[4]; UInt32 sz = 4;
        (*gDev)->GetGenerationAndNodeID(gDev, &gGen, &node);
        FWAddress a = {0, BASE_HI, BASE_LO + off};
        r = (*gDev)->Read(gDev, gSvc, &a, b, &sz, true, gGen);
        if (r == kIOReturnSuccess) { *v = (UInt32)b[0] << 24 | (UInt32)b[1] << 16 | (UInt32)b[2] << 8 | b[3]; return r; }
        gRetries++; usleep(50000);
    }
    return r;
}
static IOReturn wq(UInt32 off, UInt32 v) {
    IOReturn r = kIOReturnError;
    for (int t = 0; t < 10; t++) {
        UInt16 node; UInt32 sz = 4;
        uint8_t b[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
        (*gDev)->GetGenerationAndNodeID(gDev, &gGen, &node);
        FWAddress a = {0, BASE_HI, BASE_LO + off};
        r = (*gDev)->Write(gDev, gSvc, &a, b, &sz, true, gGen);
        if (r == kIOReturnSuccess) return r;
        gRetries++; usleep(50000);
    }
    return r;
}

static uint64_t propNum(io_object_t svc, CFStringRef key) {
    uint64_t v = 0;
    CFTypeRef t = IORegistryEntrySearchCFProperty(svc, kIOServicePlane, key, kCFAllocatorDefault,
                                                  kIORegistryIterateRecursively);
    if (t) {
        if (CFGetTypeID(t) == CFNumberGetTypeID()) CFNumberGetValue(t, kCFNumberSInt64Type, &v);
        CFRelease(t);
    }
    return v;
}

static const unsigned rateTable[] = {32000, 44100, 48000, 88200, 96000, 176400, 192000};

// ---- streams ---------------------------------------------------------------------------------------

typedef struct {
    unsigned idx;
    uint32_t pcm, midi, dbs;
    UInt32 isoReg, speedReg;
    uint8_t *buf;
    NuDCLRef dcls[MAX_RING];
    IOFireWireLibNuDCLPoolRef pool;
    IOFireWireLibLocalIsochPortRef local;
    IOFireWireLibRemoteIsochPortRef remote;
    IOFireWireLibIsochChannelRef chan;
    uint64_t packets, data, empty, badCip, badDbs, dbcJumps, noSyt, shortPk, startupEvents;
    uint32_t lastDbc; int haveDbc;
    struct { double t; uint64_t pk; uint32_t expect, got; } ev[8]; unsigned nEv;
    CFAbsoluteTime lastCb; double maxGap; struct { double t, gap; } gaps[8]; unsigned nGaps;
    uint64_t frames;
    // per channel and per second accumulators
    uint32_t secFrames;
    double sumsq[64], peak[64], maxStep[64], prev[64];
    int havePrev;
    float secRms[64][MAX_SEC], secPeak[64][MAX_SEC], secClick[64][MAX_SEC];
    uint32_t nSec;
    FILE *wav;
} Stream;

static Stream gS[MAX_STREAMS];
static unsigned gNStreams = 2;
static unsigned gRate;
static UInt32 gGlobalOff, gTxOff, gTxBlock;
static UInt32 gEnableReg, gClockSelReg, gOrigClock;
static int gTouched, gClockChanged;
static volatile sig_atomic_t gStop;
static CFAbsoluteTime gT0, gT1;
static const double kToneHz = 1002.0;       // only used to judge clicks on channels that carry a tone

static int waitLock(UInt32 code, int ms) {
    for (int t = 0; t < ms; t += 20) {
        UInt32 st;
        if (rq(gGlobalOff + 0x54, &st) == kIOReturnSuccess && (st & 1) && ((st >> 8) & 0xFF) == code) return 1;
        usleep(20000);
    }
    return 0;
}

static void restoreCard(void) {
    if (!gDev || !gTouched) return;
    wq(gEnableReg, 0);
    for (unsigned i = 0; i < gNStreams; i++) if (gS[i].isoReg) wq(gS[i].isoReg, 0xFFFFFFFFu);
    if (gClockChanged) {
        wq(gClockSelReg, gOrigClock);
        printf("  rate restored: %s\n", waitLock((gOrigClock >> 8) & 0xFF, 3000) ? "locked" : "NOT LOCKED, check the card");
        gClockChanged = 0;
    }
    gTouched = 0;
}
static void onSignal(int s) { (void)s; gStop = 1; CFRunLoopStop(CFRunLoopGetMain()); }

static void closeSecond(Stream *s) {
    if (s->nSec < MAX_SEC) {
        for (uint32_t c = 0; c < s->pcm; c++) {
            double rms = sqrt(s->sumsq[c] / (s->secFrames ? s->secFrames : 1));
            s->secRms[c][s->nSec] = (float)rms;
            s->secPeak[c][s->nSec] = (float)s->peak[c];
            double exp = 2 * s->peak[c] * sin(M_PI * kToneHz / gRate);
            s->secClick[c][s->nSec] = exp > 0 ? (float)(s->maxStep[c] / exp) : 0;
        }
        s->nSec++;
    }
    for (uint32_t c = 0; c < s->pcm; c++) { s->sumsq[c] = 0; s->peak[c] = 0; s->maxStep[c] = 0; }
    s->secFrames = 0;
}

static void onPacket(void *refcon, NuDCLRef dcl) {
    (void)dcl;
    unsigned sid = (unsigned)((uintptr_t)refcon >> 16), idx = (unsigned)((uintptr_t)refcon & 0xFFFF);
    Stream *s = &gS[sid];
    const uint8_t *p = s->buf + (size_t)idx * BUF_STRIDE;
    s->packets++;
    if (s->packets == 1) gT0 = CFAbsoluteTimeGetCurrent();
    gT1 = CFAbsoluteTimeGetCurrent();
    if (s->lastCb > 0) {
        double gap = gT1 - s->lastCb;
        if (gap > s->maxGap) s->maxGap = gap;
        if (gap > 0.008 && s->nGaps < 8) { s->gaps[s->nGaps].t = gT1 - gT0; s->gaps[s->nGaps].gap = gap; s->nGaps++; }
    }
    s->lastCb = gT1;

    uint32_t len = (uint32_t)p[2] | (uint32_t)p[3] << 8;
    const uint8_t *q = p + HDR_BYTES;
    int startup = (gT1 - gT0) < 0.25;   // the card restarts its block counter once the stream is established
    if (len < 8 || len > BUF_STRIDE - HDR_BYTES) { if (startup) s->startupEvents++; else s->shortPk++; return; }
    if ((q[0] & 0xC0) != 0x00 || (q[4] & 0xC0) != 0x80 || (q[4] & 0x3F) != 0x10) { s->badCip++; return; }
    uint32_t dbs = q[1], dbc = q[3], fdf = q[5], syt = (uint32_t)q[6] << 8 | q[7];
    if (syt == 0xFFFF) s->noSyt++;
    if (len == 8) { s->empty++; return; }
    if (dbs != s->dbs) { s->badDbs++; return; }
    uint32_t blocks = (len - 8) / (dbs * 4);
    if (s->haveDbc && (s->lastDbc & 0xFF) != dbc) {
        if (s->nEv < 8) { s->ev[s->nEv].t = gT1 - gT0; s->ev[s->nEv].pk = s->packets; s->ev[s->nEv].expect = s->lastDbc & 0xFF; s->ev[s->nEv].got = dbc; s->nEv++; }
        if (startup) s->startupEvents++; else s->dbcJumps++;
    }
    s->lastDbc = dbc + blocks; s->haveDbc = 1;
    s->data++;
    if (fdf < 7 && rateTable[fdf] != gRate) s->badCip++;

    const uint8_t *a = q + 8;
    for (uint32_t b = 0; b < blocks; b++, a += dbs * 4) {
        for (uint32_t c = 0; c < s->pcm; c++) {
            int32_t v = (int32_t)((uint32_t)a[c * 4 + 1] << 24 | (uint32_t)a[c * 4 + 2] << 16 | (uint32_t)a[c * 4 + 3] << 8);
            double x = (double)v / 2147483648.0;
            s->sumsq[c] += x * x;
            double ax = fabs(x); if (ax > s->peak[c]) s->peak[c] = ax;
            if (s->havePrev) { double d = fabs(x - s->prev[c]); if (d > s->maxStep[c]) s->maxStep[c] = d; }
            s->prev[c] = x;
            if (s->wav) fwrite(&v, 4, 1, s->wav);
        }
        s->havePrev = 1;
        s->frames++;
        if (++s->secFrames >= gRate) closeSecond(s);
    }
}

// ---- remote port: the card as talker (one per stream) ------------------------------------------------

static Stream *streamOf(IOFireWireLibIsochPortRef self) {
    for (unsigned i = 0; i < gNStreams; i++) if ((void *)gS[i].remote == (void *)self) return &gS[i];
    return NULL;
}
static IOReturn rpGetSupported(IOFireWireLibIsochPortRef self, IOFWSpeed *sp, UInt64 *ch) {
    (void)self; *sp = kFWSpeed400MBit; *ch = 0xFFFFFFFFFFFFFFFFULL; return kIOReturnSuccess;
}
static IOReturn rpAllocate(IOFireWireLibIsochPortRef self, IOFWSpeed speed, UInt32 chan) {
    Stream *s = streamOf(self); if (!s) return kIOReturnError;
    printf("  stream %u: channel %u allocated, speed code %u\n", s->idx, chan, (unsigned)speed);
    gTouched = 1;
    IOReturn r = wq(s->isoReg, chan);
    if (r == kIOReturnSuccess) r = wq(s->speedReg, (UInt32)speed);
    return r;
}
static IOReturn rpRelease(IOFireWireLibIsochPortRef self) {
    Stream *s = streamOf(self); if (s) wq(s->isoReg, 0xFFFFFFFFu); return kIOReturnSuccess;
}
static IOReturn rpStart(IOFireWireLibIsochPortRef self) { (void)self; usleep(2000); gTouched = 1; return wq(gEnableReg, 1); }
static IOReturn rpStop(IOFireWireLibIsochPortRef self) { (void)self; return wq(gEnableReg, 0); }

// ---- main --------------------------------------------------------------------------------------------------

static int die(const char *what, IOReturn r) {
    fprintf(stderr, "FAILED: %s (IOReturn 0x%08x)\n", what, (unsigned)r);
    restoreCard();
    return 1;
}
static double db(double v) { return v > 0 ? 20 * log10(v) : -200; }

int main(int argc, char **argv) {
    int go = 0, nopoll = 0, qos = 0; double seconds = 60; unsigned reqRate = 0; const char *prefix = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--go")) go = 1;
        else if (!strcmp(argv[i], "-t") && i + 1 < argc) seconds = atof(argv[++i]);
        else if (!strcmp(argv[i], "-r") && i + 1 < argc) reqRate = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "-o") && i + 1 < argc) prefix = argv[++i];
        else if (!strcmp(argv[i], "--nopoll")) nopoll = 1;
        else if (!strcmp(argv[i], "--qos")) qos = 1;
        else if (!strcmp(argv[i], "-R") && i + 1 < argc) { gRing = (unsigned)atoi(argv[++i]); if (gRing < 32) gRing = 32; if (gRing > MAX_RING) gRing = MAX_RING; }
    }
    if (seconds > MAX_SEC - 2) seconds = MAX_SEC - 2;
    if (qos) pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

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
    gGlobalOff = t[0] * 4; gTxOff = t[2] * 4;
    UInt32 nTx, blkQ, enable, status, clkSel;
    if ((r = rq(gTxOff, &nTx)) || (r = rq(gTxOff + 4, &blkQ))) return die("read TX header", r);
    gTxBlock = blkQ * 4; gEnableReg = gGlobalOff + 0x50;
    rq(gEnableReg, &enable); rq(gGlobalOff + 0x54, &status); rq(gGlobalOff + 0x4C, &clkSel);
    if (nTx < gNStreams) gNStreams = nTx;
    unsigned rateIdx = (clkSel >> 8) & 0xFF;
    gRate = rateIdx < 7 ? rateTable[rateIdx] : 0;

    for (unsigned i = 0; i < gNStreams; i++) {
        Stream *s = &gS[i];
        UInt32 sb = gTxOff + 8 + i * gTxBlock, iso = 0, pcm = 0, midi = 0;
        rq(sb, &iso); rq(sb + 4, &pcm); rq(sb + 8, &midi);
        s->idx = i; s->isoReg = sb; s->speedReg = sb + 0xC;
        s->pcm = pcm; s->midi = midi; s->dbs = pcm + (midi ? 1 : 0);
        if (iso != 0xFFFFFFFFu) { fprintf(stderr, "Stream %u is already configured; not touching the card.\n", i); return 3; }
    }
    if (enable != 0) { fprintf(stderr, "Card is already streaming; not touching it.\n"); return 3; }
    printf("GS-R24 found, %u streams, rate %u Hz, locked=%s.\n", gNStreams, gRate, (status & 1) ? "yes" : "no");
    for (unsigned i = 0; i < gNStreams; i++)
        printf("  stream %u: %u PCM, %u MIDI, DBS %u (card channels %u to %u)\n", i, gS[i].pcm, gS[i].midi, gS[i].dbs, i * 16 + 1, i * 16 + gS[i].pcm);
    printf("Ring: %u packets (%.0f ms)%s.\n", gRing, gRing * 0.125, qos ? ", high-priority thread" : "");
    printf("Plan: capture both streams for %.0f s%s. Nothing is written to a file%s.\n", seconds,
           reqRate && reqRate != gRate ? " after switching the clock rate (restored afterwards)" : "",
           prefix ? " except the WAV files you asked for" : "");
    if (!go) { printf("Dry run. Add --go to do it.\n"); return 0; }

    if (reqRate && reqRate != gRate) {
        unsigned code = 99;
        for (unsigned i = 0; i < 7; i++) if (rateTable[i] == reqRate) code = i;
        UInt32 caps = 0; rq(gGlobalOff + 0x64, &caps);
        if (code == 99 || !(caps & (1u << code))) { fprintf(stderr, "The card does not offer %u Hz.\n", reqRate); return 3; }
        gClockSelReg = gGlobalOff + 0x4C; gOrigClock = clkSel; gTouched = 1; gClockChanged = 1;
        if ((r = wq(gClockSelReg, (clkSel & ~0xFF00u) | (code << 8)))) return die("write CLOCK_SELECT", r);
        if (!waitLock(code, 3000)) { fprintf(stderr, "The card did not lock at %u Hz.\n", reqRate); restoreCard(); return 3; }
        gRate = reqRate;
        for (unsigned i = 0; i < gNStreams; i++) {
            UInt32 pcm = 0, midi = 0; rq(gS[i].isoReg + 4, &pcm); rq(gS[i].isoReg + 8, &midi);
            gS[i].pcm = pcm; gS[i].midi = midi; gS[i].dbs = pcm + (midi ? 1 : 0);
        }
        printf("Locked at %u Hz.\n", gRate);
    }
    unsigned syt = gRate <= 48000 ? 8 : gRate <= 96000 ? 16 : 32;

    (*gDev)->AddCallbackDispatcherToRunLoop(gDev, CFRunLoopGetMain());
    (*gDev)->AddIsochCallbackDispatcherToRunLoop(gDev, CFRunLoopGetMain());

    for (unsigned si = 0; si < gNStreams; si++) {
        Stream *s = &gS[si];
        if (s->pcm == 0 || s->pcm > 64) { fprintf(stderr, "Unexpected stream layout.\n"); restoreCard(); return 3; }
        UInt32 maxPayload = syt * s->dbs * 4 + 8;
        s->pool = (*gDev)->CreateNuDCLPool(gDev, gRing * 4, CFUUIDGetUUIDBytes(kIOFireWireNuDCLPoolInterfaceID));
        if (!s->pool) return die("CreateNuDCLPool", si);
        s->buf = calloc(gRing, BUF_STRIDE);
        for (unsigned i = 0; i < gRing; i++) {
            IOVirtualRange rg = {(IOVirtualAddress)(s->buf + (size_t)i * BUF_STRIDE), BUF_STRIDE};
            s->dcls[i] = (NuDCLRef)(*s->pool)->AllocateReceivePacket(s->pool, NULL, HDR_BYTES, 1, &rg);
            if (!s->dcls[i]) return die("AllocateReceivePacket", i);
            (*s->pool)->SetDCLRefcon(s->dcls[i], (void *)(uintptr_t)(si << 16 | i));
            (*s->pool)->SetDCLCallback(s->dcls[i], onPacket);
        }
        for (unsigned i = 0; i < gRing; i++) (*s->pool)->SetDCLBranch(s->dcls[i], s->dcls[(i + 1) % gRing]);
        s->local = (*gDev)->CreateLocalIsochPort(gDev, false, (*s->pool)->GetProgram(s->pool), 0, 0, 0, NULL, 0, NULL, 0,
                                                 CFUUIDGetUUIDBytes(kIOFireWireLocalIsochPortInterfaceID));
        if (!s->local) return die("CreateLocalIsochPort", si);
        s->remote = (*gDev)->CreateRemoteIsochPort(gDev, true, CFUUIDGetUUIDBytes(kIOFireWireRemoteIsochPortInterfaceID));
        if (!s->remote) return die("CreateRemoteIsochPort", si);
        (*s->remote)->SetGetSupportedHandler(s->remote, rpGetSupported);
        (*s->remote)->SetAllocatePortHandler(s->remote, rpAllocate);
        (*s->remote)->SetReleasePortHandler(s->remote, rpRelease);
        (*s->remote)->SetStartHandler(s->remote, rpStart);
        (*s->remote)->SetStopHandler(s->remote, rpStop);
        s->chan = (*gDev)->CreateIsochChannel(gDev, true, maxPayload, kFWSpeed400MBit,
                                              CFUUIDGetUUIDBytes(kIOFireWireIsochChannelInterfaceID));
        if (!s->chan) return die("CreateIsochChannel", si);
        (*s->chan)->SetTalker(s->chan, (IOFireWireLibIsochPortRef)s->remote);
        (*s->chan)->AddListener(s->chan, (IOFireWireLibIsochPortRef)s->local);
        if (prefix) {
            char name[256]; snprintf(name, sizeof name, "%s_s%u.wav", prefix, si);
            s->wav = fopen(name, "wb");
            if (s->wav) { uint8_t z[44] = {0}; fwrite(z, 1, 44, s->wav); }
        }
    }

    // Allocate every channel first so all streams are configured before ENABLE is written.
    for (unsigned si = 0; si < gNStreams; si++)
        if ((r = (*gS[si].chan)->AllocateChannel(gS[si].chan))) { for (unsigned j = 0; j < si; j++) (*gS[j].chan)->ReleaseChannel(gS[j].chan); restoreCard(); return die("AllocateChannel", r); }
    printf("Starting...\n");
    for (unsigned si = 0; si < gNStreams; si++)
        if ((r = (*gS[si].chan)->Start(gS[si].chan))) { for (unsigned j = 0; j < gNStreams; j++) (*gS[j].chan)->ReleaseChannel(gS[j].chan); restoreCard(); return die("Start", r); }

    // Run, with a progress line every 30 s and a lock check.
    int lockLost = 0, slips = 0; UInt32 lastExt = 0;
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    double nextReport = 30;
    while (!gStop) {
        double el = CFAbsoluteTimeGetCurrent() - start;
        if (el >= seconds) break;
        double step = fmin(nextReport, seconds) - el; if (step < 0.5) step = 0.5;
        // With --nopoll the register reads that check the lock are skipped: a synchronous read blocks the
        // thread that processes the packets.
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, nopoll ? step : fmin(step, 5.0), false);
        UInt32 st = 0, ext = 0;
        if (!nopoll) {
            if (rq(gGlobalOff + 0x54, &st) == kIOReturnSuccess && !(st & 1)) lockLost++;
            if (rq(gGlobalOff + 0x58, &ext) == kIOReturnSuccess && (ext >> 16) != 0 && ext != lastExt) { slips++; lastExt = ext; }
        }
        el = CFAbsoluteTimeGetCurrent() - start;
        if (el >= nextReport) {
            printf("  %4.0f s: stream0 pk %" PRIu64 " dbc %" PRIu64 " cip %" PRIu64 " | stream1 pk %" PRIu64 " dbc %" PRIu64 " cip %" PRIu64 " | lock lost %d slips %d\n",
                   el, gS[0].packets, gS[0].dbcJumps, gS[0].badCip, gS[gNStreams - 1].packets, gS[gNStreams - 1].dbcJumps, gS[gNStreams - 1].badCip, lockLost, slips);
            fflush(stdout);
            nextReport += 30;
        }
    }
    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - start;

    printf("Stopping...\n");
    for (unsigned si = 0; si < gNStreams; si++) (*gS[si].chan)->Stop(gS[si].chan);
    restoreCard();
    for (unsigned si = 0; si < gNStreams; si++) (*gS[si].chan)->ReleaseChannel(gS[si].chan);
    UInt32 en = 99; rq(gEnableReg, &en);

    printf("\nResult after %.1f s (rate %u Hz)%s\n", elapsed, gRate, gStop ? " [stopped early]" : "");
    int bad = 0;
    for (unsigned si = 0; si < gNStreams; si++) {
        Stream *s = &gS[si];
        printf("  stream %u: packets %" PRIu64 " (data %" PRIu64 ", empty %" PRIu64 ", short %" PRIu64 "), CIP errors %" PRIu64
               ", DBS mismatches %" PRIu64 ", DBC discontinuities %" PRIu64 ", frames %" PRIu64 " (start-up events in the first 0.25 s, not counted: %" PRIu64 ")\n",
               si, s->packets, s->data, s->empty, s->shortPk, s->badCip, s->badDbs, s->dbcJumps, s->frames, s->startupEvents);
        bad += (int)(s->shortPk + s->badCip + s->badDbs + s->dbcJumps);
        printf("    longest gap between two packet callbacks: %.1f ms\n", s->maxGap * 1000);
        for (unsigned e = 0; e < s->nGaps; e++)
            printf("    callback gap over 8 ms: %.1f ms at %.3f s\n", s->gaps[e].gap * 1000, s->gaps[e].t);
        for (unsigned e = 0; e < s->nEv; e++)
            printf("    DBC jump %u at %.3f s, packet %" PRIu64 ": expected %u, got %u\n", e, s->ev[e].t, s->ev[e].pk, s->ev[e].expect, s->ev[e].got);
        double span = gT1 - gT0;
        if (si == 0 && span > 1)
            printf("    clock: %.0f frames in %.3f s of Mac time = %.2f Hz effective (%+.1f ppm against %u Hz)\n",
                   (double)s->frames, span, s->frames / span, (s->frames / span / gRate - 1) * 1e6, gRate);
        for (uint32_t c = 0; c < s->pcm; c++) {
            if (s->nSec < 3) break;
            double lo = 1e9, hi = 0, worstClick = 0, tot = 0;
            for (uint32_t k = 1; k < s->nSec; k++) {   // skip second 0 (partial)
                double v = s->secRms[c][k]; tot += v;
                if (v < lo) lo = v; if (v > hi) hi = v;
                if (s->secClick[c][k] > worstClick) worstClick = s->secClick[c][k];
            }
            double mean = tot / (s->nSec - 1);
            if (db(mean) > -50) {
                double swing = db(hi) - db(lo);
                printf("    card ch%2u carries a signal: rms %.1f dBFS, per-second rms from %.1f to %.1f dBFS (swing %.2f dB), worst click ratio %.2f\n",
                       si * 16 + c + 1, db(mean), db(lo), db(hi), swing, worstClick);
                if (swing > 1.0 || worstClick > 1.5) bad++;
            }
        }
        if (s->wav) {
            uint8_t h[44]; uint32_t data = (uint32_t)(s->frames * s->pcm * 4);
            memcpy(h, "RIFF", 4); uint32_t v = 36 + data; memcpy(h + 4, &v, 4); memcpy(h + 8, "WAVEfmt ", 8);
            v = 16; memcpy(h + 16, &v, 4); uint16_t w = 1; memcpy(h + 20, &w, 2); w = s->pcm; memcpy(h + 22, &w, 2);
            v = gRate; memcpy(h + 24, &v, 4); v = gRate * s->pcm * 4; memcpy(h + 28, &v, 4); w = s->pcm * 4; memcpy(h + 32, &w, 2);
            w = 32; memcpy(h + 34, &w, 2); memcpy(h + 36, "data", 4); memcpy(h + 40, &data, 4);
            fseek(s->wav, 0, SEEK_SET); fwrite(h, 1, 44, s->wav); fclose(s->wav);
        }
    }
    printf("  lock lost %d times, slip events %d, register retries %d, ENABLE after stop %u\n", lockLost, slips, gRetries, en);
    printf("  VERDICT: %s\n", (bad == 0 && lockLost == 0) ? "clean" : "problems found, see above");
    (*gDev)->Close(gDev);
    return 0;
}
