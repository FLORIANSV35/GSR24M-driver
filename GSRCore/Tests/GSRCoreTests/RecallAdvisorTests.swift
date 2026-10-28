import Foundation
import Testing
@testable import GSRCore

@Suite struct RecallAdvisorTests {
    private func deltas(_ d: [EQGuide.Knob: Double]) -> [Double] { EQGuide.Knob.allCases.map { d[$0] ?? 0 } }
    private func gap(_ a: [EQGuide.Knob: Double]) -> EQGuide.Guidance {
        EQGuide.Guidance(contributions: EQGuide.Knob.allCases.map { abs(a[$0] ?? 0) * 0.1 }, amounts: deltas(a))
    }

    @Test func theFirstPassGoesGainsFrequenciesThenQ() {
        var adv = RecallAdvisor()
        var d: [EQGuide.Knob: Double] = [.hf: 5, .hmfGain: -4, .lmfGain: 3, .lf: -2, .hmfFreq: 0.5, .lmfFreq: -0.4, .hmfQ: 0.6, .lmfQ: -0.5]
        var order: [EQGuide.Knob] = []
        for step in 0..<12 {
            adv.update(now: Double(step), accuracy: 40, deltas: deltas(d), gap: gap(d), active: nil, activeRemaining: nil)
            guard let s = adv.suggested, adv.phase == .firstPass else { break }
            if order.last != s.knob { order.append(s.knob) }
            #expect(adv.shown(s.knob) == s.amount)                                    // arrows only on the knob of the moment
            #expect(EQGuide.Knob.allCases.filter { adv.shown($0) != nil }.count == 1)
            d[s.knob] = 0                                                              // the operator sets it
        }
        #expect(order == RecallAdvisor.passOrder)
        #expect(adv.phase == .refine)                                                  // the pass is over
    }

    @Test func theFirstPassStopsAt65Percent() {
        var adv = RecallAdvisor()
        let d: [EQGuide.Knob: Double] = [.hf: 5, .lmfFreq: 0.5]
        adv.update(now: 0, accuracy: 50, deltas: deltas(d), gap: gap(d), active: nil, activeRemaining: nil)
        #expect(adv.phase == .firstPass)
        adv.update(now: 1, accuracy: 66, deltas: deltas(d), gap: gap(d), active: nil, activeRemaining: nil)
        #expect(adv.phase == .refine)
    }

    @Test func theRefinementLeavesTheQKnobsForLast() {
        var adv = RecallAdvisor()
        var a: [EQGuide.Knob: Double] = [.hmfQ: 0.9, .lmfGain: 1.2, .hmfFreq: 0.3]       // the Q is the largest part, but it waits
        adv.update(now: 0, accuracy: 80, deltas: deltas(a), gap: gap(a), active: nil, activeRemaining: nil)
        #expect(adv.phase == .refine)
        #expect(adv.suggested?.knob != .hmfQ && adv.shown(.hmfQ) == nil)
        #expect(adv.shown(.lmfGain) != nil && adv.shown(.hmfFreq) != nil)                // the open knobs that are not a Q show their arrows
        a[.lmfGain] = 0; a[.hmfFreq] = 0
        adv.update(now: 1, accuracy: 85, deltas: deltas(a), gap: gap(a), active: nil, activeRemaining: nil)
        #expect(adv.suggested?.knob == .hmfQ && adv.shown(.hmfQ) == 0.9)                  // then the Q
        a[.lmfGain] = 1.0                                                                 // a gain drifted out of place: back to the gains
        adv.update(now: 2, accuracy: 85, deltas: deltas(a), gap: gap(a), active: nil, activeRemaining: nil)
        #expect(adv.suggested?.knob == .lmfGain && adv.shown(.hmfQ) == nil)
    }

    @Test func aKnobTurnedAndLeftOutOfPlaceIsSetAside() {
        var adv = RecallAdvisor()
        let a: [EQGuide.Knob: Double] = [.hf: 3, .lf: 2]
        adv.update(now: 0, accuracy: 80, deltas: deltas(a), gap: gap(a), active: nil, activeRemaining: nil)
        let first = adv.suggested?.knob
        adv.update(now: 1, accuracy: 80, deltas: deltas(a), gap: gap(a), active: first, activeRemaining: 3)   // being turned
        adv.update(now: 2, accuracy: 80, deltas: deltas(a), gap: gap(a), active: nil, activeRemaining: nil)    // let go
        #expect(adv.suggested?.knob == first)
        adv.update(now: 6, accuracy: 80, deltas: deltas(a), gap: gap(a), active: nil, activeRemaining: nil)    // 4 s later and still out of place
        #expect(adv.suggested?.knob != first && adv.shown(first!) == nil)
        adv.update(now: 40, accuracy: 80, deltas: deltas(a), gap: gap(a), active: nil, activeRemaining: nil)   // it comes back later
        #expect(adv.shown(first!) != nil)
    }

    @Test func fitDeltasIgnoreTheFrequencyOfAFlatBell() {
        let live = EQSettings(lf: 0, hf: 0, lmf: .init(gain: 0, freq: 200, q: 1), hmf: .init(gain: 6, freq: 2000, q: 1))
        let target = EQSettings(lf: 3, hf: -2, lmf: .init(gain: 5, freq: 100, q: 2), hmf: .init(gain: 4, freq: 3000, q: 1))
        let d = EQGuide.fitDeltas(live: live, target: target)
        #expect(d[EQGuide.Knob.lf.rawValue] == 3 && d[EQGuide.Knob.hf.rawValue] == -2)
        #expect(d[EQGuide.Knob.lmfGain.rawValue] == 5 && d[EQGuide.Knob.lmfFreq.rawValue] == 0 && d[EQGuide.Knob.lmfQ.rawValue] == 0)   // the live bell is flat
        #expect(abs(d[EQGuide.Knob.hmfFreq.rawValue] - log(1.5)) < 1e-9 && d[EQGuide.Knob.hmfGain.rawValue] == -2)
    }

    @Test func typedKnobValuesBecomeTheTarget() {
        var m = ManualEQ()
        m.hf = 4; m.lmfGain = -6; m.lmfFreq = 250; m.lmfQ = 2.0
        let fit = EQSettings(lf: 1, hf: 0, lmf: .init(gain: 0, freq: 120, q: 1), hmf: .init(gain: 3, freq: 2000, q: 1.5))
        let s = m.settings(fallback: fit)
        #expect(s.hf == 4 && s.lf == 1)                                                // what was typed, the rest from the fit
        #expect(s.lmf.gain == -6 && s.lmf.freq == 250)
        #expect(abs(s.lmf.q - EQFit.effectiveQ(knob: 2.0, gain: -6)) < 1e-9)
        #expect(s.hmf == fit.hmf)                                                      // nothing typed for the HM bell
        #expect(abs(EQFit.knobQ(effective: EQFit.effectiveQ(knob: 3.2, gain: 9), gain: 9) - 3.2) < 1e-9)
        #expect(ManualEQ().isEmpty && !m.isEmpty)
        var out = ManualEQ(); out.lmfFreq = 5000; out.hf = 30                          // beyond the sweep and the stops: kept inside
        let c = out.settings(fallback: fit)
        #expect(c.lmf.freq == EQFit.lmfRange.upperBound && c.hf == EQFit.gainLimit)
    }

    @Test func typedValuesAreParsedAndOldCapturesStillLoad() throws {
        #expect(ManualEQ.parseFrequency("1.5k") == 1500 && ManualEQ.parseFrequency("2,5 kHz") == 2500 && ManualEQ.parseFrequency(" 250 Hz ") == 250)
        #expect(ManualEQ.parseFrequency("abc") == nil && ManualEQ.parseFrequency("-3") == nil)
        #expect(ManualEQ.parseNumber("+4,5") == 4.5 && ManualEQ.parseNumber("-3") == -3 && ManualEQ.parseNumber("x") == nil)
        let old = #"{"name":"old","date":"2026-10-01T10:00:00Z","rate":48000,"channels":{}}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        #expect(try dec.decode(EQCapture.self, from: Data(old.utf8)).manual.isEmpty)
        var c = EQCapture(name: "new", rate: 48000); var m = ManualEQ(); m.hf = 2; c.manual["3"] = m
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let back = try dec.decode(EQCapture.self, from: enc.encode(c))
        #expect(back.manual["3"]?.hf == 2)
    }

    @Test func theWholeStripIsKeptAndListed() throws {
        var s = StripSheet()
        #expect(s.isEmpty && s.lines.isEmpty)
        s.line = false; s.gain = 34; s.phantom = true; s.hpf = true; s.aux[0] = 0; s.aux[2] = StripSheet.off; s.pan = -30; s.route12 = true; s.fader = -6; s.mute = false
        let names = s.lines.map(\.name)
        #expect(names == ["Input", "Gain", "+48V", "HPF 100 Hz", "Aux 1", "Aux 3", "Pan", "1-2", "Mute", "Fader"])
        #expect(s.lines.first { $0.name == "Gain" }?.value == "+34 dB" && s.lines.first { $0.name == "Aux 3" }?.value == "off" && s.lines.first { $0.name == "Pan" }?.value == "L 30")
        #expect(StripSheet.parseLevel("off") == StripSheet.off && StripSheet.parseLevel("-6 dB") == -6 && StripSheet.parseLevel("+3,5") == 3.5 && StripSheet.parseLevel("x") == nil)
        var c = EQCapture(name: "n", rate: 48000); c.strips["5"] = s
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        #expect(try dec.decode(EQCapture.self, from: enc.encode(c)).strips["5"] == s)
        #expect(try dec.decode(EQCapture.self, from: Data(#"{"name":"o","date":"2026-10-01T10:00:00Z","rate":48000,"channels":{},"manual":{}}"#.utf8)).strips.isEmpty)
    }

    @Test func theFaderPositionSentByTheConsoleBecomesALevel() {
        #expect(StripSheet.faderDB(midi: 127) == 10 && StripSheet.faderDB(midi: 0) == StripSheet.off)
        let unity = StripSheet.faderMIDI(db: 0)
        #expect(abs(StripSheet.faderDB(midi: unity)) < 0.5 && unity > 100 && unity < 115)       // unity sits near the top of the travel
        var last = -1000.0
        for v in stride(from: 0, through: 127, by: 1) { let d = StripSheet.faderDB(midi: v); #expect(d >= last); last = d }   // a higher position is never a lower level
        #expect(abs(StripSheet.faderDB(midi: StripSheet.faderMIDI(db: -20)) + 20) < 0.7)
        var s = StripSheet(); s.fader = -6; s.faderMIDI = 90
        #expect(s.lines.first { $0.name == "Fader" }?.value == "-6.0 dB (MIDI 90)")
    }
}
