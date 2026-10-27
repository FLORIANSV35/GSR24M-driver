import Foundation

/// Estimated position of the four EQ sections of a mono channel (GS-R24 user guide p.12-13):
/// HF shelf 12 kHz, LF shelf 60 Hz (gains only, ±15 dB), LMF and HMF bells (gain ±15 dB, sweepable frequency, Q 0.8 to 6).
public struct EQSettings: Codable, Equatable {
    public struct Bell: Codable, Equatable {
        public var gain: Double, freq: Double, q: Double
        public init(gain: Double, freq: Double, q: Double) { self.gain = gain; self.freq = freq; self.q = q }
        /// A bell with nearly no gain says nothing about its frequency and Q.
        public var isFlat: Bool { abs(gain) < EQFit.flatThreshold }
    }
    public var lf: Double, hf: Double
    public var lmf: Bell, hmf: Bell
    /// RMS difference in dB between the measured curve and the model (small means the console behaves like the model).
    public var residual: Double
    public init(lf: Double, hf: Double, lmf: Bell, hmf: Bell, residual: Double = 0) {
        self.lf = lf; self.hf = hf; self.lmf = lmf; self.hmf = hmf; self.residual = residual
    }
}

public enum EQFit {
    public static let flatThreshold = 0.4
    public static let lfCorner = 60.0, hfCorner = 12_000.0     // as in the guide; free fits of the +15 end stop gave 62 Hz and 12.8 kHz
    public static let lmfRange = 18.0...1_000.0, hmfRange = 400.0...18_000.0
    /// Q as this model reads it. The bells are wider than a fixed-Q section at a modest gain, so the range goes below the knob's own (0.41 was
    /// read at +7.5 dB with the knob at the left stop); lower than that the fit starts to settle on look-alike solutions with the wrong split
    /// between the bands. See `knobQ` for the conversion to the knob.
    public static let qRange = 0.4...6.5

    /// Q of the knob, in the units of its printed scale as measured at full boost, from the Q the fit reads and the gain of the bell.
    /// Measured on the LM bell with the Q knob at the left stop: Q read 0.41 at +7.5 dB, 0.60 at +11.7, 0.74 at +16.4 and 0.20 at -9.2 dB, which
    /// this law brings back to 0.69, 0.76, 0.74 and 0.75. Not measured at the other Q positions (the same factor is assumed).
    public static func knobQ(effective q: Double, gain: Double) -> Double {
        let boost = 0.25 + 0.75 * min(1, abs(gain) / 16.4)
        return q / (gain >= 0 ? boost : 0.4 * boost)
    }

    /// The gain knobs stop a little beyond the printed ±15: measured +16.7 (LF), +16.3 (HF), +16.0 (LM bell).
    public static let gainLimit = 16.7

    // MARK: model

    /// Magnitude in dB of the whole EQ at `f`.
    public static func response(_ s: EQSettings, at f: Double) -> Double {
        shelfLow(s.lf, f) + shelfHigh(s.hf, f) + bell(s.lmf, f) + bell(s.hmf, f)
    }

    static func shelfLow(_ gdB: Double, _ f: Double) -> Double {      // gain g at low frequencies, 1 above the corner
        let g = pow(10, gdB / 20), w = f / lfCorner
        return 10 * log10((w * w + g * g) / (w * w + 1))
    }

    static func shelfHigh(_ gdB: Double, _ f: Double) -> Double {
        let g = pow(10, gdB / 20), w = f / hfCorner
        return 10 * log10((g * g * w * w + 1) / (w * w + 1))
    }

    static func bell(_ b: EQSettings.Bell, _ f: Double) -> Double {   // analogue second-order peaking section, gain at the centre
        let g = pow(10, b.gain / 20), x = f / b.freq
        let a = (1 - x * x) * (1 - x * x), d = x / b.q
        return 10 * log10((a + g * g * d * d) / (a + d * d))
    }

    // MARK: fit

    private static func settings(_ p: [Double]) -> EQSettings {
        EQSettings(lf: p[0], hf: p[1],
                   lmf: .init(gain: p[2], freq: pow(10, p[3]), q: p[4]),
                   hmf: .init(gain: p[5], freq: pow(10, p[6]), q: p[7]))
    }

    private static func clamp(_ p: [Double]) -> [Double] {
        var p = p
        for i in [0, 1, 2, 5] { p[i] = min(gainLimit, max(-gainLimit, p[i])) }
        p[3] = min(log10(lmfRange.upperBound), max(log10(lmfRange.lowerBound), p[3]))
        p[6] = min(log10(hmfRange.upperBound), max(log10(hmfRange.lowerBound), p[6]))
        for i in [4, 7] { p[i] = min(qRange.upperBound, max(qRange.lowerBound, p[i])) }
        return p
    }

    private static func cost(_ p: [Double], _ freq: [Double], _ db: [Double]) -> Double {
        let s = settings(p)
        var sum = 0.0
        for i in freq.indices { let e = response(s, at: freq[i]) - db[i]; sum += e * e }
        return sum / Double(freq.count)
    }

    /// Nelder-Mead on the clamped parameters.
    private static func minimise(from start: [Double], _ freq: [Double], _ db: [Double], iterations: Int = 500) -> ([Double], Double) {
        let n = start.count
        let step = [3.0, 3.0, 3.0, 0.15, 0.6, 3.0, 0.15, 0.6]
        var pts: [[Double]] = [clamp(start)]
        for i in 0..<n { var q = start; q[i] += step[i]; pts.append(clamp(q)) }
        var vals = pts.map { cost($0, freq, db) }
        for _ in 0..<iterations {
            let order = vals.indices.sorted { vals[$0] < vals[$1] }
            pts = order.map { pts[$0] }; vals = order.map { vals[$0] }
            if vals[n] - vals[0] < 1e-7 { break }
            var c = [Double](repeating: 0, count: n)
            for k in 0..<n { for i in 0..<n { c[i] += pts[k][i] / Double(n) } }
            func at(_ t: Double) -> [Double] { clamp((0..<n).map { c[$0] + t * (pts[n][$0] - c[$0]) }) }
            let r = at(-1), fr = cost(r, freq, db)
            if fr < vals[0] {
                let e = at(-2), fe = cost(e, freq, db)
                if fe < fr { pts[n] = e; vals[n] = fe } else { pts[n] = r; vals[n] = fr }
            } else if fr < vals[n - 1] {
                pts[n] = r; vals[n] = fr
            } else {
                let k = at(fr < vals[n] ? -0.5 : 0.5), fk = cost(k, freq, db)
                if fk < min(fr, vals[n]) { pts[n] = k; vals[n] = fk } else {
                    for i in 1...n { pts[i] = clamp((0..<n).map { pts[0][$0] + 0.5 * (pts[i][$0] - pts[0][$0]) }); vals[i] = cost(pts[i], freq, db) }
                }
            }
        }
        let b = vals.indices.min { vals[$0] < vals[$1] }!
        return (pts[b], vals[b])
    }

    /// Estimates the settings from a curve in dB relative to the flat reference (EQ IN up). `previous` is kept for callers but not used.
    public static func fit(freq: [Double], db: [Double], previous: EQSettings? = nil) -> EQSettings {
        func at(_ f: Double) -> Double { db[freq.indices.min { abs(freq[$0] - f) < abs(freq[$1] - f) }!] }
        // Always the same starting points, so the same curve gives the same knobs (a warm start could settle in another look-alike solution).
        var starts: [[Double]] = []
        for fl in [40.0, 120, 300, 700] { for fh in [600.0, 1500, 3500, 8000, 14000] {
            starts.append([at(30), at(18000), at(fl), log10(fl), 1.5, at(fh), log10(fh), 1.5])
        } }
        var best: ([Double], Double)?
        for s in starts {
            let r = minimise(from: s, freq, db)
            if best == nil || r.1 < best!.1 { best = r }
        }
        var out = settings(best!.0)
        out.residual = best!.1.squareRoot()
        return out
    }
}
