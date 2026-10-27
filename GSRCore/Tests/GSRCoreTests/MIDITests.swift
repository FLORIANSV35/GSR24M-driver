import Foundation
import Testing
@testable import GSRCore

private func bytes(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

private struct Vectors: Decodable {
    struct ToHUI: Decodable { struct Out: Decodable { let device: Int; let bytes: String }; let rule: String; let `in`: String; let out: [Out] }
    struct ToConsole: Decodable { let rule: String; let device: Int; let `in`: String; let out: String }
    let toHUI: [ToHUI]
    let toConsole: [ToConsole]
    static func load() throws -> Vectors {
        let url = Bundle.module.url(forResource: "bome-vectors", withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }
}

@Suite struct MIDIParserTests {
    @Test func wholeMessagesWithRunningStatus() {
        var p = MIDIParser()
        let got = p.feed(bytes("90 01 7F 02 7F 80 01 00 B0 07 40"))
        #expect(got == [bytes("90 01 7F"), bytes("90 02 7F"), bytes("80 01 00"), bytes("B0 07 40")])
    }

    @Test func sysexAndRealtimeInside() {
        var p = MIDIParser()
        let got = p.feed(bytes("F0 7F 7F 06 02 F8 F7 90 01 7F"))
        #expect(got == [[0xF8], bytes("F0 7F 7F 06 02 F7"), bytes("90 01 7F")])
    }

    @Test func oneByteMessagesAndStrayData() {
        var p = MIDIParser()
        #expect(p.feed(bytes("12 34")) == [])                       // data without a status
        #expect(p.feed(bytes("C0 05 07")) == [bytes("C0 05"), bytes("C0 07")])
    }
}

@Suite struct HUITests {
    @Test func switchAndFaderBytes() {
        #expect(HUI.switchMessage(zone: 0x0E, port: 4, pressed: true) == bytes("B0 0F 0E B0 2F 44"))
        #expect(HUI.switchMessage(zone: 0x0E, port: 4, pressed: false) == bytes("B0 0F 0E B0 2F 04"))
        #expect(HUI.fader(strip: 3, value: 0x55) == bytes("B0 03 55 B0 23 00"))
    }

    @Test func hostReader() {
        var r = HUI.HostReader()
        #expect(r.read(bytes("90 00 00")) == .ping)
        #expect(r.read(bytes("B0 0C 02")) == .other)
        #expect(r.read(bytes("B0 2C 41")) == .led(zone: 2, port: 1, on: true))
        #expect(r.read(bytes("B0 0C 0E")) == .other)
        #expect(r.read(bytes("B0 2C 04")) == .led(zone: 0x0E, port: 4, on: false))
        #expect(r.read(bytes("B0 01 4D")) == .other)
        #expect(r.read(bytes("B0 21 05")) == .fader(strip: 1, value: 0x4D))
        #expect(r.read(bytes("F0 00 00 66 05 00 10 03 41 42 43 44 F7")) == .smallDisplay(zone: 3, text: "ABCD"))
        #expect(r.read(bytes("A0 12 07")) == .meter(zone: 0x12, level: 7))
    }
}

@Suite struct ConsoleMapTests {
    @Test func identifiesTheDefaultCodes() throws {
        let m = ConsoleMap.mode3()
        func id(_ s: String) -> (ConsoleControl, Layer?, ControlEvent)? { m.identify(bytes(s)).map { ($0.control, $0.layer, $0.event) } }
        #expect(id("90 05 7F")! == (.sel(5), nil, .down))          // mode 3: Shift (note 0x6C) does not change the code
        #expect(id("80 05 00")! == (.sel(5), nil, .up))
        #expect(id("90 21 7F")! == (.st(1), nil, .down))
        #expect(id("90 22 7F")! == (.st(2), nil, .down))
        #expect(id("90 27 7F")! == (.sel(5), .shift, .down))
        #expect(id("B0 0C 55")! == (.fader(12), nil, .value(0x55)))
        #expect(id("90 6D 7F")! == (.button(1), nil, .down))
        #expect(id("90 79 00")! == (.arrowDown, nil, .up))
        #expect(id("F0 7F 7F 06 02 F7")! == (.play, nil, .down))
        #expect(id("B0 7B 05")! == (.jogWheel, nil, .value(5)))
        #expect(id("91 05 7F") == nil)                              // another MIDI channel is another device
        #expect(ConsoleMap.mode3(channel: 1).identify(bytes("91 05 7F"))?.control == .sel(5))
    }

    @Test func everySELAndFaderHasAnLED() {
        #expect(ConsoleMap.ledNote(.sel(24)) == 24 && ConsoleMap.ledNote(.button(8)) == 0x74 && ConsoleMap.ledNote(.fader(3)) == nil)
    }
}

/// The Bridge against what the owner's Bome project does, rule by rule (vectors made by midi/bmtp_vectors.py).
@Suite struct BridgeAgainstBomeTests {
    private func fresh() -> ProToolsBridge { ProToolsBridge() }

    @Test func consoleToHUI() throws {
        let v = try Vectors.load()
        #expect(v.toHUI.count > 100)
        var failures: [String] = []
        for t in v.toHUI {
            let b = fresh()
            var input = bytes(t.in)
            if input.count == 3, input[0] & 0xF0 == 0x80 { _ = b.receiveFromConsole([0x90 | (input[0] & 0x0F), input[1], 0x7F], now: 0) }   // a release follows a press
            else if input.count == 3, input[0] & 0xF0 == 0x90, input[2] == 0 { input[2] = 0x00 }
            let out = b.receiveFromConsole(input, now: 0)
            let want = t.out.map { BridgeOutput.hui(device: $0.device, bytes: bytes($0.bytes)) }
            if out != want { failures.append("\(t.rule): in \(t.in), got \(out), wanted \(want)") }
        }
        #expect(failures.isEmpty, "\(failures.count) differences, first: \(failures.first ?? "")")
    }

    @Test func huiToConsole() throws {
        let v = try Vectors.load()
        #expect(v.toConsole.count > 50)
        var failures: [String] = []
        for t in v.toConsole {
            let b = fresh()
            var last: [BridgeOutput] = []
            for m in midiMessages(bytes(t.in)) { last = b.receiveFromHUI(device: t.device, m) }
            if last != [.console(bytes: bytes(t.out))] { failures.append("\(t.rule): in \(t.in), got \(last), wanted \(t.out)") }
        }
        #expect(failures.isEmpty, "\(failures.count) differences, first: \(failures.first ?? "")")
    }
}

@Suite struct BridgeBehaviourTests {
    private func send(_ b: ProToolsBridge, _ s: String, now: TimeInterval = 0) -> [BridgeOutput] { b.receiveFromConsole(bytes(s), now: now) }

    @Test func faderTouchLastsUntilTheFaderRests() {
        let b = ProToolsBridge()
        let first = send(b, "B0 03 40", now: 0)
        #expect(first == [.hui(device: 0, bytes: bytes("B0 0F 02 B0 2F 40 B0 02 40 B0 22 00"))])
        let second = send(b, "B0 03 41", now: 0.3)
        #expect(second == [.hui(device: 0, bytes: bytes("B0 02 41 B0 22 00"))])           // still touching: value only
        #expect(b.tick(now: 0.7) == [])                                                  // 0.4 s since the last move
        #expect(b.tick(now: 0.95) == [.hui(device: 0, bytes: bytes("B0 0F 02 B0 2F 00"))])
        #expect(b.tick(now: 5) == [])
    }

    @Test func faderBanksAreThreeDevices() {
        let b = ProToolsBridge()
        #expect(send(b, "B0 18 10") == [.hui(device: 2, bytes: bytes("B0 0F 07 B0 2F 40 B0 07 10 B0 27 00"))])
    }

    @Test func modeButtonsChangeWhatTheShiftedSwitchesDo() {
        let b = ProToolsBridge()
        #expect(send(b, "90 23 7F") == [.hui(device: 0, bytes: bytes("B0 0F 00 B0 2F 43"))])                  // SEL 1 shifted: solo
        _ = send(b, "80 23 00")
        let leds = send(b, "90 6E 7F")                                                                          // button 2: the shifted switches mute
        #expect(leds.contains(.console(bytes: bytes("90 6E 7F"))) && leds.contains(.console(bytes: bytes("80 6D 00"))))
        #expect(send(b, "90 23 7F") == [.hui(device: 0, bytes: bytes("B0 0F 00 B0 2F 42"))])
        _ = send(b, "80 23 00")
        _ = send(b, "90 6F 7F")                                                                                 // button 3: record ready
        #expect(send(b, "90 23 7F") == [.hui(device: 0, bytes: bytes("B0 0F 00 B0 2F 47"))])
    }

    @Test func aReleaseFollowsItsPressEvenIfTheLayerChanged() {
        let b = ProToolsBridge()
        _ = send(b, "90 23 7F")                                                // solo pressed
        _ = send(b, "90 6E 7F")                                                // the shifted layer becomes mute while it is held
        #expect(send(b, "80 23 00") == [.hui(device: 0, bytes: bytes("B0 0F 00 B0 2F 03"))])        // released as solo
    }

    @Test func swapLayersMakesThePlainSwitchesSolo() {
        let b = ProToolsBridge()
        _ = send(b, "90 70 7F")                                                // button 4
        #expect(send(b, "90 01 7F") == [.hui(device: 0, bytes: bytes("B0 0F 00 B0 2F 43"))])        // SEL 1 plain: solo now
        _ = send(b, "80 01 00")
        #expect(send(b, "90 23 7F") == [.hui(device: 0, bytes: bytes("B0 0F 00 B0 2F 41"))])        // shifted: select
    }

    @Test func theTwoBanksOfSELLightsAreWrittenAndShiftIsLeftToTheConsole() {
        let b = ProToolsBridge()
        _ = b.startup()
        func light(_ zone: String, _ value: String) -> [BridgeOutput] { b.receiveFromHUI(device: 0, bytes("B0 0C \(zone)")) + b.receiveFromHUI(device: 0, bytes("B0 2C \(value)")) }
        #expect(light("01", "41") == [.console(bytes: bytes("90 02 7F"))])                    // strip 2 selected: plain bank, note 0x02
        #expect(light("01", "43") == [.console(bytes: bytes("90 24 7F"))])                    // strip 2 solo: shifted bank, note 0x22 + 2
        #expect(light("01", "03") == [.console(bytes: bytes("80 24 00"))])
        #expect(light("01", "42") == [])                                                       // mute: not on a layer now
        #expect(send(b, "90 6C 7F") == [] && send(b, "80 6C 00") == [])                       // Shift changes no light by itself
        _ = send(b, "90 6E 7F"); _ = send(b, "80 6E 00")                                       // button 2: the shifted layer is mute
        #expect(b.shiftLayer == .mute)
        #expect(light("02", "42") == [.console(bytes: bytes("90 25 7F"))])                    // strip 3 muted: shifted bank
    }

    @Test func afterTheSwapButtonsOneToThreeChooseWhatPlainSELDoes() {
        let b = ProToolsBridge()
        _ = send(b, "90 70 7F"); _ = send(b, "80 70 00")                       // button 4: Shift+SEL selects, SEL does the choice (solo)
        #expect(b.plainLayer == .solo && b.shiftLayer == .select)
        let out = send(b, "90 6E 7F")                                           // button 2: the choice becomes mute
        #expect(b.plainLayer == .mute && b.shiftLayer == .select)
        #expect(out.contains(.console(bytes: bytes("90 6E 7F"))) && out.contains(.console(bytes: bytes("80 6D 00"))))        // button 2 lit, button 1 dark
        #expect(send(b, "90 01 7F") == [.hui(device: 0, bytes: bytes("B0 0F 00 B0 2F 42"))])                                // SEL 1 mutes
        _ = send(b, "80 01 00"); _ = send(b, "90 70 7F")                         // button 4 again: back to select, with Shift+SEL = mute
        #expect(b.plainLayer == .select && b.shiftLayer == .mute)
    }

    @Test func jogStepsAndScrub() {
        let b = ProToolsBridge()
        #expect(send(b, "B0 7B 05") == [.hui(device: 0, bytes: bytes("B0 0F 0E B0 2F 42 B0 0F 0E B0 2F 02"))])
        let leds = send(b, "90 43 7F")                                         // shifted ST1 toggles scrub and darkens the jog LEDs
        #expect(leds == [.console(bytes: bytes("80 43 00")), .console(bytes: bytes("80 21 00"))])
        #expect(b.scrub)
        #expect(send(b, "B0 7B 05") == [.hui(device: 0, bytes: bytes("B0 0D 45"))])
        #expect(send(b, "B0 7B 64") == [.hui(device: 0, bytes: bytes("B0 0D 1B"))])
    }

    @Test func rebindingAControl() {
        var c = ProToolsConfig.standard
        c.set(.huiPulse(zone: 0x0D, port: 5), .arrowCentre)                    // centre of the keypad: Scrub
        c.set(.none, .button(7))
        let b = ProToolsBridge(config: c)
        #expect(send(b, "90 77 7F") == [.hui(device: 0, bytes: bytes("B0 0F 0D B0 2F 45 B0 0F 0D B0 2F 05"))])
        #expect(send(b, "90 73 7F") == [])
    }

    @Test func softwareShiftLayerForControlsWithoutAShiftedCode() {
        var c = ProToolsConfig.standard
        c.set(.huiPulse(zone: 0x0E, port: 1), .arrowUp, .shift)
        let b = ProToolsBridge(config: c)
        _ = send(b, "90 6C 7F")                                                // Shift held
        #expect(send(b, "90 75 7F") == [.hui(device: 0, bytes: bytes("B0 0F 0E B0 2F 41 B0 0F 0E B0 2F 01"))])
        _ = send(b, "90 75 00"); _ = send(b, "80 6C 00")
        #expect(send(b, "90 75 7F") == [.hui(device: 0, bytes: bytes("B0 0F 0D B0 2F 44"))])        // back to the plain layer
    }

    @Test func shiftedSELFollowsTheShiftNoteOfMode3() {                        // seen on the console: SEL 1 sends 90 01 with or without Shift
        let b = ProToolsBridge()
        #expect(send(b, "90 01 7F") == [.hui(device: 0, bytes: bytes("B0 0F 00 B0 2F 41"))])      // select
        _ = send(b, "80 01 00")
        _ = send(b, "90 6C 7F")
        #expect(send(b, "90 01 7F") == [.hui(device: 0, bytes: bytes("B0 0F 00 B0 2F 43"))])      // solo
        _ = send(b, "80 6C 00")                                                // Shift released before the SEL switch
        #expect(send(b, "80 01 00") == [.hui(device: 0, bytes: bytes("B0 0F 00 B0 2F 03"))])      // the release matches the press
    }

    @Test func keyboardShortcutAndPings() {
        let b = ProToolsBridge()
        #expect(send(b, "90 71 7F") == [.key(KeyShortcut(key: "f", shift: true))])
        #expect(send(b, "90 71 00") == [])
        #expect(b.receiveFromHUI(device: 1, bytes("90 00 00")) == [.hui(device: 1, bytes: bytes("90 00 7F"))])
        #expect(send(b, "9F 00 7F").count == 3)
    }

    @Test func aSecondSELBeforeTheReleaseReplacesTheSelection() {
        let b = ProToolsBridge()
        #expect(send(b, "90 01 7F") == [.hui(device: 0, bytes: bytes("B0 0F 00 B0 2F 41"))])
        let second = send(b, "90 02 7F")                                                            // finger still on SEL 1
        #expect(second == [.hui(device: 0, bytes: bytes("B0 0F 00 B0 2F 01")), .hui(device: 0, bytes: bytes("B0 0F 01 B0 2F 41"))])
        #expect(send(b, "80 01 00") == [])                                                           // already released
        #expect(send(b, "80 02 00") == [.hui(device: 0, bytes: bytes("B0 0F 01 B0 2F 01"))])
        let held = ProToolsBridge()                                                                   // a SEL held on purpose lets the next one add: multi-select
        _ = held.receiveFromConsole(bytes("90 01 7F"), now: 0)
        #expect(held.receiveFromConsole(bytes("90 02 7F"), now: 0.5) == [.hui(device: 0, bytes: bytes("B0 0F 01 B0 2F 41"))])
        var c = ProToolsConfig.standard; c.overlapSelects = true                                      // HUI's own rule: adds to the selection
        let add = ProToolsBridge(config: c)
        _ = add.receiveFromConsole(bytes("90 01 7F"), now: 0)
        #expect(add.receiveFromConsole(bytes("90 02 7F"), now: 0) == [.hui(device: 0, bytes: bytes("B0 0F 01 B0 2F 41"))])
    }

    @Test func theConsolesRepeatedSELPressIsDropped() {                           // seen on the hardware: SEL 3 arrives with SEL 1, pressed before
        let b = ProToolsBridge()
        _ = send(b, "90 01 7F", now: 10); _ = send(b, "80 01 00", now: 10.1)
        #expect(send(b, "90 03 7F", now: 11) == [.hui(device: 0, bytes: bytes("B0 0F 02 B0 2F 41"))])
        #expect(send(b, "90 01 7F", now: 11.001) == [])                                              // the echo of the SEL before
        #expect(send(b, "80 03 00", now: 11.1) == [.hui(device: 0, bytes: bytes("B0 0F 02 B0 2F 01"))])
        #expect(send(b, "80 01 00", now: 11.1) == [])
        _ = send(b, "90 02 7F", now: 12)
        #expect(send(b, "90 02 7F", now: 12.001) == [])                                              // the same note twice
        #expect(send(b, "90 01 7F", now: 13) != [])                                                  // a real press later goes through
    }

    @Test func ledsAreSentOnceAndRememberedAcrossLayers() {
        let b = ProToolsBridge()
        func light(_ zone: String, _ value: String) -> [BridgeOutput] { b.receiveFromHUI(device: 0, bytes("B0 0C \(zone)")) + b.receiveFromHUI(device: 0, bytes("B0 2C \(value)")) }
        _ = b.startup()
        #expect(light("01", "41") == [.console(bytes: bytes("90 02 7F"))])    // select light of strip 2
        #expect(light("01", "41") == [])                                   // already lit
        #expect(light("01", "43") == [.console(bytes: bytes("90 24 7F"))])    // solo light: the shifted bank, note 0x22 + 2
        #expect(light("01", "43") == [])
        let all = light("0E", "44")                                       // play light
        #expect(all == [.console(bytes: bytes("B1 78 7F"))])
        #expect(light("0E", "44") == [])
        let swapped = b.receiveFromConsole(bytes("90 70 7F"), now: 0)                                            // button 4 swaps the layers
        #expect(swapped.contains(.console(bytes: bytes("90 02 7F"))))                                            // the plain bank now shows solo (strip 2 lit)
        #expect(swapped.contains(.console(bytes: bytes("90 24 7F"))))                                            // the shifted bank shows select (strip 2 lit)
    }

    @Test func aRepeatedFaderPositionIsSentOnce() {
        let b = ProToolsBridge()
        #expect(b.receiveFromHUI(device: 0, bytes("B0 03 35")) == [])                            // high half alone: not a position yet
        let first = b.receiveFromHUI(device: 0, bytes("B0 23 00"))
        #expect(first == [.console(bytes: bytes("B0 04 35"))])
        #expect(b.receiveFromHUI(device: 0, bytes("B0 03 35")) == [])
        #expect(b.receiveFromHUI(device: 0, bytes("B0 23 40")) == [])                            // same position, other low half
        #expect(b.receiveFromHUI(device: 0, bytes("B0 03 36")) == [])
        #expect(b.receiveFromHUI(device: 0, bytes("B0 23 00")) == [.console(bytes: bytes("B0 04 36"))])
    }

    @Test func fadersFromProToolsYieldToAHandOnThem() {
        let b = ProToolsBridge()
        _ = send(b, "B0 02 10", now: 0)                                        // the hand is on fader 2
        #expect(b.receiveFromHUI(device: 0, bytes("B0 01 33")) == [])
        #expect(b.receiveFromHUI(device: 0, bytes("B0 21 00")) == [])
        _ = b.tick(now: 1)
        _ = b.receiveFromHUI(device: 0, bytes("B0 01 33"))
        #expect(b.receiveFromHUI(device: 0, bytes("B0 21 00")) == [.console(bytes: bytes("B0 02 33"))])
    }

    @Test func startupLights() {
        let out = ProToolsBridge().startup()
        #expect(out.contains(.console(bytes: bytes("90 6D 7F"))) && out.contains(.console(bytes: bytes("80 6E 00"))) && out.contains(.console(bytes: bytes("80 6F 00"))))
        #expect(out.contains(.console(bytes: bytes("90 43 7F"))) && out.contains(.console(bytes: bytes("90 21 7F"))))
    }

    @Test func configRoundTripsThroughJSON() throws {
        let c = ProToolsConfig.standard
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(ProToolsConfig.self, from: data) == c)
    }
}

private final class FakeCard: CardMIDI {
    var sent: [(Int, [UInt8])] = []
    var onReceive: ((Int, [UInt8]) -> Void)?
    func send(port: Int, bytes: [UInt8]) { sent.append((port, bytes)) }
    func receive(_ port: Int, _ b: [UInt8]) { onReceive?(port, b) }
}

private final class FakeVirtual: VirtualMIDI {
    var toApps: [(MIDIEndpoint, [UInt8])] = []
    var onFromApplications: ((MIDIEndpoint, [UInt8]) -> Void)?
    func sendToApplications(_ e: MIDIEndpoint, bytes: [UInt8]) { toApps.append((e, bytes)) }
    func fromApp(_ e: MIDIEndpoint, _ b: [UInt8]) { onFromApplications?(e, b) }
}

@Suite struct ConsoleShaperTests {
    @Test func aQuietLinkIsNotDelayed() {
        let sh = ConsoleShaper()
        #expect(sh.push(bytes("B0 01 40"), now: 0) == [bytes("B0 01 40")])                       // sent at once
        #expect(sh.push(bytes("90 02 7F"), now: 0.01) == [bytes("90 02 7F")])
        #expect(sh.queued == 0)
    }

    @Test func aFloodWaitsAndStaysUnderTheBudget() {
        let sh = ConsoleShaper(bytesPerSecond: 1000, burstBytes: 30)
        var sent = 0
        for n in 0..<200 { sent += sh.push([0x90 | UInt8(n / 100), UInt8(n % 100), 0x7F], now: 0).count * 3 }     // 200 different lights at the same instant (600 bytes)
        #expect(sent <= 33 && sh.queued > 150)                                                     // only the burst went out
        var t = 0.0
        while sh.queued > 0 { t += 0.02; sent += sh.drain(now: t).count * 3 }
        #expect(sent >= 400)                                                                       // the rest follows at the allowed rate
        #expect(t >= 0.4 && t < 1.2)                                                               // 600 bytes at 1000 B/s: about half a second
        #expect(sh.dropped == 0)
    }

    @Test func aMessageReplacedBeforeItIsSentIsSentOnce() {
        let sh = ConsoleShaper(bytesPerSecond: 100, burstBytes: 3)
        _ = sh.push(bytes("B0 01 10"), now: 0)                                                     // uses the burst
        #expect(sh.push(bytes("B0 02 20"), now: 0).isEmpty)                                        // waits
        #expect(sh.push(bytes("B0 02 30"), now: 0).isEmpty && sh.push(bytes("B0 02 40"), now: 0).isEmpty)
        #expect(sh.coalesced == 2 && sh.queued == 1)
        #expect(sh.drain(now: 1) == [bytes("B0 02 40")])                                           // only the last position
        _ = sh.push(bytes("90 05 7F"), now: 2); _ = sh.push(bytes("90 06 7F"), now: 2)
        _ = sh.push(bytes("90 06 7F"), now: 2); _ = sh.push(bytes("80 06 00"), now: 2)           // a light on then off before it left
        #expect(sh.drain(now: 3).contains(bytes("80 06 00")) && !sh.drain(now: 3).contains(bytes("90 06 7F")))
    }

    @Test func theQueueIsBounded() {
        let sh = ConsoleShaper(bytesPerSecond: 1, burstBytes: 0, maxQueued: 10)
        for n in 0..<30 { _ = sh.push([0xF0, UInt8(n), 0xF7], now: 0) }                           // messages without key
        #expect(sh.queued == 10 && sh.dropped == 20)
    }
}

@Suite struct MIDIHostTests {
    private func make(_ mode: MIDIMode) -> (MIDIHost, FakeCard, FakeVirtual) {
        let c = FakeCard(), v = FakeVirtual()
        var s = MIDISettings(); s.mode = mode
        let h = MIDIHost(card: c, virtual: v, settings: s)
        return (h, c, v)
    }

    @Test func legacyPassesBytesThroughBothWays() {
        let (h, c, v) = make(.legacy)
        c.receive(1, bytes("90 05 7F"))
        #expect(v.toApps.count == 1 && v.toApps[0].0 == .legacy(1) && v.toApps[0].1 == bytes("90 05 7F"))
        v.fromApp(.legacy(2), bytes("B0 07 40"))
        #expect(c.sent.count == 1 && c.sent[0].0 == 2 && c.sent[0].1 == bytes("B0 07 40"))
        v.fromApp(.hui(0), bytes("90 00 00"))                              // the other mode's endpoints are silent
        #expect(c.sent.count == 1 && v.toApps.count == 1)
        _ = h
    }

    @Test func protoolsTranslatesAcrossSplitBuffers() {
        let (h, c, v) = make(.protools)
        c.receive(0, bytes("B0 03"))                                        // a message arrives in two pieces
        #expect(v.toApps.isEmpty)
        c.receive(0, bytes("40"))
        #expect(v.toApps.count == 1 && v.toApps[0].0 == .hui(0) && v.toApps[0].1 == bytes("B0 0F 02 B0 2F 40 B0 02 40 B0 22 00"))
        c.receive(1, bytes("B0 03 41"))                                     // not the console's port: ignored
        #expect(v.toApps.count == 1)
        _ = h
    }

    @Test func protoolsAnswersThePingAndFeedsLEDsBack() {
        let (h, c, v) = make(.protools)
        v.fromApp(.hui(2), bytes("90 00 00"))
        #expect(v.toApps.last?.0 == .hui(2) && v.toApps.last?.1 == bytes("90 00 7F"))
        v.fromApp(.hui(0), bytes("B0 0C 00 B0 2C 41"))                      // HUI select light of strip 1
        #expect(c.sent.last?.0 == 0 && c.sent.last?.1 == bytes("90 01 7F"))
        _ = h
    }

    @Test func modeChangeLightsTheConsole() {
        let (h, c, _) = make(.legacy)
        #expect(c.sent.isEmpty)
        var s = h.settings; s.mode = .protools
        h.apply(s, now: 0)
        #expect(c.sent.contains { $0.1 == bytes("90 6D 7F") })
    }

    @Test func touchReleaseComesFromTick() {
        let (h, c, v) = make(.protools)
        c.receive(0, bytes("B0 01 10"))
        let before = v.toApps.count
        h.tick(now: ProcessInfo.processInfo.systemUptime + 0.1)
        #expect(v.toApps.count == before)
        h.tick(now: ProcessInfo.processInfo.systemUptime + 5)
        #expect(v.toApps.last?.1 == bytes("B0 0F 00 B0 2F 00"))
    }

    @Test func keystrokesGoToTheSink() {
        let (h, c, _) = make(.protools)
        var got: [KeyShortcut] = []
        h.onKeystroke = { got.append($0) }
        c.receive(0, bytes("90 71 7F"))
        #expect(got == [KeyShortcut(key: "f", shift: true)])
    }

    @Test func settingsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gsr-midi-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var s = MIDISettings(); s.mode = .protools; s.consolePort = 2
        s.protools.set(.none, .button(5))
        #expect(s.save(to: url))
        #expect(MIDISettings.load(from: url) == s)
        #expect(MIDISettings.load(from: url.appendingPathExtension("missing")) == MIDISettings())
    }
}

import CoreMIDI

@Suite struct CoreMIDIVirtualTests {
    private static func endpoint(named name: String, destination: Bool) -> MIDIEndpointRef? {
        let n = destination ? MIDIGetNumberOfDestinations() : MIDIGetNumberOfSources()
        for i in 0..<n {
            let e = destination ? MIDIGetDestination(i) : MIDIGetSource(i)
            var cf: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(e, kMIDIPropertyName, &cf) == noErr, let s = cf?.takeRetainedValue() as String?, s == name { return e }
        }
        return nil
    }

    private static func bytes(of list: UnsafePointer<MIDIPacketList>) -> [UInt8] { CoreMIDIVirtual.bytes(in: list) }

    @Test func bytesPassBothWays() throws {
        let q = DispatchQueue(label: "gsr.test.virtual")
        let v = CoreMIDIVirtual(queue: q, prefix: "GSR TEST", idBase: 0x47535A00)
        try #require(v.failure == nil, "\(v.failure ?? "")")
        let src = try #require(Self.endpoint(named: "GSR TEST HUI 2", destination: false))
        let dst = try #require(Self.endpoint(named: "GSR TEST MIDI 3", destination: true))

        var client = MIDIClientRef(); MIDIClientCreate("gsr test client" as CFString, nil, nil, &client)
        let got = NSLock(); nonisolated(unsafe) var received: [UInt8] = []
        var inPort = MIDIPortRef()
        MIDIInputPortCreateWithBlock(client, "in" as CFString, &inPort) { list, _ in
            let b = Self.bytes(of: list); got.lock(); received += b; got.unlock()
        }
        MIDIPortConnectSource(inPort, src, nil)

        v.sendToApplications(.hui(1), bytes: [0x90, 0x00, 0x7F])
        Thread.sleep(forTimeInterval: 0.3)
        got.lock(); let r = received; got.unlock()
        #expect(r == [0x90, 0x00, 0x7F], "got \(r)")

        // the other direction: an application sends to "GSR TEST MIDI 3"
        let heard = NSLock(); nonisolated(unsafe) var seen: [(MIDIEndpoint, [UInt8])] = []
        v.onFromApplications = { e, b in heard.lock(); seen.append((e, b)); heard.unlock() }
        var outPort = MIDIPortRef(); MIDIOutputPortCreate(client, "out" as CFString, &outPort)
        var buf = [UInt8](repeating: 0, count: 256)
        buf.withUnsafeMutableBytes { raw in
            let l = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
            let p = MIDIPacketListInit(l)
            _ = MIDIPacketListAdd(l, 256, p, 0, 3, [0xB0, 0x07, 0x40])
            MIDISend(outPort, dst, l)
        }
        Thread.sleep(forTimeInterval: 0.3)
        heard.lock(); let s = seen; heard.unlock()
        #expect(s.count == 1 && s[0].0 == .legacy(2) && s[0].1 == [0xB0, 0x07, 0x40], "got \(s)")
        // a list with several packets and a long one (what Pro Tools sends in a burst): all of it must arrive, in order
        heard.lock(); seen.removeAll(); heard.unlock()
        let long = [0xF0] + [UInt8](repeating: 0x55, count: 598) + [0xF7]                  // a system exclusive message of 600 bytes
        var big = [UInt8](repeating: 0, count: 4096)
        big.withUnsafeMutableBytes { raw in
            let l = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
            var p = MIDIPacketListInit(l)
            p = MIDIPacketListAdd(l, 4096, p, 0, 3, [0xB0, 0x01, 0x10])
            p = MIDIPacketListAdd(l, 4096, p, 0, 3, [0xB0, 0x02, 0x20])
            p = MIDIPacketListAdd(l, 4096, p, 0, long.count, long)
            p = MIDIPacketListAdd(l, 4096, p, 0, 3, [0xB0, 0x03, 0x30])
            MIDISend(outPort, dst, l)
        }
        Thread.sleep(forTimeInterval: 0.3)
        heard.lock(); let all = seen.flatMap { $0.1 }; heard.unlock()
        #expect(all == [0xB0, 0x01, 0x10, 0xB0, 0x02, 0x20] + long + [0xB0, 0x03, 0x30], "got \(all.count) bytes")
        MIDIPortDispose(inPort); MIDIPortDispose(outPort); MIDIClientDispose(client)
    }
}

@Suite struct SurfaceLayoutTests {
    @Test func everyControlOfTheConsoleIsDrawnOnce() {
        let map = ConsoleMap.mode3()
        let drawn = SurfaceLayout.all.map(\.control)
        #expect(Set(drawn).count == drawn.count, "a control is drawn twice")
        let known = Set(map.table.values.map(\.control))
        #expect(known.subtracting(Set(drawn)).isEmpty, "not drawn: \(known.subtracting(Set(drawn)).map(\.id).sorted())")
    }

    @Test func nothingOverlapsAndEverythingIsInsideItsBlock() {
        for (cells, size) in [(SurfaceLayout.strips, SurfaceLayout.stripsSize), (SurfaceLayout.controls, SurfaceLayout.controlsSize)] {
            for (i, a) in cells.enumerated() {
                #expect(a.x >= 0 && a.y >= 0 && a.x + a.w <= size.width + 1e-9 && a.y + a.h <= size.height + 1e-9, "\(a.control) outside its block")
                for b in cells[(i + 1)...] {
                    let overlap = a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
                    #expect(!overlap, "\(a.control) overlaps \(b.control)")
                }
            }
        }
    }

    @Test func titlesAndBindableControls() {
        #expect(ConsoleControl.sel(5).title == "SEL 5" && ConsoleControl.arrowCentre.title == "Keypad centre")
        #expect(ConsoleControl.button(3).isBindable && !ConsoleControl.fader(3).isBindable && !ConsoleControl.jogWheel.isBindable)
    }

    @Test func learnedCodesWinOverTheDocumentedOnes() {
        var s = MIDISettings()
        s.customCodes = [CustomCode(pattern: .note(channel: 0, note: 0x50), control: .jogSwitch, layer: nil)]
        #expect(s.consoleMap().identify(bytes("90 50 7F"))?.control == .jogSwitch)
        #expect(s.consoleMap().identify(bytes("90 7A 7F"))?.control == .jogSwitch)          // the documented code is still there
        let round = try? JSONDecoder().decode(MIDISettings.self, from: JSONEncoder().encode(s))
        #expect(round == s)
    }
}

@Suite struct EditingTests {
    @Test func learnFindsTheControlOrReportsTheCode() {
        var s = MIDISettings(); s.customCodes = []
        let m = s.consoleMap()
        #expect(m.learn(bytes("90 27 7F")) == .known(.sel(5), .shift))
        #expect(m.learn(bytes("80 27 00")) == .ignored)
        #expect(m.learn(bytes("90 55 7F")) == .unknown(.note(channel: 0, note: 0x55)))
        #expect(m.learn([0xF8]) == .ignored)
        #expect(ConsoleMap.describe(.note(channel: 0, note: 0x23)) == "note 0x23, channel 1")
        let codes = m.codes(of: .sel(1)).map { ConsoleMap.describe($0.0) }
        #expect(codes == ["note 0x01, channel 1", "note 0x23, channel 1"])
    }

    @Test func everyKindStartsAsItsOwnKindAndSummarises() {
        for k in ActionKind.allCases { #expect(Action.starting(k).kind == k) }
        #expect(Action.hui(zone: 0x0E, port: 4).summary == "Transport: play")
        #expect(Action.hui(zone: 0x1F, port: 2).summary == "HUI zone 0x1F port 2")
        #expect(Action.key(KeyShortcut(key: "f", shift: true)).summary == "key ⇧F")
        #expect(Action.kinds(for: .sel(3)).contains(.channel) && !Action.kinds(for: .button(1)).contains(.channel))
    }
}

@Suite struct CatalogTests {
    @Test func noTwoEntriesShareASwitch() {
        let targets = HUICatalog.entries.map(\.target)
        #expect(Set(targets).count == targets.count)
        #expect(Set(HUICatalog.entries.map(\.title)).count == HUICatalog.entries.count)
    }

    @Test func theBomeSwitchesAreVerifiedAndTheOthersAreFlagged() {
        #expect(HUICatalog.isVerified(HUISwitch(zone: 0x0E, port: 4)))             // play
        #expect(!HUICatalog.isVerified(HUISwitch(zone: 0x0A, port: 0)))            // channel left: not tried
        #expect(!HUICatalog.isVerified(HUISwitch(zone: 0x1F, port: 7)))            // unknown to the catalog
        #expect(HUICatalog.entries.filter(\.verified).count == 19)
    }

    @Test func userSwitchesJoinTheCatalogWithoutHidingKnownOnes() {
        let mine = [UserSwitch(name: "My undo", zone: 0x15, port: 3), UserSwitch(name: "Not play", zone: 0x0E, port: 4)]
        let all = HUICatalog.all(user: mine)
        #expect(all.contains { $0.title == "My undo" && $0.group == "Mine" })
        #expect(!all.contains { $0.title == "Not play" })                          // a known switch keeps its own name
        #expect(HUICatalog.title(of: HUISwitch(zone: 0x15, port: 3), user: mine) == "My undo")
        #expect(Action.hui(zone: 0x0E, port: 4).summary == "Transport: play")
    }

    @Test func proToolsKeyPresetsAreUsableKeys() {
        for p in ProToolsKeys.presets { #expect(KeyInjector.keyCode(p.shortcut.key) != nil, "unknown key in preset \(p.title)") }
        #expect(Set(ProToolsKeys.presets.map(\.title)).count == ProToolsKeys.presets.count)
        #expect(ProToolsKeys.title(of: KeyShortcut(key: "z", command: true)) == "Undo")
        #expect(Action.key(KeyShortcut(key: "z", command: true)).summary.hasPrefix("Undo: key"))
    }

    @Test func settingsKeepTheUserSwitches() throws {
        var s = MIDISettings(); s.userSwitches = [UserSwitch(name: "x", zone: 3, port: 4)]
        #expect(try JSONDecoder().decode(MIDISettings.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test func hostSendsToTheHUIPortsOnDemand() {
        let c = FakeCard(), v = FakeVirtual()
        let h = MIDIHost(card: c, virtual: v, settings: MIDISettings())
        h.sendToHUI(device: 1, bytes: HUI.switchMessage(zone: 9, port: 2, pressed: true) + HUI.switchMessage(zone: 9, port: 2, pressed: false))
        #expect(v.toApps.count == 1 && v.toApps[0].0 == .hui(1) && v.toApps[0].1.count == 12)
        h.sendToHUI(device: 5, bytes: [0x90])
        #expect(v.toApps.count == 1)                                                // no such device
    }
}
