import Foundation
import Testing
@testable import GSRCore

func fixture(_ name: String) throws -> String {
    let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures")!
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct ReportTests {
    @Test func parseVeniceF32() throws {
        let r = try DiceReport.parse(try fixture("midasF32"))
        #expect(r.guid == 0x10C73F04004011DF)
        #expect(r.vendor == "Midas")
        #expect(r.model == "Venice F32")
        #expect(r.tcatOUI == 0x10C73F)
        #expect(r.tcatCategory == 0x04)
        #expect(r.tcatProduct == 1)
        #expect(r.tcatSerial == 4575)
        #expect(r.nickName == "Venice")
        #expect(r.clockSourceID == "internal")
        #expect(r.currentRate == 48000)
        #expect(r.locked)
        #expect(r.version == "1.0.4.0")
        #expect(r.supportedRates == [44100, 48000])
        #expect(r.supportedSources == ["arx1", "arx2", "internal"])
        #expect(r.clockSources.count == 13)
        #expect(r.clockSources.last == DiceClockSource(index: 12, id: "internal", label: "Internal"))
        #expect(r.tx.count == 2)
        #expect(r.rx.count == 2)
        #expect(r.captureChannels == 32)
        #expect(r.playbackChannels == 32)
        #expect(r.tx[0].speed == "S400")
        #expect(r.tx[1].names[8] == "OUTPUT ST CH1L")
        #expect(r.rx[0].names.first == "INPUT CH1")
        #expect(r.tx[0].isochronous == -1)
    }

    @Test func parseAsymmetricPreSonus() throws {
        let r = try DiceReport.parse(try fixture("presonus2442"))
        #expect(r.captureChannels == 32)   // 16 + 16 per the ASFW fixture notes
        #expect(r.playbackChannels == 26)  // 16 + 10
    }

    @Test func rejectsGarbage() {
        #expect(throws: DiceReport.ParseError.noIdentity) { try DiceReport.parse("hello") }
    }
}

@Suite struct PacketTests {
    @Test func cipRoundTripAndBytes() {
        let h = CIPHeader(sourceID: 1, dataBlockSize: 16, dataBlockCount: 0x20, fdf: SampleRate.r48000.fdf, syt: 0x1234)
        #expect(h.encoded() == [0x01, 0x10, 0x00, 0x20, 0x90, 0x02, 0x12, 0x34])
        #expect(CIPHeader(h.encoded()) == h)
        #expect(CIPHeader([0x41, 0x10, 0, 0, 0x90, 2, 0, 0]) == nil)   // EOH0 set
        #expect(CIPHeader([0x01, 0x10, 0, 0, 0x91, 2, 0, 0]) == nil)   // wrong format
    }

    @Test func rateTables() {
        #expect(SampleRate(fdf: 4) == .r96000)
        #expect(SampleRate.r44100.sytInterval == 8)
        #expect(SampleRate.r96000.sytInterval == 16)
        #expect(SampleRate(fdf: 7) == nil)
    }

    @Test func am824Sample() {
        #expect(AM824.audioQuadlet(fromInt32: 0x1234_5600) == 0x4012_3456)
        #expect(AM824.int32(fromQuadlet: 0x4012_3456) == 0x1234_5600)
        #expect(AM824.int32(fromQuadlet: 0x40FF_FFFF) == Int32(bitPattern: 0xFFFF_FF00))
        #expect(AM824.midiQuadlet(byte: 0x90) == 0x8190_0000)
        #expect(AM824.midiQuadlet(byte: nil) == 0x8000_0000)
        #expect(AM824.midiByte(fromQuadlet: 0x8190_0000) == 0x90)
        #expect(AM824.midiByte(fromQuadlet: 0x8000_0000) == nil)
    }

    @Test func packUnpackWithMIDI() {
        let frames: [Int32] = [0x0100_0000, -0x0100_0000, 0x7FFF_FF00, Int32.min,
                               0x0000_0100, 0x0000_0200, 0x0000_0300, 0x0000_0400]
        let payload = AM824.pack(frames: frames, pcmChannels: 4, frameCount: 2, midiSlot: true, midi: [0x90, nil])
        #expect(payload.count == 2 * 5 * 4)
        let out = AM824.unpack(payload: payload, pcmChannels: 4, midiSlot: true)
        #expect(out.frames == frames)
        #expect(out.midi.count == 2)
        #expect(out.midi[0] == 0x90)
        #expect(out.midi[1] == nil)
    }
}


/// Synthetic reports built from the rules in the vendor driver; not a capture of a real card.
func syntheticReport(vendor: String, specID: String, guid: String) -> String {
    """
    DICE DEVICE REPORT
    IDENTITY
    --------
    GUID:          \(guid)
    Vendor:        \(vendor)
    Model:         test
    Unit_Spec_ID:  \(specID)
    """
}

@Suite struct AllenHeathTests {
    // GUID = OUI(24) category(8) product(10) serial(22)
    @Test func gsr24Accepted() throws {
        let r = try DiceReport.parse(syntheticReport(vendor: "Allen and Heath Ltd.", specID: "0x0004C4", guid: "0x0004C40400401234"))
        #expect(r.ahKind == .gsr24)
    }
    @Test func zedAccepted() throws {
        let r = try DiceReport.parse(syntheticReport(vendor: "", specID: "0x0004C4", guid: "0x0004C40400001234"))
        #expect(r.ahKind == .zedr16)
    }
    @Test func venicePrefixSameProductRejected() throws {
        // Midas Venice also has category 4 and product 1: must not be taken for a GS-R24.
        let r = try DiceReport.parse(try fixture("midasF32"))
        #expect(r.ahKind == nil)
        #expect(r.ahCheck().reason.contains("Allen"))
    }
    @Test func wrongProductRejected() throws {
        let r = try DiceReport.parse(syntheticReport(vendor: "Allen and Heath Ltd.", specID: "0x0004C4", guid: "0x0004C40400801234"))
        #expect(r.ahKind == nil)
    }
}


@Suite struct ChannelNameTests {
    let guid: UInt64 = 0x0004C40400401234

    @Test func setGetRemove() {
        var s = ChannelNameStore()
        #expect(s.name(guid: guid, .input, channel: 1) == nil)
        s.set(guid: guid, .input, channel: 1, name: "  Kick  ")
        s.set(guid: guid, .output, channel: 1, name: "Monitor L")
        #expect(s.name(guid: guid, .input, channel: 1) == "Kick")
        #expect(s.name(guid: guid, .output, channel: 1) == "Monitor L")   // directions are independent
        s.set(guid: guid, .input, channel: 1, name: "   ")
        #expect(s.name(guid: guid, .input, channel: 1) == nil)
        s.reset(guid: guid)
        #expect(s.devices.isEmpty)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gsr-names-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var s = ChannelNameStore()
        s.set(guid: guid, .input, channel: 17, name: "Overhead L")
        #expect(s.save(to: url))
        let back = ChannelNameStore.load(from: url)
        #expect(back == s)
        #expect(back.name(guid: guid, .input, channel: 17) == "Overhead L")
    }

    @Test func missingFileGivesEmptyStore() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        #expect(ChannelNameStore.load(from: url) == ChannelNameStore())
    }
}


/// Captured from the real GS-R24 (serial 837, DICE firmware 1.0.12.0) on 2026-10-25.
@Suite struct RealCardTests {
    @Test func realGSR24Report() throws {
        let r = try DiceReport.parse(try fixture("gsr24m-real"))
        #expect(r.ahKind == .gsr24)
        #expect(r.guid == 0x0004C40400400345)
        #expect(r.tcatOUI == 0x0004C4)
        #expect(r.tcatCategory == 0x04)
        #expect(r.tcatProduct == 1)
        #expect(r.tcatSerial == 837)
        #expect(r.vendorID == 0x0004C4)
        #expect(r.modelID == 1)
        #expect(r.unitSpecID == 0x0004C4)
        #expect(r.nickName == "GS R-24")
        #expect(r.version == "1.0.12.0")
        #expect(r.currentRate == 48000)
        #expect(r.clockSourceID == "internal")
        #expect(r.locked)
        #expect(r.supportedRates == [44100, 48000, 88200, 96000])
        #expect(r.supportedSources == ["wc", "internal"])
        #expect(r.clockSources.count == 13)
        #expect(r.clockSources[7] == DiceClockSource(index: 7, id: "wc", label: "Word Clock"))
        #expect(r.tx.count == 2 && r.rx.count == 2)
        #expect(r.captureChannels == 32 && r.playbackChannels == 32)
        #expect(r.tx[0].midiPorts == 3 && r.tx[1].midiPorts == 0)
        #expect(r.tx[0].speed == "S400")
        #expect(r.tx[0].names.first == "CH1/CH1/2")
        #expect(r.tx[1].names.first == "CH17/CH17/18")
        #expect(r.tx.allSatisfy { $0.names.count == 16 })
        #expect(r.rx.allSatisfy { $0.names.count == 16 })
    }
}


@Suite struct DaemonInfoTests {
    static let sample = """
    {"version":1,"state":2,"generation":3,"haveCard":true,"owned":true,"sessions":2,"busResets":0,"uptime":120,"leadMs":80,"ioClients":1,"inLate":0,"outLate":672,"inWritten":5760000,"cipErrors":0,"dbcJumps":0,"maxGapMs":2.3,"error":"","guid":"0x0004C40400400345","vendor":"A_H","model":"Allen_and_Heath_GS_R_24","vendorID":1220,"modelID":1,"unitSpecID":1220,"nickName":"GS R-24","clockSource":"internal","rate":48000,"locked":true,"ext":192,"dice":"1.0.12.0","rates":[44100,48000,88200,96000],"sources":["wc","internal"],"clockSources":[{"id":"aes1","label":"AES12"},{"id":"internal","label":"Internal"}],"tx":[{"index":0,"iso":3,"pcm":16,"midi":3,"speed":"S400","names":["CH1/CH1/2","CH2/CH1/2"]},{"index":1,"iso":4,"pcm":16,"midi":0,"speed":"S400","names":["CH17/CH17/18"]}],"rx":[{"index":0,"iso":1,"pcm":16,"midi":3,"speed":"","names":["CH1/CH1/2"]}],"customIn":["Kick","",""],"customOut":["","",""]}
    """

    @Test func decodesDaemonJSON() throws {
        let i = try #require(DaemonInfo.decode(Self.sample))
        #expect(i.state == 2 && i.isStreaming && i.leadMs == 80 && i.outLate == 672)
        let r = try #require(i.report())
        #expect(r.guid == 0x0004C40400400345)
        #expect(r.currentRate == 48000 && r.locked && r.supportedRates == [44100, 48000, 88200, 96000])
        #expect(r.tx.count == 2 && r.tx[0].midiPorts == 3 && r.tx[0].speed == "S400" && r.rx[0].speed == nil)
        #expect(r.ahCheck().kind == .gsr24)
    }

    @Test func noCardStillDecodes() throws {
        let j = "{\"version\":1,\"state\":0,\"generation\":1,\"haveCard\":false,\"owned\":false,\"sessions\":0,\"busResets\":0,\"uptime\":3,\"leadMs\":80,\"ioClients\":0,\"inLate\":0,\"outLate\":0,\"inWritten\":0,\"cipErrors\":0,\"dbcJumps\":0,\"maxGapMs\":0,\"error\":\"carte occupée\",\"customIn\":[],\"customOut\":[]}"
        let i = try #require(DaemonInfo.decode(j))
        #expect(i.report() == nil && i.error == "carte occupée")
    }

    @Test func operationModesMapToLeads() {
        #expect(DaemonInfo.modeName(forLead: 80) == "Normal Mode")
        #expect(DaemonInfo.modeName(forLead: 45) == "Lowest Latency")
        #expect(DaemonInfo.modeName(forLead: 300) == "Safe Mode Level 2")
    }

    @Test func everyModeHasItsLatencies() {
        for m in DaemonInfo.modeLeads {
            #expect(DaemonInfo.outputLatencyMs(forLead: m.ms) == m.ms + 3)
            #expect(DaemonInfo.inputSafetyMs(forLead: m.ms) >= 6)
        }
        #expect(DaemonInfo.inputSafetyMs(forLead: 80) == 10)
    }

    @Test func nameListsHaveThirtyTwoEntries() {
        var s = ChannelNameStore()
        s.set(guid: 7, .input, channel: 3, name: "Snare")
        let l = s.lists(guid: 7)
        #expect(l.inputs.count == 32 && l.outputs.count == 32 && l.inputs[2] == "Snare" && l.inputs[0] == "")
    }
}


@Suite struct ChannelLabelTests {
    @Test func shortNameDropsThePairLabel() {
        #expect("CH16/CH15/16".channelShortName == "CH16")
        #expect("CH1".channelShortName == "CH1")
        #expect("ADAT1/2".channelShortName == "ADAT1")
        #expect("".channelShortName == "")
    }
}


@Suite struct UpdateTests {
    static let release = """
    {"tag_name":"v0.3.1","draft":false,"prerelease":false,"html_url":"https://github.com/FLORIANSV35/GSR24M-driver/releases/tag/v0.3.1","body":"Notes",
     "assets":[{"name":"GSR24M-0.3.1.pkg","browser_download_url":"https://example.com/GSR24M-0.3.1.pkg"},
               {"name":"GSR24M-0.3.1.pkg.sha256","browser_download_url":"https://example.com/GSR24M-0.3.1.pkg.sha256"}]}
    """

    @Test func versionsCompareNumerically() {
        #expect(SemVer("v0.10.0")! > SemVer("0.9.9")!)
        #expect(SemVer("1.0")! == SemVer(1, 0, 0))
        #expect(SemVer("0.2.0-beta")! == SemVer(0, 2, 0))
        #expect(SemVer("abc") == nil && SemVer("1.2.3.4") == nil && SemVer("") == nil)
    }

    @Test func parsesTheLatestReleaseAnswer() throws {
        let r = try #require(ReleaseInfo.parse(Data(Self.release.utf8)))
        #expect(r.version == SemVer(0, 3, 1) && r.tag == "v0.3.1" && r.notes == "Notes")
        #expect(r.installerURL?.lastPathComponent == "GSR24M-0.3.1.pkg" && r.checksumURL?.lastPathComponent == "GSR24M-0.3.1.pkg.sha256")
        #expect(r.isNewer(than: "0.2.0") && !r.isNewer(than: "0.3.1") && !r.isNewer(than: "0.4.0") && !r.isNewer(than: "garbage"))
    }

    @Test func refusesDraftsPrereleasesAndGarbage() {
        #expect(ReleaseInfo.parse(Data(Self.release.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true").utf8)) == nil)
        #expect(ReleaseInfo.parse(Data(Self.release.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true").utf8)) == nil)
        #expect(ReleaseInfo.parse(Data("{}".utf8)) == nil)
        #expect(ReleaseInfo.parse(Data("not json".utf8)) == nil)
    }

    @Test func readsTheChecksumFile() {
        let h = String(repeating: "ab", count: 32)
        #expect(ReleaseInfo.checksum(from: h + "  GSR24M-0.3.1.pkg\n") == h)
        #expect(ReleaseInfo.checksum(from: "zz") == nil)
        #expect(ReleaseInfo.checksum(from: h.uppercased()) == h)
    }
}
