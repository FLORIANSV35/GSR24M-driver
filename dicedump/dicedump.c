// SPDX-License-Identifier: Apache-2.0
//
// dicedump: read-only dump of a DICE/TCAT FireWire device through Apple's
// native IOFireWireLib. Output follows the layout of the ASFW DICE device
// reports in documentation/fixtures/DICE/ so the result can be filed next to
// them. Nothing is ever written to the device.
//
// Build:  clang -O1 -Wall -o dicedump dicedump.c -framework IOKit -framework CoreFoundation
// Usage:  ./dicedump [-l] [-g GUID_HEX]
//           -l  list FireWire devices and exit
//           -g  pick the device with this GUID (default: the first Allen & Heath unit,
//               GUID OUI 0x0004C4 / Unit_Spec_ID 1220 / vendor name)

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/firewire/IOFireWireLib.h>
#include <IOKit/firewire/IOFireWireFamilyCommon.h>

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

#define DICE_BASE_HI 0xFFFF
#define DICE_BASE_LO 0xE0000000u
#define DICE_EXT_LO 0xE0200000u
#define ROM_LO 0xF0000400u

static IOFireWireLibDeviceRef gDev;
static io_object_t gSvc;
static UInt32 gGen;

static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

// Block read of `len` bytes at (hi:lo), split in 64-byte transactions.
static IOReturn rd(UInt16 hi, UInt32 lo, uint8_t *buf, UInt32 len) {
    UInt32 done = 0;
    while (done < len) {
        UInt32 n = len - done > 64 ? 64 : len - done;
        FWAddress a = {0, hi, lo + done};
        IOReturn r = kIOReturnError;
        for (int tries = 0; tries < 4; tries++) {
            UInt32 sz = n;
            UInt16 node;
            (*gDev)->GetGenerationAndNodeID(gDev, &gGen, &node);
            r = (*gDev)->Read(gDev, gSvc, &a, buf + done, &sz, true, gGen);
            if (r == kIOReturnSuccess) break;
            struct timespec ts = {0, 20 * 1000 * 1000};
            nanosleep(&ts, NULL);
        }
        if (r != kIOReturnSuccess) return r;
        done += n;
    }
    return kIOReturnSuccess;
}

static int q(UInt32 off, uint32_t *v) {
    uint8_t b[4];
    if (rd(DICE_BASE_HI, DICE_BASE_LO + off, b, 4) != kIOReturnSuccess) return -1;
    *v = be32(b);
    return 0;
}

// DICE stores text as bytes that come back reversed inside each 32-bit quadlet.
static void swapQuadlets(uint8_t *b, size_t n) {
    for (size_t i = 0; i + 3 < n; i += 4) {
        uint8_t t0 = b[i], t1 = b[i + 1];
        b[i] = b[i + 3]; b[i + 1] = b[i + 2]; b[i + 2] = t1; b[i + 3] = t0;
    }
}

static const char *rateName(unsigned c) {
    static const char *n[] = {"32000", "44100", "48000", "88200", "96000", "176400", "192000"};
    return c < 7 ? n[c] : "?";
}
static const char *srcName(unsigned c) {
    static const char *n[] = {"aes1", "aes2", "aes3", "aes4", "aes_any", "adat", "tdif",
                              "wc",   "arx1", "arx2", "arx3", "arx4",    "internal"};
    return c < 13 ? n[c] : "?";
}

static void printNames(const uint8_t *raw, size_t len, const char *indent) {
    // 'a\b\c\\' : names separated by '\', list ends with '\\'. The register
    // bytes are stored in big-endian quadlets of ASCII, i.e. already in order.
    char tmp[257];
    size_t n = len > 256 ? 256 : len;
    memcpy(tmp, raw, n);
    swapQuadlets((uint8_t *)tmp, n);
    tmp[n] = 0;
    int idx = 0;
    char *p = tmp;
    while (*p) {
        char *e = strchr(p, '\\');
        if (e) *e = 0;
        if (!*p && e) break;
        printf("%s%-3d '%s'\n", indent, idx++, p);
        if (!e) break;
        p = e + 1;
    }
}

static int openDevice(io_object_t svc) {
    IOCFPlugInInterface **plug = NULL;
    SInt32 score;
    if (IOCreatePlugInInterfaceForService(svc, kIOFireWireLibTypeID, kIOCFPlugInInterfaceID, &plug,
                                          &score) != kIOReturnSuccess || !plug)
        return -1;
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOFireWireDeviceInterfaceID_v9),
                                         (LPVOID *)&gDev);
    (*plug)->Release(plug);
    if (hr != S_OK || !gDev) return -1;
    gSvc = svc;
    // The vendor panel retries Open() while another client holds the device
    // (exclusive access), sleeping 1 ms between attempts.
    IOReturn r = (*gDev)->Open(gDev);
    for (int i = 0; r == kIOReturnExclusiveAccess && i < 200; i++) {
        struct timespec ts = {0, 1000 * 1000};
        nanosleep(&ts, NULL);
        r = (*gDev)->Open(gDev);
    }
    if (r != kIOReturnSuccess) return -1;
    return 0;
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

static void propStr(io_object_t svc, CFStringRef key, char *out, size_t n) {
    out[0] = 0;
    CFTypeRef t = IORegistryEntrySearchCFProperty(svc, kIOServicePlane, key, kCFAllocatorDefault,
                                                  kIORegistryIterateRecursively);
    if (t) {
        if (CFGetTypeID(t) == CFStringGetTypeID())
            CFStringGetCString(t, out, (CFIndex)n, kCFStringEncodingUTF8);
        CFRelease(t);
    }
}

// Allen & Heath units: the vendor kext matches Unit_Spec_ID 1220 (0x0004C4), which for DICE is
// the vendor OUI; we also accept the vendor name in case the registry reports it.
static int isAllenHeath(io_object_t svc, uint64_t guid) {
    char vn[128];
    propStr(svc, CFSTR("FireWire Vendor Name"), vn, sizeof vn);
    return (guid >> 40) == 0x0004C4 || propNum(svc, CFSTR("Unit_Spec_ID")) == 1220 ||
           strcasestr(vn, "allen") != NULL;
}

static void dumpRom(void) {
    uint8_t rom[1024];
    printf("\nCONFIG ROM  (raw, big-endian quadlets @ 0xFFFFF0000400)\n");
    printf("-------------------------------------------------------\n");
    // The header's crc_length may cover only the bus info block, so read block by block
    // until the device stops answering instead of trusting it.
    uint32_t got = 0;
    while (got < sizeof rom) {
        if (rd(0xFFFF, ROM_LO + got, rom + got, 64) != kIOReturnSuccess) break;
        got += 64;
    }
    if (got == 0) { printf("<read failed>\n"); return; }
    uint32_t total = got / 4;
    uint32_t hdr = be32(rom);
    printf("header: bus_info_length=%u crc_length=%u crc=0x%04X   (%u quadlets read)\n",
           hdr >> 24, (hdr >> 16) & 0xFF, hdr & 0xFFFF, total);
    for (uint32_t i = 0; i < total; i += 4) {
        printf("%03x:", i * 4);
        for (uint32_t j = i; j < i + 4 && j < total; j++) printf(" %08x", be32(rom + j * 4));
        printf("\n");
    }
    uint32_t info = (hdr >> 24) & 0xFF;
    uint32_t rootOff = (1 + info) * 4;
    if (rootOff + 4 > total * 4) { printf("<root directory outside the ROM>\n"); return; }
    uint32_t rootHdr = be32(rom + rootOff), n = rootHdr >> 16;
    printf("\nROOT DIRECTORY  (%u entries)\n", n);
    for (uint32_t i = 1; i <= n && rootOff + i * 4 + 4 <= total * 4; i++) {
        uint32_t e = be32(rom + rootOff + i * 4);
        printf("  key=0x%02X type=%u value=0x%06X\n", e >> 24, (e >> 30), e & 0xFFFFFF);
    }
}

int main(int argc, char **argv) {
    int listOnly = 0;
    uint64_t wantGuid = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-l")) listOnly = 1;
        else if (!strcmp(argv[i], "-g") && i + 1 < argc) wantGuid = strtoull(argv[++i], NULL, 16);
    }

    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFireWireDevice"), &it) !=
        kIOReturnSuccess) {
        fprintf(stderr, "cannot enumerate FireWire devices\n");
        return 2;
    }
    io_object_t svc, chosen = 0;
    int count = 0;
    while ((svc = IOIteratorNext(it))) {
        uint64_t guid = propNum(svc, CFSTR("GUID"));
        char vn[128], pn[128];
        propStr(svc, CFSTR("FireWire Vendor Name"), vn, sizeof vn);
        propStr(svc, CFSTR("FireWire Product Name"), pn, sizeof pn);
        uint64_t vid = propNum(svc, CFSTR("Vendor_ID"));
        count++;
        int ah = isAllenHeath(svc, guid);
        if (listOnly)
            printf("GUID 0x%016" PRIX64 "  vendor '%s'  product '%s'  Vendor_ID 0x%06" PRIX64
                   "  allen_heath=%d\n", guid, vn, pn, vid, ah);
        // Only Allen & Heath units are dumped, unless -g names a GUID explicitly.
        if (!chosen && (wantGuid ? guid == wantGuid : ah)) {
            chosen = svc;
            continue;
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    if (listOnly) return count ? 0 : 1;
    if (!chosen) {
        fprintf(stderr, "no Allen & Heath FireWire device found (%d FireWire devices seen)\n", count);
        return 1;
    }
    if (openDevice(chosen) != 0) {
        fprintf(stderr, "cannot open the device (is another driver holding it? try sudo)\n");
        return 3;
    }

    uint64_t guid = propNum(chosen, CFSTR("GUID"));
    char vn[128], pn[128];
    propStr(chosen, CFSTR("FireWire Vendor Name"), vn, sizeof vn);
    propStr(chosen, CFSTR("FireWire Product Name"), pn, sizeof pn);
    UInt16 node = 0;
    (*gDev)->GetGenerationAndNodeID(gDev, &gGen, &node);

    time_t now = time(NULL);
    char ts[32];
    strftime(ts, sizeof ts, "%Y-%m-%dT%H:%M:%SZ", gmtime(&now));
    printf("DICE DEVICE REPORT (dicedump, read-only, IOFireWireLib)\n");
    printf("=======================================================\n");
    printf("Generated: %s\n\n", ts);
    printf("IDENTITY\n--------\n");
    printf("GUID:          0x%016" PRIX64 "\n", guid);
    printf("Vendor:        %s\nModel:         %s\n", vn, pn);
    printf("Vendor_ID:     0x%06" PRIX64 "\n", propNum(chosen, CFSTR("Vendor_ID")));
    printf("Model_ID:      0x%06" PRIX64 "\n", propNum(chosen, CFSTR("Model_ID")));
    printf("Unit_Spec_ID:  0x%06" PRIX64 "\n", propNum(chosen, CFSTR("Unit_Spec_ID")));
    printf("Unit_SW_Ver:   0x%06" PRIX64 "\n", propNum(chosen, CFSTR("Unit_SW_Version")));
    printf("Node / gen:    %u / %u\n", node & 0x3F, gGen);
    printf("TCAT vendor:   0x%06" PRIX64 "\n", guid >> 40);
    printf("TCAT category: 0x%02" PRIX64 "\n", (guid >> 32) & 0xFF);
    printf("TCAT product:  0x%03" PRIX64 "\n", (guid >> 22) & 0x3FF);
    printf("TCAT serial:   %" PRIu64 "\n", guid & 0x3FFFFF);

    uint32_t tbl[10];
    printf("\nSECTION TABLES  (offsets and sizes in quadlets)\n");
    printf("-----------------------------------------------\n");
    for (int i = 0; i < 10; i++)
        if (q(i * 4, &tbl[i])) {
            printf("section table read failed: not a DICE device at 0xFFFFE0000000?\n");
            dumpRom();
            return 4;
        }
    const char *sn[] = {"global", "tx", "rx", "ext_sync", "unused2"};
    printf("general space @ 0xFFFFE0000000\n");
    for (int i = 0; i < 5; i++)
        printf("  %-12s offset=0x%05X (0x%06X B)  size=0x%05X (%u B)\n", sn[i], tbl[i * 2],
               tbl[i * 2] * 4, tbl[i * 2 + 1], tbl[i * 2 + 1] * 4);
    {
        uint8_t b[4];
        int ext = rd(DICE_BASE_HI, DICE_EXT_LO, b, 4) == kIOReturnSuccess;
        printf("\nextension space @ 0xFFFFE0200000\n  %s\n", ext ? "<present>" : "<absent>");
    }

    UInt32 g = tbl[0] * 4;
    uint32_t v;
    uint8_t buf[1200];
    printf("\nGLOBAL\n--------\n");
    if (rd(DICE_BASE_HI, DICE_BASE_LO + g, buf, tbl[1] * 4 > 360 ? 360 : tbl[1] * 4) == kIOReturnSuccess) {
        uint64_t own = ((uint64_t)be32(buf) << 32) | be32(buf + 4);
        printf("OWNER              = 0x%016" PRIX64 "%s\n", own,
               (own >> 48) == 0xFFFF ? "  (no owner)" : "  (owned)");
        printf("NOTIFICATION       = 0x%08X\n", be32(buf + 8));
        char nick[65];
        memcpy(nick, buf + 12, 64);
        swapQuadlets((uint8_t *)nick, 64);
        nick[64] = 0;
        printf("NICK_NAME          = '%s'\n", nick);
        v = be32(buf + 0x4C);
        printf("CLOCK_SELECT       = 0x%08X   source=%u (%s)  rate=%u (%s)\n", v, v & 0xFF,
               srcName(v & 0xFF), (v >> 8) & 0xFF, rateName((v >> 8) & 0xFF));
        v = be32(buf + 0x50);
        printf("ENABLE             = 0x%08X   streaming=%s\n", v, v ? "yes" : "no");
        v = be32(buf + 0x54);
        printf("STATUS             = 0x%08X   locked=%s  nominal=%s\n", v, (v & 1) ? "yes" : "no",
               rateName((v >> 8) & 0xFF));
        v = be32(buf + 0x58);
        printf("EXTENDED_STATUS    = 0x%08X\n", v);
        for (int s = 0; s < 13; s++) {
            if (v & (1u << s)) printf("    locked  : %s\n", srcName(s));
            if (v & (1u << (s + 16))) printf("    slipped : %s\n", srcName(s));
        }
        printf("SAMPLE_RATE        = %u Hz  (measured)\n", be32(buf + 0x5C));
        v = be32(buf + 0x60);
        printf("VERSION            = 0x%08X   (%u.%u.%u.%u)\n", v, v >> 24, (v >> 16) & 0xFF,
               (v >> 8) & 0xFF, v & 0xFF);
        v = be32(buf + 0x64);
        printf("CLOCK_CAPABILITIES = 0x%08X\n    rates   :", v);
        for (int r = 0; r < 7; r++)
            if (v & (1u << r)) printf(" %s", rateName(r));
        printf("\n    sources :");
        for (int s = 0; s < 13; s++)
            if (v & (1u << (16 + s))) printf(" %s", srcName(s));
        printf("\nCLOCK_SOURCE_NAMES:\n");
        {
            char cs[257];
            memcpy(cs, buf + 0x68, 256);
            swapQuadlets((uint8_t *)cs, 256);
            cs[256] = 0;
            int idx = 0;
            char *p = cs;
            while (*p) {
                char *e = strchr(p, '\\');
                if (e) *e = 0;
                if (!*p && e) break;
                printf("    %-3d %-9s '%s'\n", idx, srcName(idx), p);
                idx++;
                if (!e) break;
                p = e + 1;
            }
        }
    } else {
        printf("<global read failed>\n");
    }

    for (int dir = 0; dir < 2; dir++) {
        UInt32 off = tbl[dir == 0 ? 2 : 4] * 4;
        printf("\n%s STREAMS  (%s)\n", dir == 0 ? "TX" : "RX",
               dir == 0 ? "device transmits -> host capture" : "device receives <- host playback");
        printf("----------------------------------------------\n");
        uint8_t h[8];
        if (rd(DICE_BASE_HI, DICE_BASE_LO + off, h, 8) != kIOReturnSuccess) {
            printf("<read failed>\n");
            continue;
        }
        uint32_t num = be32(h), blk = be32(h + 4) * 4;
        printf("NUMBER = %u   SIZE = %u quadlets (%u bytes)\n", num, blk / 4, blk);
        if (num > 8 || blk < 0x10 || blk > sizeof buf) {
            printf("<implausible geometry, stopping>\n");
            continue;
        }
        for (uint32_t s = 0; s < num; s++) {
            uint32_t base = off + 8 + s * blk;
            if (rd(DICE_BASE_HI, DICE_BASE_LO + base, buf, blk) != kIOReturnSuccess) {
                printf("  [stream %u] <read failed>\n", s);
                continue;
            }
            int32_t iso = (int32_t)be32(buf);
            printf("\n  [stream %u]\n    ISOCHRONOUS  = %d%s\n", s, iso, iso == -1 ? "  (disabled)" : "");
            uint32_t o = 4;
            if (dir == 1) { printf("    SEQ_START    = %u\n", be32(buf + 4)); o = 8; }
            printf("    PCM channels = %u\n    MIDI ports   = %u\n", be32(buf + o), be32(buf + o + 4));
            if (dir == 0) {
                static const char *sp[] = {"S100", "S200", "S400", "S800"};
                uint32_t spd = be32(buf + 12);
                printf("    SPEED        = %s\n", spd < 4 ? sp[spd] : "?");
            }
            printf("    NAMES:\n");
            printNames(buf + 0x10, 256, "      ");
        }
    }

    printf("\nEXT_SYNC\n--------\n");
    if (rd(DICE_BASE_HI, DICE_BASE_LO + tbl[6] * 4, buf, 16) == kIOReturnSuccess) {
        v = be32(buf);
        printf("CLOCK_SOURCE   = %u (%s)\nLOCKED         = %s\nRATE           = %u (%s)\n", v,
               srcName(v), be32(buf + 4) & 1 ? "yes" : "no", be32(buf + 4) >> 8 & 0xFF,
               rateName(be32(buf + 4) >> 8 & 0xFF));
    }

    dumpRom();
    (*gDev)->Close(gDev);
    return 0;
}
