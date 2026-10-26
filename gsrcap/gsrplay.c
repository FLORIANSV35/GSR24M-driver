// SPDX-License-Identifier: Apache-2.0
//
// gsrplay: milestone M3 test, playback to the card. Sends a short sine tone to one output channel of
// an Allen & Heath GS-R24 (the card's RX stream 0, card inputs 1 to 16) and stays silent on the others.
//
// Packets follow the blocking AM824 cadence the vendor driver uses: three data packets of one SYT
// interval of frames in every four bus cycles, the fourth packet empty (8 bytes, SYT 0xFFFF). Data packets
// carry a presentation time of send time + 0x2E00 ticks, advancing by 4096 ticks per data packet.
//
// It writes only volatile run-time registers (RX stream ISOCHRONOUS and SEQ_START, then GLOBAL ENABLE) and
// puts them back on exit, also on Ctrl-C. It never touches firmware. Level is limited to -20 dBFS.
//
// Build: clang -O1 -Wall -o gsrplay gsrplay.c -framework IOKit -framework CoreFoundation -lm
// Usage: ./gsrplay                       plan only
//        ./gsrplay --go [-c channel] [-l dBFS] [-t seconds] [-f Hz] [-s rxStream]

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
    if (t) { if (CFGetTypeID(t) == CFNumberGetTypeID()) CFNumberGetValue(t, kCFNumberSInt64Type, &v); CFRelease(t); }
    return v;
}

static const unsigned rateTable[] = {32000, 44100, 48000, 88200, 96000, 176400, 192000};

// ---- state ---------------------------------------------------------------------------------------------

static UInt32 gGlobalOff, gRxOff, gRxBlock, gEnableReg, gIsoReg, gSeqReg;
static int gTouched;
static volatile sig_atomic_t gStop;
static unsigned gRate, gPcm, gMidi, gDbs, gBlocks, gSid;
static uint8_t *gBuf;
static uint32_t gSlotLen[RING];
static NuDCLRef gDcl[RING];

// generator
static uint64_t gSeq;            // packet sequence number
static uint64_t gDataIdx;        // data packet index
static uint32_t gDbc;            // data block counter
static uint64_t gFrame;          // frame counter for the tone
static uint64_t gU0;             // presentation time of data packet 0, in ticks
static double gAmp, gFreq, gSecs;
static unsigned gToneCh;
static uint64_t gSent, gRefilled;
static CFAbsoluteTime gLastCb, gMaxGap;
static unsigned gLateGaps;

static void restoreCard(void) {
    if (!gDev || !gTouched) return;
    wq(gEnableReg, 0);
    if (gIsoReg) wq(gIsoReg, 0xFFFFFFFFu);
    gTouched = 0;
}
static void onSignal(int s) { (void)s; gStop = 1; CFRunLoopStop(CFRunLoopGetMain()); }

static void put32(uint8_t *p, uint32_t q) { p[0] = q >> 24; p[1] = q >> 16; p[2] = q >> 8; p[3] = q; }

// Builds packet number `seq` into its ring slot.
static void buildPacket(uint64_t seq) {
    unsigned slot = (unsigned)(seq % RING);
    uint8_t *p = gBuf + (size_t)slot * MAX_PKT;
    int empty = (seq % 4) == 3;
    uint32_t len = gSlotLen[slot];
    p[0] = gSid & 0x3F; p[1] = (uint8_t)gDbs; p[2] = 0; p[3] = (uint8_t)gDbc;
    p[4] = 0x90; p[5] = (uint8_t)(gRate == 48000 ? 2 : gRate == 96000 ? 4 : 2);
    if (empty) { p[6] = 0xFF; p[7] = 0xFF; return; }
    uint64_t pt = gU0 + gDataIdx * 4096ull;                         // presentation time in ticks
    uint32_t cyc = (uint32_t)((pt / 3072) & 0xF), off = (uint32_t)(pt % 3072);
    uint32_t syt = cyc << 12 | off;
    p[6] = syt >> 8; p[7] = syt;
    uint8_t *q = p + 8;
    double fadeFrames = gRate * 0.1, total = gSecs * gRate;
    for (unsigned b = 0; b < gBlocks; b++, gFrame++) {
        double t = (double)gFrame, env = 1.0;
        if (t < fadeFrames) env = t / fadeFrames;
        if (t > total - fadeFrames) env = fmax(0.0, (total - t) / fadeFrames);
        if (t > total) env = 0;
        double v = gAmp * env * sin(2 * M_PI * gFreq * t / gRate);
        int32_t s = (int32_t)lrint(v * 8388607.0);                    // 24-bit
        for (unsigned c = 0; c < gPcm; c++, q += 4) {
            int32_t x = (c == gToneCh) ? s : 0;
            put32(q, 0x40000000u | ((uint32_t)x & 0x00FFFFFFu));
        }
        if (gMidi) { put32(q, 0x80000000u); q += 4; }
    }
    (void)len;
    gDbc = (gDbc + gBlocks) & 0xFF;
    gDataIdx++;
}

static void onSent(void *refcon, NuDCLRef dcl) {
    (void)dcl; (void)refcon;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gLastCb > 0) {
        double gap = now - gLastCb;
        if (gap > gMaxGap) gMaxGap = gap;
        if (gap > 0.040) gLateGaps++;       // half of the ring: refilling is getting close to the limit
    }
    gLastCb = now;
    gSent++;
    // The packet that just went out frees its slot: put the next packet of the sequence there.
    buildPacket(gSeq++);
    gRefilled++;
}

// ---- remote port: the card as listener ---------------------------------------------------------------------

static IOReturn rpGetSupported(IOFireWireLibIsochPortRef self, IOFWSpeed *sp, UInt64 *ch) {
    (void)self; *sp = kFWSpeed400MBit; *ch = 0xFFFFFFFFFFFFFFFFULL; return kIOReturnSuccess;
}
static IOReturn rpAllocate(IOFireWireLibIsochPortRef self, IOFWSpeed speed, UInt32 chan) {
    (void)self; (void)speed;
    printf("  channel %u allocated\n", chan);
    gTouched = 1;
    IOReturn r = wq(gIsoReg, chan);
    if (r == kIOReturnSuccess) r = wq(gSeqReg, 0);
    return r;
}
static IOReturn rpRelease(IOFireWireLibIsochPortRef self) { (void)self; wq(gIsoReg, 0xFFFFFFFFu); return kIOReturnSuccess; }
static IOReturn rpStart(IOFireWireLibIsochPortRef self) { (void)self; usleep(2000); gTouched = 1; return wq(gEnableReg, 1); }
static IOReturn rpStop(IOFireWireLibIsochPortRef self) { (void)self; return wq(gEnableReg, 0); }

static int die(const char *what, IOReturn r) {
    fprintf(stderr, "FAILED: %s (IOReturn 0x%08x)\n", what, (unsigned)r);
    restoreCard();
    return 1;
}

int main(int argc, char **argv) {
    int go = 0; unsigned sidx = 0; double level = -50; gSecs = 3; gFreq = 1000; gToneCh = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--go")) go = 1;
        else if (!strcmp(argv[i], "-c") && i + 1 < argc) gToneCh = (unsigned)atoi(argv[++i]) - 1;
        else if (!strcmp(argv[i], "-l") && i + 1 < argc) level = atof(argv[++i]);
        else if (!strcmp(argv[i], "-t") && i + 1 < argc) gSecs = atof(argv[++i]);
        else if (!strcmp(argv[i], "-f") && i + 1 < argc) gFreq = atof(argv[++i]);
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) sidx = (unsigned)atoi(argv[++i]);
    }
    if (level > -20) level = -20;
    if (gSecs > 30) gSecs = 30;
    gAmp = pow(10.0, level / 20.0);

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
    gGlobalOff = t[0] * 4; gRxOff = t[4] * 4;
    UInt32 nRx, blkQ, enable, status, clkSel;
    if ((r = rq(gRxOff, &nRx)) || (r = rq(gRxOff + 4, &blkQ))) return die("read RX header", r);
    gRxBlock = blkQ * 4; gEnableReg = gGlobalOff + 0x50;
    rq(gEnableReg, &enable); rq(gGlobalOff + 0x54, &status); rq(gGlobalOff + 0x4C, &clkSel);
    if (sidx >= nRx) { fprintf(stderr, "RX stream %u does not exist (card has %u).\n", sidx, nRx); return 3; }
    UInt32 sb = gRxOff + 8 + sidx * gRxBlock, iso = 0, pcm = 0, midi = 0;
    rq(sb, &iso); rq(sb + 4, &pcm); rq(sb + 8, &midi);   // note: for RX, +4 is SEQ_START, +8 audio, +0xC midi
    rq(sb + 8, &pcm); rq(sb + 0xC, &midi);
    gIsoReg = sb; gSeqReg = sb + 4;
    gPcm = pcm; gMidi = midi; gDbs = pcm + (midi ? 1 : 0);
    unsigned rateIdx = (clkSel >> 8) & 0xFF;
    gRate = rateIdx < 7 ? rateTable[rateIdx] : 0;
    gBlocks = gRate <= 48000 ? 8 : gRate <= 96000 ? 16 : 32;

    printf("GS-R24 found. RX stream %u: %u PCM, %u MIDI, DBS %u (card inputs %u to %u).\n", sidx, gPcm, midi, gDbs, sidx * 16 + 1, sidx * 16 + gPcm);
    printf("Rate %u Hz, locked=%s, ENABLE=%u, RX ISOCHRONOUS=%d.\n", gRate, (status & 1) ? "yes" : "no", enable, (int)iso);
    printf("Plan: send a %.0f Hz tone at %.0f dBFS (%.1f s with 0.1 s fades) to card input %u, others silent.\n", gFreq, level, gSecs, sidx * 16 + gToneCh + 1);
    printf("      Packets: %u frames per data packet, 3 data packets in 4 cycles, SYT = send time + 0x2E00 ticks.\n", gBlocks);
    printf("      Registers written: RX stream %u ISOCHRONOUS and SEQ_START, then ENABLE; all put back at the end.\n", sidx);
    if (!go) { printf("Dry run. Add --go to do it. Turn the monitors down first.\n"); return 0; }
    if (enable != 0 || iso != 0xFFFFFFFFu) { fprintf(stderr, "Card is already streaming or configured; not touching it.\n"); return 3; }
    if (gRate != 48000 && gRate != 96000) { fprintf(stderr, "Only 48 and 96 kHz are supported here.\n"); return 3; }
    if (gPcm == 0 || gPcm > 32 || gToneCh >= gPcm) { fprintf(stderr, "Unexpected stream layout or channel.\n"); return 3; }

    UInt16 localNode = 0; (*gDev)->GetLocalNodeID(gDev, &localNode);
    gSid = localNode & 0x3F;

    (*gDev)->AddCallbackDispatcherToRunLoop(gDev, CFRunLoopGetMain());
    (*gDev)->AddIsochCallbackDispatcherToRunLoop(gDev, CFRunLoopGetMain());

    IOFireWireLibNuDCLPoolRef pool = (*gDev)->CreateNuDCLPool(gDev, RING * 4, CFUUIDGetUUIDBytes(kIOFireWireNuDCLPoolInterfaceID));
    if (!pool) return die("CreateNuDCLPool", 0);
    (*pool)->SetCurrentTagAndSync(pool, 1, 0);                         // tag 1 (CIP), sync 0
    gBuf = calloc(RING, MAX_PKT);
    for (unsigned i = 0; i < RING; i++) {
        int empty = (i % 4) == 3;
        gSlotLen[i] = empty ? 8 : 8 + gBlocks * gDbs * 4;
        IOVirtualRange rg = {(IOVirtualAddress)(gBuf + (size_t)i * MAX_PKT), gSlotLen[i]};
        gDcl[i] = (NuDCLRef)(*pool)->AllocateSendPacket(pool, NULL, 1, &rg);
        if (!gDcl[i]) return die("AllocateSendPacket", i);
        (*pool)->SetDCLRefcon(gDcl[i], (void *)(uintptr_t)i);
        (*pool)->SetDCLCallback(gDcl[i], onSent);
    }
    for (unsigned i = 0; i < RING; i++) (*pool)->SetDCLBranch(gDcl[i], gDcl[(i + 1) % RING]);

    // Start the DMA at a known cycle so presentation times can be computed from it.
    UInt32 ct = 0; (*gDev)->GetCycleTime(gDev, &ct);
    unsigned nowCycle = (ct >> 12) & 0x1FFF;
    unsigned startCycle = (nowCycle + 1600) % 8000;                    // 200 ms ahead
    gU0 = (uint64_t)startCycle * 3072 + 0x2E00 + 2048;
    gSeq = 0; gDataIdx = 0; gDbc = 0; gFrame = 0;
    for (unsigned i = 0; i < RING; i++) buildPacket(gSeq++);           // prefill the whole ring

    IOFireWireLibLocalIsochPortRef local = (*gDev)->CreateLocalIsochPort(
        gDev, true, (*pool)->GetProgram(pool), kFWDCLCycleEvent, startCycle, 0x1FFF, NULL, 0, NULL, 0,
        CFUUIDGetUUIDBytes(kIOFireWireLocalIsochPortInterfaceID));
    if (!local) return die("CreateLocalIsochPort", 0);
    IOFireWireLibRemoteIsochPortRef remote = (*gDev)->CreateRemoteIsochPort(
        gDev, false, CFUUIDGetUUIDBytes(kIOFireWireRemoteIsochPortInterfaceID));
    if (!remote) return die("CreateRemoteIsochPort", 0);
    (*remote)->SetGetSupportedHandler(remote, rpGetSupported);
    (*remote)->SetAllocatePortHandler(remote, rpAllocate);
    (*remote)->SetReleasePortHandler(remote, rpRelease);
    (*remote)->SetStartHandler(remote, rpStart);
    (*remote)->SetStopHandler(remote, rpStop);

    UInt32 maxPayload = 8 + gBlocks * gDbs * 4;
    IOFireWireLibIsochChannelRef chan = (*gDev)->CreateIsochChannel(
        gDev, true, maxPayload, kFWSpeed400MBit, CFUUIDGetUUIDBytes(kIOFireWireIsochChannelInterfaceID));
    if (!chan) return die("CreateIsochChannel", 0);
    (*chan)->SetTalker(chan, (IOFireWireLibIsochPortRef)local);
    (*chan)->AddListener(chan, (IOFireWireLibIsochPortRef)remote);

    printf("Allocating channel...\n");
    if ((r = (*chan)->AllocateChannel(chan))) { restoreCard(); return die("AllocateChannel", r); }
    printf("Starting (DMA starts at cycle %u, now %u)...\n", startCycle, nowCycle);
    if ((r = (*chan)->Start(chan))) { (*chan)->ReleaseChannel(chan); restoreCard(); return die("Start", r); }

    double run = gSecs + 1.5;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, run, false);

    printf("Stopping...\n");
    (*chan)->Stop(chan);
    restoreCard();
    (*chan)->ReleaseChannel(chan);

    UInt32 en = 99, ext = 0, st2 = 0;
    rq(gEnableReg, &en); rq(gGlobalOff + 0x58, &ext); rq(gGlobalOff + 0x54, &st2);
    printf("\nResult\n");
    printf("  packets sent %" PRIu64 " (expected about %.0f), refilled %" PRIu64 "\n", gSent, run * 8000, gRefilled);
    printf("  data packets built %" PRIu64 ", last block count %u\n", gDataIdx, gDbc);
    printf("  longest gap between send callbacks: %.1f ms (ring holds 80 ms), gaps over 40 ms: %u\n", gMaxGap * 1000, gLateGaps);
    printf("  card after stop: ENABLE %u, STATUS 0x%08x (locked=%s), EXTENDED_STATUS 0x%08x, register retries %d\n",
           en, st2, (st2 & 1) ? "yes" : "no", ext, gRetries);
    (*gDev)->Close(gDev);
    return 0;
}
