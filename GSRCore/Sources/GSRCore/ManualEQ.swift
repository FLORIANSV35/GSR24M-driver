import Foundation

/// EQ knob positions typed in by hand while capturing, as read on the console: gains in dB, frequencies in Hz, Q on the knob's own scale. Any
/// value can be left out. A capture with these values gives the exact target for the first pass of the recall, where the fit of the curve alone
/// has to guess (several settings can give nearly the same curve).
public struct ManualEQ: Codable, Equatable {
    public var lf: Double?, hf: Double?
    public var lmfGain: Double?, lmfFreq: Double?, lmfQ: Double?
    public var hmfGain: Double?, hmfFreq: Double?, hmfQ: Double?
    public init() {}

    public var isEmpty: Bool { [lf, hf, lmfGain, lmfFreq, lmfQ, hmfGain, hmfFreq, hmfQ].allSatisfy { $0 == nil } }

    /// The settings of the model: what was typed, the rest from `fallback` (the fit of the curve). The Q of the knob becomes the Q the model reads, which
    /// depends on the gain (`EQFit.knobQ` is the other way round). Values are kept inside what the console can do.
    public func settings(fallback f: EQSettings) -> EQSettings {
        func gain(_ v: Double?, _ d: Double) -> Double { min(EQFit.gainLimit, max(-EQFit.gainLimit, v ?? d)) }
        func bell(_ g: Double?, _ fr: Double?, _ q: Double?, _ d: EQSettings.Bell, _ range: ClosedRange<Double>) -> EQSettings.Bell {
            let gn = gain(g, d.gain)
            let freq = min(range.upperBound, max(range.lowerBound, fr ?? d.freq))
            let qe = q.map { EQFit.effectiveQ(knob: $0, gain: gn) } ?? d.q
            return .init(gain: gn, freq: freq, q: min(EQFit.qRange.upperBound, max(EQFit.qRange.lowerBound, qe)))
        }
        return EQSettings(lf: gain(lf, f.lf), hf: gain(hf, f.hf),
                          lmf: bell(lmfGain, lmfFreq, lmfQ, f.lmf, EQFit.lmfRange), hmf: bell(hmfGain, hmfFreq, hmfQ, f.hmf, EQFit.hmfRange), residual: f.residual)
    }

    /// "1.5k", "1500", "250 Hz", "2,5 kHz" to Hz; nil when it is not a number.
    public static func parseFrequency(_ text: String) -> Double? {
        var t = text.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if t.hasSuffix("hz") { t.removeLast(2) }
        t = t.trimmingCharacters(in: .whitespaces)
        var scale = 1.0
        if t.hasSuffix("k") { scale = 1000; t.removeLast() }
        guard let v = Double(t.trimmingCharacters(in: .whitespaces)), v > 0 else { return nil }
        return v * scale
    }

    /// A plain number ("-3", "+4,5", "2.5"); nil when it is not.
    public static func parseNumber(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "+", with: ""))
    }
}

extension EQFit {
    /// The Q the model reads for a bell whose knob is at `knob` on its printed scale, at `gain` dB (the inverse of `knobQ`).
    public static func effectiveQ(knob: Double, gain: Double) -> Double {
        let boost = 0.25 + 0.75 * min(1, abs(gain) / 16.4)
        return knob * (gain >= 0 ? boost : 0.4 * boost)
    }
}
