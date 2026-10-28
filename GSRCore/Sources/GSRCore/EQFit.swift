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
    /// read at +7.5 dB with the knob at the left stop). Deep cuts are wider still: with 0.4 as the floor, channels set to cuts of 15 dB and more
    /// stayed 7 to 11 dB rms off the measure (capture "16 test", channels 4 to 6), with 0.1 they fit to 0.1 to 0.3 dB (channel 5, with all four
    /// bands at the stop, still 2.8). The simulated recall reaches 90 % in 19 cases out of 20 with either floor. See `knobQ` for the conversion to the knob.
    public static let qRange = 0.1...6.5

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

    /// Starting points by screening: for a grid of bell frequencies and Q, the four gains that best explain the curve (linear least squares on the
    /// shapes of the four sections at a small gain), then the exact cost of each candidate; the best few start the simplex search. A handful of
    /// fixed starting points left the simplex in a look-alike minimum when a bell sat at the very end of its sweep or the two bells and a shelf
    /// overlapped (a bell near 25 Hz against the LF shelf, a bell near 15 kHz against the HF shelf): in simulation about 8 % of the fits ended
    /// 0.2 to 1.6 dB off, the screening cuts that.
    private static func screenedStarts(freq: [Double], db: [Double], count: Int) -> [[Double]] {
        let lmFreqs: [Double] = [20, 25, 32, 40, 55, 80, 120, 180, 300, 500, 800]
        let hmFreqs: [Double] = [450, 700, 1100, 1800, 2800, 4500, 7000, 11000, 16000]
        let qs: [Double] = [0.7, 2.0, 5.0]
        let probe = 6.0
        func basis(_ f: (Double) -> Double) -> [Double] { freq.map { f($0) / probe } }
        let lfB = basis { shelfLow(probe, $0) }, hfB = basis { shelfHigh(probe, $0) }
        var lmB: [[Double]] = [], hmB: [[Double]] = []
        for f in lmFreqs { for q in qs { lmB.append(basis { bell(.init(gain: probe, freq: f, q: q), $0) }) } }
        for f in hmFreqs { for q in qs { hmB.append(basis { bell(.init(gain: probe, freq: f, q: q), $0) }) } }
        let n = freq.count
        func dot(_ a: [Double], _ b: [Double]) -> Double { var t = 0.0; for i in 0..<n { t += a[i] * b[i] }; return t }
        var cells: [Int: (cost: Double, p: [Double])] = [:]               // the best Q pair of each pair of frequencies keeps the starts apart
        for (i, lm) in lmB.enumerated() {
            for (j, hm) in hmB.enumerated() {
                let cols = [lfB, hfB, lm, hm]
                var ata = (0..<4).map { r in (0..<4).map { c in dot(cols[r], cols[c]) } }
                var atb = (0..<4).map { dot(cols[$0], db) }
                for k in 0..<4 { ata[k][k] += 1e-3 * ata[k][k] + 1e-6 }
                guard let g = EQGuide.solve(ata, atb) else { continue }
                atb = []
                let gains = g.map { min(gainLimit, max(-gainLimit, $0)) }
                let p = [gains[0], gains[1], gains[2], log10(lmFreqs[i / qs.count]), qs[i % qs.count], gains[3], log10(hmFreqs[j / qs.count]), qs[j % qs.count]]
                let c = cost(p, freq, db), cell = (i / qs.count) * 100 + j / qs.count
                if cells[cell] == nil || c < cells[cell]!.cost { cells[cell] = (c, p) }
            }
        }
        return cells.values.sorted { $0.cost < $1.cost }.prefix(count).map { $0.p }
    }

    /// Levenberg-Marquardt on the clamped parameters (finite-difference Jacobian): reaches the bottom of a basin much more exactly than a simplex.
    private static func refine(from start: [Double], _ freq: [Double], _ db: [Double], iterations: Int = 30) -> ([Double], Double) {
        let h = [0.05, 0.05, 0.05, 0.004, 0.02, 0.05, 0.004, 0.02]
        var p = clamp(start), c = cost(p, freq, db), lambda = 1e-2
        let n = freq.count
        for _ in 0..<iterations {
            var jac = [[Double]](repeating: [Double](repeating: 0, count: 8), count: n)     // by point, then parameter
            for k in 0..<8 {
                var a = p, b = p; a[k] += h[k]; b[k] -= h[k]
                let sa = settings(clamp(a)), sb = settings(clamp(b)), width = clamp(a)[k] - clamp(b)[k]
                for i in 0..<n { jac[i][k] = width.magnitude > 1e-12 ? (response(sa, at: freq[i]) - response(sb, at: freq[i])) / width : 0 }
            }
            let s0 = settings(p)
            let r = (0..<n).map { response(s0, at: freq[$0]) - db[$0] }
            var jtj = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8), jtr = [Double](repeating: 0, count: 8)
            for i in 0..<n { for a in 0..<8 { jtr[a] += jac[i][a] * r[i]; for b in 0..<8 { jtj[a][b] += jac[i][a] * jac[i][b] } } }
            var improved = false
            for _ in 0..<6 {
                var m = jtj
                for k in 0..<8 { m[k][k] += lambda * (jtj[k][k] + 1e-6) }
                guard let d = EQGuide.solve(m, jtr.map { -$0 }) else { lambda *= 10; continue }
                let q = clamp((0..<8).map { p[$0] + d[$0] }), qc = cost(q, freq, db)
                if qc < c { p = q; c = qc; lambda = max(1e-6, lambda / 3); improved = true; break }
                lambda *= 4
            }
            if !improved { break }
        }
        return (p, c)
    }

    /// Estimates the settings from a curve in dB relative to the flat reference (EQ IN up). `previous` is kept for callers but not used.
    public static func fit(freq: [Double], db: [Double], previous: EQSettings? = nil) -> EQSettings {
        // Always the same starting points, so the same curve gives the same knobs (a warm start could settle in another look-alike solution).
        var best: ([Double], Double)?
        var results: [([Double], Double)] = screenedStarts(freq: freq, db: db, count: 12).map { refine(from: $0, freq, db) }
        results.sort { $0.1 < $1.1 }
        for r0 in results.prefix(3) {                                      // the simplex finishes the best few
            let r = minimise(from: r0.0, freq, db, iterations: 300)
            if best == nil || r.1 < best!.1 { best = r }
        }
        var out = settings(best!.0)
        out.residual = best!.1.squareRoot()
        return out
    }
}
