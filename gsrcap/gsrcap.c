// SPDX-License-Identifier: Apache-2.0
//
// gsrcap: milestone M2, capture only. Receives stream 0 of an Allen & Heath GS-R24 for a few seconds,
// checks the packets and writes the audio to a WAV file. Nothing is played to the card.
//
// It writes only volatile run-time registers of the card, as the vendor driver does:
//   TX stream 0 ISOCHRONOUS and SPEED, then GLOBAL ENABLE.
// It never touches firmware. On exit (normal, error or Ctrl-C) it clears ENABLE and ISOCHRONOUS.
//
// Build: clang -O1 -Wall -o gsrcap gsrcap.c -framework IOKit -framework CoreFoundation
// Usage: ./gsrcap            prints the plan only
//        ./gsrcap --go [-t seconds] [-o file.wav]

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
#include <strings.h>

#define BASE_HI 0xFFFF
#define BASE_LO 0xE0000000u

#define RING_PACKETS 160      // about 20 ms at 8000 packets per second, as the vendor driver
#define HDR_BYTES 4           // isochronous header received in front of the payload
#define BUF_STRIDE 2048       // payload room per packet (96 kHz, DBS 17: 1096 bytes)

static IOFireWireLibDeviceRef gDev;
static io_object_t gSvc;
static UInt32 gGen;

// ---- register access -------------------------------------------------------------------------

// Block reads and writes of 4 bytes, big-endian on the wire (same path as dicedump, which is proven
// on this card; ReadQuadlet returned the bytes in a different order).
// Reads and writes of single registers are idempotent, so a transient failure (for example a bus
// reset right after a rate change) is retried with a fresh bus generation.
static int gRetries;      // number of retries used, reported at the end
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

// ---- device layout and state we must restore ----------------------------------------------------

static UInt32 gGlobalOff, gTxOff, gTxBlock;      // bytes from the DICE base
static UInt32 gEnableReg, gIsoReg, gSpeedReg;     // offsets
static int gTouched;                              // we changed registers and must undo them
static UInt32 gClockSelReg, gOrigClock;           // CLOCK_SELECT and its value before we changed the rate
static int gClockChanged;

// Waits until STATUS says locked at the given rate code (bits 8-15 of STATUS are the nominal rate).
static int waitLock(UInt32 rateCode, int ms) {
    for (int t = 0; t < ms; t += 20) {
        UInt32 st;
        if (rq(gGlobalOff + 0x54, &st) == kIOReturnSuccess && (st & 1) && ((st >> 8) & 0xFF) == rateCode) return 1;
        usleep(20000);
    }
    return 0;
}

static void restoreCard(void) {
    if (!gDev || !gTouched) return;
    if (gIsoReg) { wq(gEnableReg, 0); wq(gIsoReg, 0xFFFFFFFFu); }
    if (gClockChanged) {
        wq(gClockSelReg, gOrigClock);
        printf("  rate restored: %s\n", waitLock((gOrigClock >> 8) & 0xFF, 3000) ? "locked" : "NOT LOCKED, check the card");
        gClockChanged = 0;
    }
    gTouched = 0;
}

static volatile sig_atomic_t gStop;
static void onSignal(int s) { (void)s; gStop = 1; CFRunLoopStop(CFRunLoopGetMain()); }

// ---- capture state --------------------------------------------------------------------------------

static uint8_t *gBuf;                 // RING_PACKETS * BUF_STRIDE
static uint32_t gPcm, gDbs;
static int gMidiSlot;
static unsigned gRate;
static FILE *gWav;
static uint64_t gFrames;
static float gPeak[64];

static struct {
    uint64_t packets, dataPackets, emptyPackets, badCip, badDbs, dbcJumps, noSyt, shortPackets;
    uint32_t lastDbc; int haveDbc;
    uint32_t firstHdr[4]; int nHdr;
} st;

static const unsigned rateTable[] = {32000, 44100, 48000, 88200, 96000, 176400, 192000};

static void onPacket(void *refcon, NuDCLRef dcl) {
    (void)dcl;
    unsigned idx = (unsigned)(uintptr_t)refcon;
    const uint8_t *p = gBuf + (size_t)idx * BUF_STRIDE;
    uint32_t hdr = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
    if (st.nHdr < 4) st.firstHdr[st.nHdr++] = hdr;
    st.packets++;

    // The isochronous header is stored as a little-endian quadlet: byte 0 = tcode(4) sy(4),
    // byte 1 = tag(2) channel(6), bytes 2 and 3 = data length. Payload bytes are in wire order.
    uint32_t len = (uint32_t)p[2] | (uint32_t)p[3] << 8;
    const uint8_t *q = p + HDR_BYTES;
    if (len < 8 || len > BUF_STRIDE - HDR_BYTES) { st.shortPackets++; return; }

    // CIP header: Q0 = 00 SID(6) DBS(8) FN QPC SPH 00 DBC(8); Q1 = 10 FMT(6) FDF(8) SYT(16)
    if ((q[0] & 0xC0) != 0x00 || (q[4] & 0xC0) != 0x80 || (q[4] & 0x3F) != 0x10) { st.badCip++; return; }
    uint32_t dbs = q[1], dbc = q[3], fdf = q[5];
    uint32_t syt = (uint32_t)q[6] << 8 | q[7];
    if (syt == 0xFFFF) st.noSyt++;
    if (len == 8) { st.emptyPackets++; return; }
    if (dbs != gDbs) { st.badDbs++; return; }
    uint32_t blocks = (len - 8) / (dbs * 4);
    if (st.haveDbc && ((st.lastDbc & 0xFF) != dbc)) st.dbcJumps++;
    st.lastDbc = dbc + blocks;
    st.haveDbc = 1;
    st.dataPackets++;
    if (fdf < 7 && rateTable[fdf] != gRate) st.badCip++;

    // Samples: label byte then 24 bits, big endian.
    const uint8_t *s = q + 8;
    for (uint32_t b = 0; b < blocks; b++, s += dbs * 4) {
        for (uint32_t c = 0; c < gPcm; c++) {
            int32_t v = (int32_t)((uint32_t)s[c * 4 + 1] << 24 | (uint32_t)s[c * 4 + 2] << 16 | (uint32_t)s[c * 4 + 3] << 8);
            if (gWav) fwrite(&v, 4, 1, gWav);
            float a = fabsf((float)v / 2147483648.0f);
            if (a > gPeak[c]) gPeak[c] = a;
        }
        gFrames++;
    }
}

// ---- remote port: the card as talker -------------------------------------------------------------------

static IOReturn rpGetSupported(IOFireWireLibIsochPortRef self, IOFWSpeed *maxSpeed, UInt64 *chans) {
    (void)self; *maxSpeed = kFWSpeed400MBit; *chans = 0xFFFFFFFFFFFFFFFFULL; return kIOReturnSuccess;
}
static IOReturn rpAllocate(IOFireWireLibIsochPortRef self, IOFWSpeed speed, UInt32 chan) {
    (void)self;
    printf("  channel %u allocated, speed code %u\n", chan, (unsigned)speed);
    gTouched = 1;
    IOReturn r = wq(gIsoReg, chan);
    if (r == kIOReturnSuccess) r = wq(gSpeedReg, (UInt32)speed);
    return r;
}
static IOReturn rpRelease(IOFireWireLibIsochPortRef self) { (void)self; wq(gIsoReg, 0xFFFFFFFFu); return kIOReturnSuccess; }
static IOReturn rpStart(IOFireWireLibIsochPortRef self) {
    (void)self;
    usleep(2000);                       // vendor driver waits 2 ms between configuring and enabling
    gTouched = 1;
    return wq(gEnableReg, 1);
}
static IOReturn rpStop(IOFireWireLibIsochPortRef self) { (void)self; return wq(gEnableReg, 0); }

// ---- WAV --------------------------------------------------------------------------------------------------

static void le32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static void le16(uint8_t *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }
static void wavHeader(FILE *f, uint16_t ch, uint32_t rate, uint64_t frames) {
    uint8_t h[44];
    uint32_t data = (uint32_t)(frames * ch * 4);
    memcpy(h, "RIFF", 4); le32(h + 4, 36 + data); memcpy(h + 8, "WAVEfmt ", 8);
    le32(h + 16, 16); le16(h + 20, 1); le16(h + 22, ch); le32(h + 24, rate);
    le32(h + 28, rate * ch * 4); le16(h + 32, ch * 4); le16(h + 34, 32);
    memcpy(h + 36, "data", 4); le32(h + 40, data);
    fseek(f, 0, SEEK_SET); fwrite(h, 1, 44, f);
}

// ---- main ------------------------------------------------------------------------------------------------------

static int die(const char *what, IOReturn r) {
    fprintf(stderr, "FAILED: %s (IOReturn 0x%08x)\n", what, (unsigned)r);
    restoreCard();
    return 1;
}

int main(int argc, char **argv) {
    int go = 0; double seconds = 5; const char *outPath = "capture.wav"; unsigned sidx = 0, reqRate = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--go")) go = 1;
        else if (!strcmp(argv[i], "-t") && i + 1 < argc) seconds = atof(argv[++i]);
        else if (!strcmp(argv[i], "-o") && i + 1 < argc) outPath = argv[++i];
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) sidx = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "-r") && i + 1 < argc) reqRate = (unsigned)atoi(argv[++i]);
    }

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

    // Layout: section table at the base: global, tx, rx ... as offset/size pairs in quadlets.
    UInt32 t[6];
    for (int i = 0; i < 6; i++) if ((r = rq(i * 4, &t[i]))) return die("read section table", r);
    gGlobalOff = t[0] * 4; gTxOff = t[2] * 4;
    UInt32 nTx, blkQ, enable, status, clkSel, owner0, owner1;
    if ((r = rq(gTxOff, &nTx)) || (r = rq(gTxOff + 4, &blkQ))) return die("read TX header", r);
    gTxBlock = blkQ * 4;
    if (sidx >= nTx) { fprintf(stderr, "Stream %u does not exist (card has %u).\n", sidx, nTx); return 3; }
    UInt32 sb = gTxOff + 8 + sidx * gTxBlock;          // start of this stream's block
    gEnableReg = gGlobalOff + 0x50; gIsoReg = sb; gSpeedReg = sb + 0xC;
    rq(gEnableReg, &enable); rq(gGlobalOff + 0x54, &status); rq(gGlobalOff + 0x4C, &clkSel);
    rq(gGlobalOff, &owner0); rq(gGlobalOff + 4, &owner1);
    UInt32 pcm = 0, midi = 0, iso = 0;
    rq(sb + 0, &iso); rq(sb + 4, &pcm); rq(sb + 8, &midi);
    gPcm = pcm; gMidiSlot = midi != 0; gDbs = pcm + (midi ? 1 : 0);
    unsigned rateIdx = (clkSel >> 8) & 0xFF;
    gRate = rateIdx < 7 ? rateTable[rateIdx] : 0;
    unsigned syt = gRate <= 48000 ? 8 : gRate <= 96000 ? 16 : 32;
    UInt32 maxPayload = syt * gDbs * 4 + 8;

    printf("GS-R24 found. TX streams: %u, block %u bytes. Stream %u: %u PCM, %u MIDI, DBS %u (channels %u to %u).\n", nTx, gTxBlock, sidx, pcm, midi, gDbs, sidx * 16 + 1, sidx * 16 + pcm);
    printf("Rate %u Hz (SYT interval %u), locked=%s, ENABLE=%u, OWNER=0x%08x%08x, stream %u ISOCHRONOUS=%d\n",
           gRate, syt, (status & 1) ? "yes" : "no", enable, owner0, owner1, sidx, (int)iso);
    printf("Plan: allocate an isochronous channel (%u byte packets, S400), write stream %u ISOCHRONOUS and SPEED,\n"
           "      wait 2 ms, write ENABLE=1, receive for %.1f s, then ENABLE=0 and ISOCHRONOUS=-1.\n", maxPayload, sidx, seconds);
    if (reqRate && reqRate != gRate)
        printf("Rate change: %u Hz -> %u Hz (CLOCK_SELECT, put back to %u Hz afterwards).\n", gRate, reqRate, gRate);
    if (!go) { printf("Dry run. Add --go to do it.\n"); return 0; }
    if (enable != 0 || iso != 0xFFFFFFFFu) { fprintf(stderr, "Card is already streaming or configured; not touching it.\n"); return 3; }
    if (!gRate || gPcm == 0 || gPcm > 64) { fprintf(stderr, "Unexpected stream layout.\n"); return 3; }

    if (reqRate && reqRate != gRate) {
        unsigned code = 99;
        for (unsigned i = 0; i < 7; i++) if (rateTable[i] == reqRate) code = i;
        UInt32 caps = 0;
        rq(gGlobalOff + 0x64, &caps);
        if (code == 99 || !(caps & (1u << code))) { fprintf(stderr, "The card does not offer %u Hz.\n", reqRate); return 3; }
        gClockSelReg = gGlobalOff + 0x4C; gOrigClock = clkSel;
        gTouched = 1; gClockChanged = 1;
        if ((r = wq(gClockSelReg, (clkSel & ~0xFF00u) | (code << 8)))) return die("write CLOCK_SELECT", r);
        if (!waitLock(code, 3000)) { fprintf(stderr, "The card did not lock at %u Hz.\n", reqRate); restoreCard(); return 3; }
        UInt32 n2 = 0, p2 = 0, m2 = 0;
        rq(gTxOff, &n2); rq(sb + 4, &p2); rq(sb + 8, &m2);
        gRate = reqRate; gPcm = p2; gMidiSlot = m2 != 0; gDbs = p2 + (m2 ? 1 : 0);
        syt = gRate <= 48000 ? 8 : gRate <= 96000 ? 16 : 32;
        maxPayload = syt * gDbs * 4 + 8;
        printf("Locked at %u Hz. TX streams: %u. Stream %u now: %u PCM, %u MIDI, DBS %u, %u byte packets.\n",
               gRate, n2, sidx, p2, m2, gDbs, maxPayload);
        if (gPcm == 0 || gPcm > 64 || gDbs == 0) { fprintf(stderr, "Unexpected stream layout at this rate.\n"); restoreCard(); return 3; }
    }

    (*gDev)->AddCallbackDispatcherToRunLoop(gDev, CFRunLoopGetMain());
    (*gDev)->AddIsochCallbackDispatcherToRunLoop(gDev, CFRunLoopGetMain());

    // DCL ring of receive packets
    IOFireWireLibNuDCLPoolRef pool = (*gDev)->CreateNuDCLPool(gDev, RING_PACKETS * 4, CFUUIDGetUUIDBytes(kIOFireWireNuDCLPoolInterfaceID));
    if (!pool) return die("CreateNuDCLPool", 0);
    gBuf = calloc(RING_PACKETS, BUF_STRIDE);
    NuDCLRef dcls[RING_PACKETS];
    for (unsigned i = 0; i < RING_PACKETS; i++) {
        IOVirtualRange rg = {(IOVirtualAddress)(gBuf + (size_t)i * BUF_STRIDE), BUF_STRIDE};
        dcls[i] = (NuDCLRef)(*pool)->AllocateReceivePacket(pool, NULL, HDR_BYTES, 1, &rg);
        if (!dcls[i]) return die("AllocateReceivePacket", i);
        (*pool)->SetDCLRefcon(dcls[i], (void *)(uintptr_t)i);
        (*pool)->SetDCLCallback(dcls[i], onPacket);
    }
    for (unsigned i = 0; i < RING_PACKETS; i++) (*pool)->SetDCLBranch(dcls[i], dcls[(i + 1) % RING_PACKETS]);

    IOFireWireLibLocalIsochPortRef local = (*gDev)->CreateLocalIsochPort(
        gDev, false, (*pool)->GetProgram(pool), 0, 0, 0, NULL, 0, NULL, 0,
        CFUUIDGetUUIDBytes(kIOFireWireLocalIsochPortInterfaceID));
    if (!local) return die("CreateLocalIsochPort", 0);

    IOFireWireLibRemoteIsochPortRef remote = (*gDev)->CreateRemoteIsochPort(
        gDev, true, CFUUIDGetUUIDBytes(kIOFireWireRemoteIsochPortInterfaceID));
    if (!remote) return die("CreateRemoteIsochPort", 0);
    (*remote)->SetGetSupportedHandler(remote, rpGetSupported);
    (*remote)->SetAllocatePortHandler(remote, rpAllocate);
    (*remote)->SetReleasePortHandler(remote, rpRelease);
    (*remote)->SetStartHandler(remote, rpStart);
    (*remote)->SetStopHandler(remote, rpStop);

    IOFireWireLibIsochChannelRef chan = (*gDev)->CreateIsochChannel(
        gDev, true, maxPayload, kFWSpeed400MBit, CFUUIDGetUUIDBytes(kIOFireWireIsochChannelInterfaceID));
    if (!chan) return die("CreateIsochChannel", 0);
    (*chan)->SetTalker(chan, (IOFireWireLibIsochPortRef)remote);
    (*chan)->AddListener(chan, (IOFireWireLibIsochPortRef)local);

    gWav = fopen(outPath, "wb");
    if (gWav) { uint8_t z[44] = {0}; fwrite(z, 1, 44, gWav); }

    printf("Allocating channel...\n");
    if ((r = (*chan)->AllocateChannel(chan))) { restoreCard(); return die("AllocateChannel", r); }
    printf("Starting...\n");
    if ((r = (*chan)->Start(chan))) { (*chan)->ReleaseChannel(chan); restoreCard(); return die("Start", r); }

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);

    printf("Stopping...\n");
    (*chan)->Stop(chan);
    restoreCard();
    (*chan)->ReleaseChannel(chan);

    UInt32 en = 99, st2 = 0;
    rq(gEnableReg, &en); rq(gGlobalOff + 0x58, &st2);
    printf("\nResult after %.1f s\n", seconds);
    printf("  packets %" PRIu64 " (data %" PRIu64 ", empty %" PRIu64 ", short %" PRIu64 ")\n", st.packets, st.dataPackets, st.emptyPackets, st.shortPackets);
    printf("  CIP errors %" PRIu64 ", DBS mismatches %" PRIu64 ", DBC discontinuities %" PRIu64 ", SYT 0xFFFF %" PRIu64 "\n", st.badCip, st.badDbs, st.dbcJumps, st.noSyt);
    printf("  frames captured %" PRIu64 " (expected about %.0f)\n", gFrames, seconds * gRate);
    for (int i = 0; i < st.nHdr; i++) printf("  first isoch header %d: 0x%08x\n", i, st.firstHdr[i]);
    printf("  peak per channel (dBFS):");
    for (uint32_t c = 0; c < gPcm; c++) printf(" %s%.0f", c % 8 == 0 ? "\n    " : " ", gPeak[c] > 0 ? 20 * log10f(gPeak[c]) : -200.0f);
    printf("\n  (channels %u to %u of the card)", sidx * 16 + 1, sidx * 16 + gPcm);
    printf("\n  ENABLE after stop: %u, register retries %d\n", en, gRetries);
    if (gWav) { wavHeader(gWav, (uint16_t)gPcm, gRate, gFrames); fclose(gWav); printf("  wrote %s\n", outPath); }
    (*gDev)->Close(gDev);
    return 0;
}
