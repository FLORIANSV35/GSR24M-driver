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

    @Test func countersCanBeCountedFromAReference() throws {
        let base = try #require(DaemonInfo.decode(Self.sample))                       // outLate 672
        var later = base; later.outLate = 700; later.inLate = 40; later.busResets = 2
        let shown = later.minus(base)
        #expect(shown.outLate == 28 && shown.inLate == 40 && shown.busResets == 2)
        var restarted = base; restarted.outLate = 5                                   // the daemon restarted: lower than the reference, shown as is
        #expect(restarted.minus(base).outLate == 5)
        #expect(later.minus(nil) == later)
    }

    @Test func loadOfTheChain() throws {
        let i = try #require(DaemonInfo.decode(Self.sample))                           // 48 kHz: tx 16+16 pcm with midi on stream 0, rx 16 pcm with midi
        let bps = try #require(Load.busBytesPerSecond(i))
        #expect(bps > 1_000_000 && bps < 10_000_000)
        let pct = try #require(Load.busPercent(i))
        #expect(pct > 3 && pct < 25)
        #expect(Load.rate(100, 160, seconds: 2) == 30 && Load.rate(500, 20, seconds: 1) == 20 && Load.rate(1, 2, seconds: 0) == 0)
        #expect(Load.level(5, warning: 10, critical: 20) == .ok && Load.level(10, warning: 10, critical: 20) == .warning && Load.level(25, warning: 10, critical: 20) == .critical)
        let withMIDI = try #require(DaemonInfo.decode(Self.sample.replacingOccurrences(of: "\"customIn\"", with: "\"midi\":{\"subscribers\":1,\"in\":[10,0,0,0,0,0,0,0],\"out\":[5,0,0],\"inDrops\":0,\"outDrops\":2},\"customIn\"")))
        #expect(withMIDI.midi?.inBytes[0] == 10 && withMIDI.midi?.outDrops == 2 && i.midi == nil)
    }

    @Test func noCardStillDecodes() throws {
        let j = "{\"version\":1,\"state\":0,\"generation\":1,\"haveCard\":false,\"owned\":false,\"sessions\":0,\"busResets\":0,\"uptime\":3,\"leadMs\":80,\"ioClients\":0,\"inLate\":0,\"outLate\":0,\"inWritten\":0,\"cipErrors\":0,\"dbcJumps\":0,\"maxGapMs\":0,\"error\":\"card busy\",\"customIn\":[],\"customOut\":[]}"
        let i = try #require(DaemonInfo.decode(j))
        #expect(i.report() == nil && i.error == "card busy")
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


@Suite struct EQMeasureTests {
    /// A made-up channel: a peaking filter at 1 kHz (+6 dB, Q 1.5) and a 3.3 ms delay, circular as a periodic signal would see it.
    static func simulate(gainDB: Double, rate: Double = 48000, periods: Int = 4, noise: Double = 3e-5) -> (rec: [Float], ref: [Float]) {
        let L = EQMeasure.period
        let x = EQMeasure.pinkPeriod(seed: 7, rate: rate)
        var re = x.map(Double.init), im = [Double](repeating: 0, count: L)
        EQMeasure.fft(&re, &im)
        let A = pow(10, gainDB / 40), w0 = 2 * Double.pi * 1000 / rate, al = sin(w0) / (2 * 1.5)
        let b = [1 + al * A, -2 * cos(w0), 1 - al * A], a = [1 + al / A, -2 * cos(w0), 1 - al / A]
        for k in 0...L / 2 {
            let f = rate * Double(k) / Double(L), ww = -2 * Double.pi * f / rate
            let z1r = cos(ww), z1i = sin(ww), z2r = cos(2 * ww), z2i = sin(2 * ww)
            let nr = b[0] + b[1] * z1r + b[2] * z2r, ni = b[1] * z1i + b[2] * z2i
            let dr = a[0] + a[1] * z1r + a[2] * z2r, di = a[1] * z1i + a[2] * z2i
            let den = dr * dr + di * di
            var hr = (nr * dr + ni * di) / den, hi = (ni * dr - nr * di) / den
            let dl = -2 * Double.pi * f * 0.0033, c = cos(dl), s = sin(dl)
            (hr, hi) = (hr * c - hi * s, hr * s + hi * c)
            let (xr, xi) = (re[k], im[k])
            re[k] = xr * hr - xi * hi; im[k] = xr * hi + xi * hr
            if k > 0 && k < L / 2 { re[L - k] = re[k]; im[L - k] = -im[k] }
        }
        EQMeasure.fft(&re, &im, inverse: true)
        let y = re.map { Float($0 / Double(L)) }
        var g = SystemRandomNumberGenerator()
        let rec = (0..<(periods * L)).map { y[$0 % L] + Float(noise * Double.random(in: -1...1, using: &g) * 1.7) }
        return (rec, x)
    }

    @Test func recoversTheBump() throws {
        let (rec, ref) = Self.simulate(gainDB: 6)
        let c = try #require(EQMeasure.curve(recorded: rec, reference: ref, rate: 48000))
        let i = try #require(c.freq.firstIndex { abs($0 - 1000) < 40 })
        #expect(abs(c.db[i] - 6) < 0.15)
        let lo = try #require(c.freq.firstIndex { $0 > 30 })
        #expect(abs(c.db[lo]) < 0.15)
    }

    @Test func identicalCurvesAreExact() throws {
        let (rec, ref) = Self.simulate(gainDB: 3)
        let c = try #require(EQMeasure.curve(recorded: rec, reference: ref, rate: 48000))
        let a = try #require(EQMeasure.accuracy(target: c, live: c))
        #expect(a.percent == 100 && a.maxDeviation == 0)
    }

    @Test func aSmallKnobChangeLowersTheScoreInTheRightBand() throws {
        let (r1, ref) = Self.simulate(gainDB: 6)
        let (r2, _) = Self.simulate(gainDB: 7)
        let t = try #require(EQMeasure.curve(recorded: r1, reference: ref, rate: 48000))
        let l = try #require(EQMeasure.curve(recorded: r2, reference: ref, rate: 48000))
        let a = try #require(EQMeasure.accuracy(target: t, live: l))
        #expect(a.percent < 95 && a.percent > 40)
        #expect(abs(a.maxDeviation - 1) < 0.2)
        let lmf = try #require(a.bands.first { $0.name == "LMF" })
        let lf = try #require(a.bands.first { $0.name == "LF" })
        #expect(abs(lmf.maxDeviation) > 0.6 && abs(lf.maxDeviation) < 0.1)
    }

    @Test func toleranceEdges() {
        let f = EQMeasure.grid
        let t = EQCurve(freq: f, db: f.map { _ in 0 })
        let within = EQCurve(freq: f, db: f.map { _ in 0.19 })
        let two = EQCurve(freq: f, db: f.map { _ in 2.0 })
        #expect(EQMeasure.accuracy(target: t, live: within)!.percent == 100)
        #expect(EQMeasure.accuracy(target: t, live: two)!.percent == 0)
    }

    @Test func captureRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gsr-eq-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = EQMeasure.grid
        var cap = EQCapture(name: "Show 1 / day 2", rate: 48000)
        cap.channels["3"] = EQCurve(freq: f, db: f.map { $0 / 1000 })
        #expect(cap.save(in: dir))
        let all = EQCapture.loadAll(from: dir)
        #expect(all.count == 1 && all[0].name == "Show 1 / day 2" && all[0].channels["3"] == cap.channels["3"])
    }
}


@Suite struct RecallEngineHardwareTests {
    /// Needs the real chain (gsrd, plug-in, card). Plays noise at -140 dBFS (silent in practice) on channel 24. Run with GSR_HW_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GSR_HW_TESTS"] == "1" && RecallEngine.deviceAvailable))
    func recordsFramesAndComputesACurve() async throws {
        let e = RecallEngine()
        try e.start(channel: 24, levelDB: -140)
        try await Task.sleep(nanoseconds: 6_500_000_000)
        let frames = e.recordedFrames
        let rec = try #require(e.recent(frames: EQMeasure.period * 3))
        let ref = EQMeasure.pinkPeriod(seed: 24, rate: e.rate)
        e.stop()
        #expect(frames > Int(e.rate * 5))
        #expect(rec.count == EQMeasure.period * 3 && ref.count == EQMeasure.period)
        #expect(EQMeasure.curve(recorded: rec, reference: ref, rate: e.rate) != nil)
    }
}


@Suite struct RecallEngineNoiseTests {
    /// Plays real noise on channel 1 and prints the curve the app would draw. GSR_HW_NOISE=1, console prepared (monitors off, A+B on channel 1).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GSR_HW_NOISE"] == "1" && RecallEngine.deviceAvailable))
    func printsTheRealCurve() async throws {
        let e = RecallEngine()
        try e.start(channel: 1, levelDB: -36)
        try await Task.sleep(nanoseconds: 9_000_000_000)
        let rec = try #require(e.recent(frames: EQMeasure.period * 3))
        let ref = EQMeasure.pinkPeriod(seed: 1, rate: e.rate)
        e.stop()
        let c = try #require(EQMeasure.curve(recorded: rec, reference: ref, rate: e.rate))
        let pick = [50, 100, 200, 500, 1000, 2000, 5000, 10000, 15000]
        var line = ""
        for f in pick { if let i = c.freq.indices.min(by: { abs(c.freq[$0] - Double(f)) < abs(c.freq[$1] - Double(f)) }) { line += String(format: "%d Hz %.2f dB | ", f, c.db[i] + 36) } }
        print("APP CURVE (relative to the played level): " + line)
        print("APP CURVE span: min \(c.db.min()! + 36) max \(c.db.max()! + 36), points \(c.freq.count)")
    }
}

@Suite struct EQFitTests {
    private func curve(_ s: EQSettings, noise: Double = 0) -> (f: [Double], db: [Double]) {
        var g = SystemRandomNumberGenerator()
        let f = EQMeasure.grid
        return (f, f.map { EQFit.response(s, at: $0) + (noise > 0 ? Double.random(in: -noise...noise, using: &g) : 0) })
    }

    @Test func flatEQGivesFlatSettings() {
        let flat = EQSettings(lf: 0, hf: 0, lmf: .init(gain: 0, freq: 200, q: 1), hmf: .init(gain: 0, freq: 2000, q: 1))
        let c = curve(flat)
        let r = EQFit.fit(freq: c.f, db: c.db)
        #expect(abs(r.lf) < 0.3 && abs(r.hf) < 0.3 && r.lmf.isFlat && r.hmf.isFlat)
    }

    @Test func recoversAKnownSetting() {
        let s = EQSettings(lf: 4.5, hf: -6, lmf: .init(gain: 7, freq: 250, q: 2), hmf: .init(gain: -5, freq: 3500, q: 1.2))
        let c = curve(s, noise: 0.1)
        let r = EQFit.fit(freq: c.f, db: c.db)
        #expect(abs(r.lf - 4.5) < 0.6 && abs(r.hf + 6) < 0.6)
        #expect(abs(r.lmf.gain - 7) < 0.8 && abs(log2(r.lmf.freq / 250)) < 0.15)
        #expect(abs(r.hmf.gain + 5) < 0.8 && abs(log2(r.hmf.freq / 3500)) < 0.15)
        #expect(r.residual < 0.3)
    }

    @Test func recoversAShelvesOnlySetting() {
        let s = EQSettings(lf: -10, hf: 8, lmf: .init(gain: 0, freq: 100, q: 1), hmf: .init(gain: 0, freq: 1000, q: 1))
        let c = curve(s)
        let r = EQFit.fit(freq: c.f, db: c.db)
        #expect(abs(r.lf + 10) < 0.5 && abs(r.hf - 8) < 0.5)
        #expect(r.lmf.isFlat && r.hmf.isFlat)
    }

    @Test func followsAChange() {
        let a = EQSettings(lf: 3, hf: 2, lmf: .init(gain: 5, freq: 300, q: 2), hmf: .init(gain: 0, freq: 2000, q: 1))
        let first = EQFit.fit(freq: curve(a).f, db: curve(a).db)
        var b = a; b.lmf.gain = 8
        let r = EQFit.fit(freq: curve(b).f, db: curve(b).db, previous: first)
        #expect(abs(r.lmf.gain - 8) < 0.5)
    }

    @Test func relativeCurveRemovesThePath() {
        let f = EQMeasure.grid
        let path = EQCurve(freq: f, db: f.map { -30 + 3 * log10($0) })
        let eq = EQCurve(freq: f, db: f.map { _ in 2.0 })
        let both = EQCurve(freq: f, db: zip(path.db, eq.db).map { $0 + $1 })
        let r = both.relative(to: path)!
        #expect(r.db.allSatisfy { abs($0 - 2) < 1e-9 })
    }
}

@Suite struct RecallFitHardwareTests {
    /// GSR_HW_FIT=1: measures channel 1 now, subtracts the stored reference and prints the curve and the fitted knobs.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GSR_HW_FIT"] == "1" && RecallEngine.deviceAvailable))
    func printsTheFit() async throws {
        let e = RecallEngine()
        try e.start(channel: 1, levelDB: -36)
        try await Task.sleep(nanoseconds: 9_000_000_000)
        let rec = try #require(e.recent(frames: EQMeasure.period * 3))
        let rate = e.rate
        e.stop()
        let c = try #require(EQMeasure.curve(recorded: rec, reference: EQMeasure.pinkPeriod(seed: 1, rate: rate), rate: rate))
        let flat = try #require(EQReferences.load().channels["1"])
        let rel = try #require(c.relative(to: flat))
        var line = ""
        for f in [20, 40, 80, 160, 320, 640, 1250, 2500, 5000, 10000, 18000] {
            let i = rel.freq.indices.min { abs(rel.freq[$0] - Double(f)) < abs(rel.freq[$1] - Double(f)) }!
            line += String(format: "%d:%+.1f ", f, rel.db[i])
        }
        if let out = ProcessInfo.processInfo.environment["GSR_HW_FIT_DUMP"] {
            try JSONEncoder().encode(rel).write(to: URL(fileURLWithPath: out))
        }
        let r = EQFit.fit(freq: rel.freq, db: rel.db)
        print("FIT CURVE " + line)
        print(String(format: "FIT LF %+.1f HF %+.1f LMF %+.1f@%.0f Q%.1f HMF %+.1f@%.0f Q%.1f residual %.2f", r.lf, r.hf, r.lmf.gain, r.lmf.freq, r.lmf.q, r.hmf.gain, r.hmf.freq, r.hmf.q, r.residual))
    }
}


@Suite struct KnobQTests {
    @Test func measuredPointsOfTheLeftStopAgree() {
        for (q, g) in [(0.41, 7.5), (0.60, 11.7), (0.74, 16.4), (0.20, -9.2)] {
            let k = EQFit.knobQ(effective: q, gain: g)
            #expect(abs(k - 0.74) < 0.1, "Q read \(q) at \(g) dB gave \(k)")
        }
    }

    @Test func aWiderBellMeansAHigherReadingKeepsOrder() {
        #expect(EQFit.knobQ(effective: 2, gain: 10) > EQFit.knobQ(effective: 1, gain: 10))
    }
}

@Suite struct GuidanceTests {
    private func curve(_ s: EQSettings) -> EQCurve { EQCurve(freq: EQMeasure.grid, db: EQMeasure.grid.map { EQFit.response(s, at: $0) }) }
    private let base = EQSettings(lf: 3, hf: -2, lmf: .init(gain: 7, freq: 180, q: 0.8), hmf: .init(gain: 4, freq: 1500, q: 1.0))

    @Test func nothingToDoWhenTheCurvesAgree() throws {
        let g = try #require(EQGuide.guidance(live: curve(base), target: curve(base), around: base))
        #expect(g.best == nil)
    }

    @Test func namesTheOneKnobThatDiffers() throws {
        let cases: [(EQGuide.Knob, (inout EQSettings) -> Void, Bool)] = [
            (.lf, { $0.lf += 4 }, true), (.hf, { $0.hf -= 4 }, false), (.lmfGain, { $0.lmf.gain += 3 }, true),
            (.hmfGain, { $0.hmf.gain -= 3 }, false), (.lmfFreq, { $0.lmf.freq *= 1.3 }, true), (.hmfFreq, { $0.hmf.freq /= 1.3 }, false)]
        for (knob, change, up) in cases {
            var target = base; change(&target)
            let g = try #require(EQGuide.guidance(live: curve(base), target: curve(target), around: base))
            #expect(g.best == knob, "expected \(knob), got \(String(describing: g.best))")
            #expect((g.amounts[knob.rawValue] > 0) == up, "wrong direction for \(knob)")
        }
    }

    @Test func offSettingsStillPointTheRightWay() throws {
        var target = base; target.lmf.gain += 3
        var off = base; off.lmf.freq = 240; off.lmf.q = 1.2; off.hf = 0
        let g = try #require(EQGuide.guidance(live: curve(base), target: curve(target), around: off))
        #expect(g.best == .lmfGain && g.amounts[EQGuide.Knob.lmfGain.rawValue] > 0)
    }
}

@Suite struct EQGuideTests {
    private func curve(_ s: EQSettings) -> EQCurve { EQCurve(freq: EQMeasure.grid, db: EQMeasure.grid.map { EQFit.response(s, at: $0) }) }
    private let base = EQSettings(lf: 3, hf: -2, lmf: .init(gain: 7, freq: 180, q: 0.8), hmf: .init(gain: 4, freq: 1500, q: 1.0))

    @Test func recognisesEachKnobThatMoves() throws {
        var cases: [(EQGuide.Knob, EQSettings)] = []
        var s = base; s.lf += 2; cases.append((.lf, s))
        s = base; s.hf -= 3; cases.append((.hf, s))
        s = base; s.lmf.gain += 2.5; cases.append((.lmfGain, s))
        s = base; s.lmf.freq *= 1.25; cases.append((.lmfFreq, s))
        s = base; s.hmf.gain -= 2.5; cases.append((.hmfGain, s))
        s = base; s.hmf.freq /= 1.25; cases.append((.hmfFreq, s))
        for (knob, moved) in cases {
            let m = try #require(EQGuide.movedKnob(from: curve(base), to: curve(moved), around: base), "no move found for \(knob)")
            #expect(m.knob == knob, "\(knob) was read as \(m.knob)")
        }
    }

    @Test func directionOfTheMove() throws {
        var up = base; up.lmf.freq *= 1.25
        #expect(try #require(EQGuide.movedKnob(from: curve(base), to: curve(up), around: base)).amount > 0)
        #expect(try #require(EQGuide.movedKnob(from: curve(up), to: curve(base), around: up)).amount < 0)
    }

    @Test func tinyChangesAreIgnored() {
        var s = base; s.lmf.gain += 0.1
        #expect(EQGuide.movedKnob(from: curve(base), to: curve(s), around: base) == nil)
    }

    @Test func severalKnobsAtOnceAreNotBlamedOnOne() {
        var s = base; s.lf += 3; s.hf -= 3; s.lmf.gain += 3; s.hmf.freq *= 1.8
        #expect(EQGuide.movedKnob(from: curve(base), to: curve(s), around: base) == nil)
    }

    @Test func remainingDistanceTellsWhichWayToGo() throws {
        var target = base; target.lmf.freq = 400
        let r = try #require(EQGuide.remaining(live: curve(base), target: curve(target), knob: .lmfFreq, around: base))
        #expect(r > 0.3)                                    // live is too low: turn clockwise
        let back = try #require(EQGuide.remaining(live: curve(target), target: curve(base), knob: .lmfFreq, around: target))
        #expect(back < -0.3)
        let done = try #require(EQGuide.remaining(live: curve(base), target: curve(base), knob: .lmfFreq, around: base))
        #expect(abs(done) < EQGuide.tolerance(.lmfFreq))
    }

    @Test func wrongSettingsStillGiveTheRightKnobAndDirection() throws {
        var moved = base; moved.lmf.freq *= 1.25
        var off = base; off.lmf.freq = 230; off.lmf.gain = 5.5; off.lmf.q = 1.0     // linearisation point clearly off
        let m = try #require(EQGuide.movedKnob(from: curve(base), to: curve(moved), around: off))
        #expect(m.knob == .lmfFreq && m.amount > 0)
    }
}
