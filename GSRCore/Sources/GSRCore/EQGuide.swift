import Foundation

/// Follows the EQ knobs while they are turned: when the live curve moves, finds which single knob explains the move, then tells which way
/// that knob still has to go to reach a stored curve.
///
/// One knob at a time is a well-posed problem (eight knobs at once, from a smooth curve, is not: several settings fit the same curve).
/// The sensitivity of the curve to each knob comes from the four-section model around the fitted settings; the model only has to be right
/// about the *shape* of a move, so its approximations in size do not matter much. Tried with the phase too: it changed nothing.
public enum EQGuide {
    public enum Knob: Int, CaseIterable {
        case lf, hf, lmfGain, lmfFreq, lmfQ, hmfGain, hmfFreq, hmfQ
    }

    public struct Move: Equatable {
        public var knob: Knob
        public var amount: Double        // in the knob's unit: dB for gains, ln of the ratio for frequency and Q (positive: turned clockwise)
        public var explained: Double     // share of the change of the curve this knob explains, 0 to 1
    }

    /// Smallest change of the curve (rms, dB) that is taken for a knob being turned.
    public static let minimumChange = 0.3
    /// Share of the change a single knob must explain.
    public static let minimumExplained = 0.7

    /// Change of the response (dB) for one unit of each knob, around `s`.
    static func sensitivities(_ s: EQSettings, freq f: [Double]) -> [[Double]] {
        func moved(_ k: Knob, _ d: Double) -> EQSettings {
            var t = s
            switch k {
            case .lf: t.lf += d
            case .hf: t.hf += d
            case .lmfGain: t.lmf.gain += d
            case .lmfFreq: t.lmf.freq *= exp(d)
            case .lmfQ: t.lmf.q *= exp(d)
            case .hmfGain: t.hmf.gain += d
            case .hmfFreq: t.hmf.freq *= exp(d)
            case .hmfQ: t.hmf.q *= exp(d)
            }
            return t
        }
        return Knob.allCases.map { k in
            let h = [Knob.lf, .hf, .lmfGain, .hmfGain].contains(k) ? 1e-2 : 1e-3
            let p = moved(k, h), m = moved(k, -h)
            return f.map { (EQFit.response(p, at: $0) - EQFit.response(m, at: $0)) / (2 * h) }
        }
    }

    private static func project(_ change: [Double], on col: [Double]) -> (amount: Double, explained: Double)? {
        let den = col.reduce(0) { $0 + $1 * $1 }, energy = change.reduce(0) { $0 + $1 * $1 }
        guard den > 1e-9, energy > 1e-12 else { return nil }
        let amount = zip(col, change).reduce(0) { $0 + $1.0 * $1.1 } / den
        let residual = zip(col, change).reduce(0) { $0 + pow($1.1 - amount * $1.0, 2) }
        return (amount, 1 - residual / energy)
    }

    /// The knob that was turned between two live curves (relative to the flat reference), if one explains the change.
    public static func movedKnob(from old: EQCurve, to new: EQCurve, around s: EQSettings) -> Move? {
        guard old.freq == new.freq, !old.freq.isEmpty else { return nil }
        let change = zip(new.db, old.db).map { $0 - $1 }
        let rms = (change.reduce(0) { $0 + $1 * $1 } / Double(change.count)).squareRoot()
        guard rms >= minimumChange else { return nil }
        let cols = sensitivities(s, freq: old.freq)
        var best: Move?
        for k in Knob.allCases {
            guard let r = project(change, on: cols[k.rawValue]), r.explained >= minimumExplained else { continue }
            if best == nil || r.explained > best!.explained { best = Move(knob: k, amount: r.amount, explained: r.explained) }
        }
        return best
    }

    /// How far `knob` still has to go (same units as `Move.amount`) for the live curve to reach the target, assuming that knob alone differs.
    public static func remaining(live: EQCurve, target: EQCurve, knob: Knob, around s: EQSettings) -> Double? {
        guard live.freq == target.freq, !live.freq.isEmpty else { return nil }
        let gap = zip(target.db, live.db).map { $0 - $1 }
        if gap.allSatisfy({ abs($0) < 1e-6 }) { return 0 }                  // already there
        return project(gap, on: sensitivities(s, freq: live.freq)[knob.rawValue])?.amount
    }

    /// What each knob would have to do, all together, to bring the live curve to the target.
    public struct Guidance: Equatable {
        public var contributions: [Double]    // by `Knob.rawValue`: rms (dB) of the part of the gap this knob accounts for in the joint solution
        public var amounts: [Double]          // by `Knob.rawValue`: change of the knob in the units of `Move.amount` (positive: clockwise)
        /// The knob with the largest contribution, if it is worth touching.
        public var best: Knob? {
            guard let i = contributions.indices.max(by: { contributions[$0] < contributions[$1] }), contributions[i] >= EQGuide.worthTouching else { return nil }
            return Knob(rawValue: i)
        }
    }

    /// Gap (rms, dB) below which a knob is not worth suggesting.
    public static let worthTouching = 0.15

    /// Joint (ridge) solution of the eight knobs for the gap between target and live. The sensitivities only need the right shapes: the
    /// advice is followed knob by knob with the live curve as feedback, so a wrong size costs a move, not the result. In simulation, from the
    /// displayed target positions (about 2 dB and 40 % off) this reaches a 0.2 dB gap in 8 to 14 moves; one knob at a time chosen without
    /// the joint solution needs 10 to 20.
    public static func guidance(live: EQCurve, target: EQCurve, around s: EQSettings) -> Guidance? {
        guard live.freq == target.freq, !live.freq.isEmpty else { return nil }
        let n = live.freq.count
        let scale = [3.0, 3.0, 3.0, 0.1, 0.15, 3.0, 0.1, 0.15]                 // typical step of each knob
        let cols = sensitivities(s, freq: live.freq).enumerated().map { i, c in c.map { $0 * scale[i] } }
        let gap = zip(target.db, live.db).map { $0 - $1 }
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8), atg = [Double](repeating: 0, count: 8)
        for i in 0..<8 {
            atg[i] = zip(cols[i], gap).reduce(0) { $0 + $1.0 * $1.1 }
            for j in 0..<8 { ata[i][j] = zip(cols[i], cols[j]).reduce(0) { $0 + $1.0 * $1.1 } }
            ata[i][i] += 1
        }
        guard let d = solve(ata, atg) else { return nil }
        let contributions = (0..<8).map { i in (cols[i].reduce(0) { $0 + $1 * $1 } / Double(n)).squareRoot() * abs(d[i]) }
        return Guidance(contributions: contributions, amounts: (0..<8).map { d[$0] * scale[$0] })
    }

    /// Gaussian elimination with partial pivoting.
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = a, v = b
        let n = b.count
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(m[$0][c]) < abs(m[$1][c]) }), abs(m[p][c]) > 1e-12 else { return nil }
            m.swapAt(c, p); v.swapAt(c, p)
            for r in (c + 1)..<n {
                let k = m[r][c] / m[c][c]
                for j in c..<n { m[r][j] -= k * m[c][j] }
                v[r] -= k * v[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var sum = v[r]
            for j in (r + 1)..<n { sum -= m[r][j] * x[j] }
            x[r] = sum / m[r][r]
        }
        return x
    }

    /// Distance to cover below which the knob counts as in place.
    public static func tolerance(_ knob: Knob) -> Double {
        switch knob {
        case .lf, .hf, .lmfGain, .hmfGain: return 0.3     // dB
        case .lmfFreq, .hmfFreq: return 0.05              // 5 %
        case .lmfQ, .hmfQ: return 0.12
        }
    }
}

/// Recognises the knob that is being turned from the stream of live curves (relative to the flat reference).
///
/// For each knob the change of the curve is projected on that knob's sensitivity pattern: a matched filter, which gathers the evidence from
/// the whole curve and so sees changes far smaller than the noise on any single point. A knob is named when its signal is well above the
/// noise (`minimumZ` standard deviations) and explains most of what changed once the noise is taken out. Several delays (0.7 to 3 s) are tried
/// so that a slow turn, which hardly moves the curve in 0.7 s, is caught over a longer span. A knob has to win twice in a row, and stays
/// named for `hold` seconds after its last win.
public struct KnobTracker {
    /// rms noise of the difference between two live curves, in dB.
    public var noise = 0.2
    public var lags = [0.7, 1.5, 3.0]
    public var minimumZ = 5.5
    public var minimumExplained = 0.7
    public var hold = 2.5

    private var history: [(time: Double, curve: EQCurve)] = []
    private var candidate: EQGuide.Knob?
    private var streak = 0
    private var active: EQGuide.Knob?
    private var until = -Double.infinity

    public init() {}

    public mutating func reset() { history = []; candidate = nil; streak = 0; active = nil; until = -.infinity }

    /// The knob being turned at `time`, if any. `settings` are the fitted settings, only used for the shape of each knob's effect.
    @discardableResult
    public mutating func update(time: Double, curve: EQCurve, around s: EQSettings) -> EQGuide.Knob? {
        var best: (knob: EQGuide.Knob, z: Double)?
        let cols = EQGuide.sensitivities(s, freq: curve.freq)
        let n = Double(curve.freq.count), noiseEnergy = n * noise * noise
        for lag in lags {
            guard let old = history.last(where: { time - $0.time >= lag })?.curve, old.freq == curve.freq else { continue }
            let change = zip(curve.db, old.db).map { $0 - $1 }
            let energy = change.reduce(0) { $0 + $1 * $1 }, signal = energy - noiseEnergy
            guard signal > 0 else { continue }
            for k in EQGuide.Knob.allCases {
                let col = cols[k.rawValue], den = col.reduce(0) { $0 + $1 * $1 }
                guard den > 1e-9 else { continue }
                let a = zip(col, change).reduce(0) { $0 + $1.0 * $1.1 } / den
                let z = abs(a) * den.squareRoot() / noise
                let explained = (a * a * den - noise * noise) / signal
                if z >= minimumZ, explained >= minimumExplained, best == nil || z > best!.z { best = (k, z) }
            }
        }
        if let b = best {
            streak = b.knob == candidate ? streak + 1 : 1
            candidate = b.knob
            if streak >= 2 { active = b.knob; until = time + hold }
        } else { candidate = nil; streak = 0 }
        history.append((time, curve))
        history.removeAll { time - $0.time > (lags.max() ?? 0) + 1 }
        return time < until ? active : nil
    }
}
