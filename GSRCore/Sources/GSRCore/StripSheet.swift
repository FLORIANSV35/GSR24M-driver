import Foundation

/// Every setting of a mono input channel of the GS-R24 that is typed in by hand while capturing (the EQ knobs are in `ManualEQ`): the other controls
/// have no effect that the EQ measurement can see. The sheet is kept with the capture and shown again when the channel is recalled, as a list to
/// set and tick off. Everything is optional: only what was typed is kept. From the user guide, p.11 to 15 and the block diagram p.10.
public struct StripSheet: Codable, Equatable {
    public var line: Bool?                   // true: the Line input is selected, false: the microphone
    public var gain: Double?                 // dB: +6 to +60 on the microphone, -14 to +40 on the line input
    public var phantom: Bool?, polarity: Bool?, hpf: Bool?, eqIn: Bool?
    public var aux: [Double?] = Array(repeating: nil, count: 6)      // aux 1 to 6, dB (-100 = off, +6 at the top, 0 at the arrow)
    public var auxPre34: Bool?               // the Pre switch of aux 3 and 4
    public var pan: Double?                  // -100 left, 0 centre, +100 right
    public var routeLR: Bool?, routeMono: Bool?, route12: Bool?, route34: Bool?
    public var switchA: Bool?, switchB: Bool?, switchC: Bool?, switchD: Bool?   // interface configuration switches
    public var mute: Bool?
    public var fader: Double?                // dB, -100 = fully down
    public var faderMIDI: Int?               // the position of the fader as the console sends it (controller 0 to 127), when it was captured by MIDI
    public init() {}

    public static let off = -100.0

    /// The printed scale of the fader as positions along its travel (0 at the top, 1 at the bottom). Approximate: the MIDI value is the exact position.
    public static let faderMarks: [(db: Double, pos: Double)] = [(10, 0), (0, 0.17), (-10, 0.34), (-20, 0.52), (-30, 0.70), (-40, 0.84), (off, 1)]

    public static func faderPosition(db: Double) -> Double {
        let m = faderMarks, c = min(m[0].db, max(m.last!.db, db))
        for i in 0..<(m.count - 1) where c <= m[i].db && c >= m[i + 1].db {
            return m[i].pos + (m[i].db - c) / (m[i].db - m[i + 1].db) * (m[i + 1].pos - m[i].pos)
        }
        return 1
    }

    public static func faderLevel(position p: Double) -> Double {
        let m = faderMarks, c = min(1, max(0, p))
        for i in 0..<(m.count - 1) where c >= m[i].pos && c <= m[i + 1].pos {
            return m[i].db + (c - m[i].pos) / (m[i + 1].pos - m[i].pos) * (m[i + 1].db - m[i].db)
        }
        return off
    }

    /// The level in dB, as the printed scale reads it, of a fader position sent by the console (127 at the top, 0 at the bottom).
    public static func faderDB(midi v: Int) -> Double { faderLevel(position: 1 - Double(min(127, max(0, v))) / 127) }
    public static func faderMIDI(db: Double) -> Int { Int(((1 - faderPosition(db: db)) * 127).rounded()) }

    public var isEmpty: Bool { self == StripSheet() }

    /// One line per setting that was typed: its name and its value as the operator reads it.
    public var lines: [(name: String, value: String)] {
        var out: [(String, String)] = []
        func sw(_ n: String, _ v: Bool?) { if let v { out.append((n, v ? "on" : "off")) } }
        func db(_ v: Double) -> String { v <= Self.off ? "off" : String(format: "%+.1f dB", v) }
        if let l = line { out.append(("Input", l ? "Line" : "Mic")) }
        if let g = gain { out.append(("Gain", String(format: "%+.0f dB", g))) }
        sw("+48V", phantom); sw("Polarity", polarity); sw("HPF 100 Hz", hpf); sw("EQ IN", eqIn)
        for (i, a) in aux.enumerated() { if let a { out.append(("Aux \(i + 1)", db(a))) } }
        sw("Aux 3-4 Pre", auxPre34)
        if let p = pan { out.append(("Pan", p == 0 ? "centre" : String(format: "%@ %.0f", p < 0 ? "L" : "R", abs(p)))) }
        sw("L-R", routeLR); sw("M", routeMono); sw("1-2", route12); sw("3-4", route34)
        sw("DAW send after EQ IN (A)", switchA); sw("DAW return pre-insert (B)", switchB); sw("DAW return post-EQ (C)", switchC); sw("Fader bypass (D)", switchD)
        sw("Mute", mute)
        if let f = fader { out.append(("Fader", db(f) + (faderMIDI.map { " (MIDI \($0))" } ?? ""))) }
        return out
    }

    /// A level in dB typed by hand: "-6", "+3,5", "off" (fully down).
    public static func parseLevel(_ text: String) -> Double? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if t == "off" || t == "-inf" || t == "inf" || t == "∞" { return off }
        return ManualEQ.parseNumber(t.replacingOccurrences(of: "db", with: ""))
    }
}
