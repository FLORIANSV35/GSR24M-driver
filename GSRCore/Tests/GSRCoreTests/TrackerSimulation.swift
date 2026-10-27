import Foundation
import Testing
@testable import GSRCore

/// A knob turned smoothly while the app measures: the live curve is the mean of the true curve over the last noise period (1.37 s), plus noise,
/// smoothed as in the app. Used to compare ways of recognising the knob that moves.
struct KnobSimulation {
    static let dt = 0.15, window = 1.37
    static let base = EQSettings(lf: 3, hf: -2, lmf: .init(gain: 6, freq: 180, q: 0.5), hmf: .init(gain: 4, freq: 1400, q: 0.5))
    static let grid = EQMeasure.grid

    struct Scenario { var knob: EQGuide.Knob; var change: Double; var duration: Double }

    static func moved(_ s: EQSettings, _ k: EQGuide.Knob, _ amount: Double) -> EQSettings {
        var t = s
        switch k {
        case .lf: t.lf += amount
        case .hf: t.hf += amount
        case .lmfGain: t.lmf.gain += amount
        case .lmfFreq: t.lmf.freq *= exp(amount)
        case .lmfQ: t.lmf.q *= exp(amount)
        case .hmfGain: t.hmf.gain += amount
        case .hmfFreq: t.hmf.freq *= exp(amount)
        case .hmfQ: t.hmf.q *= exp(amount)
        }
        return t
    }

    /// Sequence of (time, measured curve) for a scenario: still for 2 s, the knob turns, still again until 12 s.
    static func run(_ sc: Scenario, seed: UInt64, noise: Double = 0.12, from start: EQSettings = base) -> [(Double, EQCurve)] {
        var rng = SplitMix(seed: seed)
        func settings(at t: Double) -> EQSettings {
            let p = min(1, max(0, (t - 2) / sc.duration))
            return moved(start, sc.knob, sc.change * p)
        }
        func truth(_ t: Double) -> [Double] { grid.map { EQFit.response(settings(at: t), at: $0) } }
        var out: [(Double, EQCurve)] = []
        var smooth: [Double]?
        var t = 0.0
        while t <= 12 {
            // mean of the true curve over the window
            let steps = 6
            var mean = [Double](repeating: 0, count: grid.count)
            for i in 0..<steps { let c = truth(t - window * Double(i) / Double(steps - 1)); for k in 0..<mean.count { mean[k] += c[k] / Double(steps) } }
            let measured = mean.map { $0 + noise * rng.gaussian() }
            smooth = smooth.map { zip($0, measured).map { 0.4 * $0 + 0.6 * $1 } } ?? measured
            out.append((t, EQCurve(freq: grid, db: smooth!)))
            t += dt
        }
        return out
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gaussian() -> Double {
        let u = max(uniform(), 1e-12), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

/// What the app does now: compare with the curve about 0.7 s ago, at least 0.3 dB rms and 70 % explained; the knob stays lit 2.5 s.
struct LegacyDetector {
    var history: [(Double, EQCurve)] = []
    var active: EQGuide.Knob?
    var until = -1.0
    mutating func update(_ t: Double, _ c: EQCurve, around s: EQSettings) -> EQGuide.Knob? {
        let old = history.last { t - $0.0 >= 0.7 }?.1
        if let old, let m = EQGuide.movedKnob(from: old, to: c, around: s) { active = m.knob; until = t + 2.5 }
        history.append((t, c)); history.removeAll { t - $0.0 > 3 }
        return t < until ? active : nil
    }
}

@Suite struct TrackerSimulation {
    static let scenarios: [KnobSimulation.Scenario] = {
        var list: [KnobSimulation.Scenario] = []
        for (k, change) in [(EQGuide.Knob.lf, 4.0), (.hf, -4), (.lmfGain, 4), (.lmfFreq, 0.4), (.lmfQ, 0.4), (.hmfGain, -4), (.hmfFreq, -0.4), (.hmfQ, 0.4)] {
            for d in [1.0, 3.0, 6.0] { list.append(.init(knob: k, change: change, duration: d)) }
        }
        return list
    }()

    /// Runs `detect` over every scenario: how often the right knob is named while it moves (and how soon), how often a wrong one is, and
    /// how often anything is named while nothing moves.
    static func evaluate(_ name: String, noise: Double = 0.12, seeds: [UInt64] = [1, 2, 3], makeDetector: () -> (Double, EQCurve, EQSettings) -> EQGuide.Knob?) -> (hit: Double, wrong: Double, falseAlarm: Double) {
        var hits = 0, wrong = 0, total = 0, falseAlarms = 0, stillSteps = 0
        var detail: [String] = []
        for sc in scenarios {
            var results: [String] = []
            for seed in seeds {
                var detect = makeDetector()
                let wrongSettings = KnobSimulation.moved(KnobSimulation.moved(KnobSimulation.base, .lmfFreq, 0.3), .lmfGain, -1.5)    // the fit is never exact
                var named: [EQGuide.Knob] = [], firstRight: Double?
                for (t, c) in KnobSimulation.run(sc, seed: seed, noise: noise) {
                    let k = detect(t, c, wrongSettings)
                    if t < 2.2 { stillSteps += 1; if k != nil { falseAlarms += 1 } }
                    if t >= 2.2 + sc.duration + 3 { /* settled again: nothing to check */ }
                    if let k, t >= 2.2 { named.append(k); if k == sc.knob, firstRight == nil { firstRight = t - 2 } }
                }
                total += 1
                if firstRight != nil { hits += 1 }
                if named.contains(where: { $0 != sc.knob }) { wrong += 1 }
                results.append(firstRight.map { String(format: "%.1fs", $0) } ?? "miss")
            }
            detail.append("\(sc.knob) \(sc.duration)s: \(results.joined(separator: " "))")
        }
        print("SIMSUM \(name): right knob named \(hits)/\(total), a wrong knob named at some point \(wrong)/\(total), false alarms while still \(falseAlarms)/\(stillSteps)")
        return (Double(hits) / Double(total), Double(wrong) / Double(total), Double(falseAlarms) / Double(stillSteps))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GSR_SIM"] == "1"))
    func legacyDetector() {
        _ = Self.evaluate("legacy") {
            var d = LegacyDetector()
            return { t, c, s in d.update(t, c, around: s) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GSR_SIM"] == "1"))
    func noiseSweep() {
        for sim in [0.05, 0.12, 0.25, 0.4] {
            for assumed in [0.1, 0.2] {
                _ = Self.evaluate("sim noise \(sim), tracker assumes \(assumed)", noise: sim) {
                    var tracker = KnobTracker(); tracker.noise = assumed
                    return { t, c, s in tracker.update(time: t, curve: c, around: s) }
                }
            }
        }
    }

    /// Quick check: one seed. `GSR_SIM=1` also runs the comparison with the previous detector and the noise sweep.
    @Test func matchedFilterTracker() {
        let r = Self.evaluate("tracker", seeds: [1]) {
            var tracker = KnobTracker()
            return { t, c, s in tracker.update(time: t, curve: c, around: s) }
        }
        #expect(r.falseAlarm < 0.01 && r.wrong == 0 && r.hit > 0.9)
    }
}
