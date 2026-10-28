import Foundation
import Testing
@testable import GSRCore

/// Closed loop of the recall, simulated: the operator sets the knobs where the app displays the target, then follows the advice one knob at a
/// time. The console is the model of `EQFit` plus a smooth error (the model is not exact), the measurements are noisy, the operator turns each knob by
/// the advised amount give or take 25 %. Reports how often the 90 % accuracy of `EQMeasure.accuracy` is reached, and in how many moves.
/// `GSR_SIM=1 GSR_TRIALS=40 swift test --filter recallConvergence`.
struct RecallSimulation {
    var rng: SplitMix
    var modelError: Double          // amplitude (dB) of the smooth difference between the console and the model
    var noise = 0.08
    var oracle = false

    struct Result { var percent: Double; var moves: Int; var start: Double; var stopped = false; var rms = 0.0; var worst = 0.0; var fitResidual = 0.0; var truth = "" }

    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * rng.uniform() }
    mutating func logUniform(_ a: Double, _ b: Double) -> Double { exp(uniform(log(a), log(b))) }

    /// Settings the console can really have: gains up to its stops, frequencies inside the sweep ranges, a bell at zero gain is common.
    mutating func randomSettings() -> EQSettings {
        func gain() -> Double { rng.uniform() < 0.25 ? 0 : uniform(-16, 16) }
        return EQSettings(lf: gain(), hf: gain(),
                          lmf: .init(gain: gain(), freq: logUniform(EQFit.lmfRange.lowerBound * 1.2, EQFit.lmfRange.upperBound), q: logUniform(0.5, 5)),
                          hmf: .init(gain: gain(), freq: logUniform(EQFit.hmfRange.lowerBound, EQFit.hmfRange.upperBound * 0.9), q: logUniform(0.5, 5)))
    }

    /// What the console really does: the model plus a smooth wobble (two slow sine waves over the log frequency).
    func console(_ s: EQSettings, _ wobble: (Double, Double, Double, Double)) -> [Double] {
        EQMeasure.grid.map { f in
            let x = log2(f / 20)
            return EQFit.response(s, at: f) + modelError * (sin(wobble.0 * x + wobble.1) * 0.6 + sin(wobble.2 * x + wobble.3) * 0.4)
        }
    }

    mutating func trial(maxMoves: Int = 40) -> Result {
        let truth = randomSettings()
        let wobble = (uniform(0.6, 1.4), uniform(0, 6.28), uniform(1.5, 3), uniform(0, 6.28))
        let grid = EQMeasure.grid
        func measure(_ s: EQSettings) -> EQCurve { EQCurve(freq: grid, db: console(s, wobble).map { $0 + noise * rng.gaussian() }) }
        let target = measure(truth)
        // knobs set where the app shows the target, with the error of setting a knob by eye
        var user = EQFit.fit(freq: target.freq, db: target.db)
        let fitResidual = user.residual
        let truthText = String(format: "LF %+.0f HF %+.0f | LM %+.0f dB %.0f Hz Q%.1f | HM %+.0f dB %.0f Hz Q%.1f", truth.lf, truth.hf, truth.lmf.gain, truth.lmf.freq, truth.lmf.q, truth.hmf.gain, truth.hmf.freq, truth.hmf.q)
        user.lf += 0.4 * rng.gaussian(); user.hf += 0.4 * rng.gaussian()
        user.lmf.gain += 0.4 * rng.gaussian(); user.hmf.gain += 0.4 * rng.gaussian()
        user.lmf.freq *= exp(0.08 * rng.gaussian()); user.hmf.freq *= exp(0.08 * rng.gaussian())
        user.lmf.q *= exp(0.15 * rng.gaussian()); user.hmf.q *= exp(0.15 * rng.gaussian())
        user = Self.clamped(user)
        var first = 0.0, last = 0.0, lastRms = 0.0, lastWorst = 0.0
        for move in 0...maxMoves {
            let live = measure(user)
            let acc = EQMeasure.accuracy(target: target, live: live)!
            let a = acc.percent
            lastRms = acc.rmsDeviation; lastWorst = acc.maxDeviation
            if move == 0 { first = a }
            last = a
            if a >= 90 { return Result(percent: a, moves: move, start: first, fitResidual: fitResidual, truth: truthText) }
            let fit = oracle ? user : EQFit.fit(freq: live.freq, db: live.db)           // oracle: the true knob positions, to see what the fit costs
            guard let g = EQGuide.guidance(live: live, target: target, around: fit), let knob = g.best else {
                return Result(percent: last, moves: move, start: first, stopped: true, rms: lastRms, worst: lastWorst, fitResidual: fitResidual, truth: truthText)
            }
            let amount = g.amounts[knob.rawValue] * (1 + 0.25 * rng.gaussian())
            user = Self.clamped(KnobSimulation.moved(user, knob, amount))
        }
        return Result(percent: last, moves: maxMoves + 1, start: first, stopped: false, rms: lastRms, worst: lastWorst, fitResidual: fitResidual, truth: truthText)
    }

    static func clamped(_ s: EQSettings) -> EQSettings {
        var t = s
        let g = EQFit.gainLimit
        t.lf = min(g, max(-g, t.lf)); t.hf = min(g, max(-g, t.hf))
        t.lmf.gain = min(g, max(-g, t.lmf.gain)); t.hmf.gain = min(g, max(-g, t.hmf.gain))
        t.lmf.freq = min(EQFit.lmfRange.upperBound, max(EQFit.lmfRange.lowerBound, t.lmf.freq))
        t.hmf.freq = min(EQFit.hmfRange.upperBound, max(EQFit.hmfRange.lowerBound, t.hmf.freq))
        t.lmf.q = min(EQFit.qRange.upperBound, max(EQFit.qRange.lowerBound, t.lmf.q))
        t.hmf.q = min(EQFit.qRange.upperBound, max(EQFit.qRange.lowerBound, t.hmf.q))
        return t
    }
}

struct RecallConvergence {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GSR_SIM"] == "1"))
    func recallConvergence() {
        let n = Int(ProcessInfo.processInfo.environment["GSR_TRIALS"] ?? "") ?? 20
        for error in [0.0, 0.3] {
            var sim = RecallSimulation(rng: SplitMix(seed: 7), modelError: error)
            sim.oracle = ProcessInfo.processInfo.environment["GSR_ORACLE"] == "1"
            let r = (0..<n).map { _ in sim.trial() }
            let ok = r.filter { $0.percent >= 90 }
            let moves = ok.map(\.moves).sorted()
            let med = moves.isEmpty ? -1 : moves[moves.count / 2]
            let worst = r.filter { $0.percent < 90 }.map { Int($0.percent) }.sorted()
            let stopped = r.filter { $0.percent < 90 && $0.stopped }.count
            print("RECALLSIM failures: \(stopped) stopped with nothing worth touching, \(r.filter { $0.percent < 90 }.count - stopped) ran out of moves; failure rms/worst dev: \(r.filter { $0.percent < 90 }.map { String(format: "%.2f/%+.2f", $0.rms, $0.worst) })")
            for f in r where f.percent < 90 { print("RECALLSIM   failure \(Int(f.percent)) % after \(f.moves) moves, fit residual \(String(format: "%.2f", f.fitResidual)) dB, truth: \(f.truth)") }
            print("RECALLSIM model error \(error) dB: \(ok.count)/\(n) reach 90 %, median \(med) moves, max \(moves.last ?? -1); start accuracy median \(Int(r.map(\.start).sorted()[n / 2])) %; failures end at \(worst)")
        }
    }
}

struct FitQuality {
    /// How well the global fit of a curve finds settings that reproduce it (the knobs displayed as the target): residual of the fit, on random
    /// settings the console can have. `GSR_SIM=1 GSR_TRIALS=200 swift test --filter fitQuality`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GSR_SIM"] == "1"))
    func fitQuality() {
        let n = Int(ProcessInfo.processInfo.environment["GSR_TRIALS"] ?? "") ?? 100
        var sim = RecallSimulation(rng: SplitMix(seed: 11), modelError: 0)
        var residuals: [Double] = []
        var bad: [String] = []
        let start = Date()
        for _ in 0..<n {
            let truth = sim.randomSettings()
            let grid = EQMeasure.grid
            let db = grid.map { EQFit.response(truth, at: $0) + 0.08 * sim.rng.gaussian() }
            let fit = EQFit.fit(freq: grid, db: db)
            residuals.append(fit.residual)
            if fit.residual > 0.2 {
                bad.append(String(format: "res %.2f: LF %+.0f HF %+.0f | LM %+.0f dB %.0f Hz Q%.1f | HM %+.0f dB %.0f Hz Q%.1f", fit.residual, truth.lf, truth.hf, truth.lmf.gain, truth.lmf.freq, truth.lmf.q, truth.hmf.gain, truth.hmf.freq, truth.hmf.q))
            }
        }
        let sorted = residuals.sorted()
        print(String(format: "FITSIM %d fits in %.1f s: residual median %.3f, 90th %.3f, max %.2f dB; above 0.2 dB: %d", n, Date().timeIntervalSince(start), sorted[n / 2], sorted[n * 9 / 10], sorted.last!, bad.count))
        for b in bad.prefix(8) { print("FITSIM   \(b)") }
    }
}

/// Does a fixed order of the knobs help? Same targets and same starting knobs for every order; the sequential orders turn the first knob that is not in
/// place to where it alone brings the curve closest (`EQGuide.remaining`), one pass after the other.
struct OrderExperiment {
    enum Policy: String, CaseIterable {
        case greedy = "greedy (largest part of the gap)"
        case topDown = "top to bottom (HF, HM Q F G, LM Q F G, LF)"
        case gainsFirst = "gains, then frequencies, then Q"
        case freqFirst = "frequencies, then gains, then Q"
        case qFirst = "Q, then frequencies, then gains"
        case stagedGains = "greedy inside stages: gains, then frequencies, then Q"
        case stagedTopDown = "greedy inside sections, top to bottom"
        case qLast = "greedy, the Q knobs only when no gain or frequency is out of place"
        case twoPhase = "one pass over all knobs up to 65 %, then greedy with the Q knobs last"
        case targetFirst = "first pass: each knob towards the fitted target (gains, frequencies, Q), then greedy with the Q knobs last"

        var order: [EQGuide.Knob]? {
            switch self {
            case .greedy: return nil
            case .topDown: return [.hf, .hmfQ, .hmfFreq, .hmfGain, .lmfQ, .lmfFreq, .lmfGain, .lf]
            case .gainsFirst: return [.hf, .hmfGain, .lmfGain, .lf, .hmfFreq, .lmfFreq, .hmfQ, .lmfQ]
            case .freqFirst: return [.hmfFreq, .lmfFreq, .hf, .hmfGain, .lmfGain, .lf, .hmfQ, .lmfQ]
            case .qFirst: return [.hmfQ, .lmfQ, .hmfFreq, .lmfFreq, .hf, .hmfGain, .lmfGain, .lf]
            case .stagedGains, .stagedTopDown, .qLast, .twoPhase, .targetFirst: return nil
            }
        }
    }

    static func run(trials n: Int, oracle: Bool, modelError: Double) -> [Policy: [RecallSimulation.Result]] {
        var out: [Policy: [RecallSimulation.Result]] = [:]
        for index in 0..<n {
            var sim = RecallSimulation(rng: SplitMix(seed: UInt64(7 + index)), modelError: modelError)
            let truth = sim.randomSettings()
            let wobble = (sim.uniform(0.6, 1.4), sim.uniform(0, 6.28), sim.uniform(1.5, 3), sim.uniform(0, 6.28))
            let grid = EQMeasure.grid
            func curve(_ s: EQSettings, _ rng: inout SplitMix) -> EQCurve { EQCurve(freq: grid, db: sim.console(s, wobble).isEmpty ? [] : sim.console(s, wobble).map { $0 + sim.noise * rng.gaussian() }) }
            var setup = SplitMix(seed: UInt64(900 + index))
            let target = curve(truth, &setup)
            var start = EQFit.fit(freq: target.freq, db: target.db)
            let targetFit = start
            start.lf += 0.4 * setup.gaussian(); start.hf += 0.4 * setup.gaussian()
            start.lmf.gain += 0.4 * setup.gaussian(); start.hmf.gain += 0.4 * setup.gaussian()
            start.lmf.freq *= exp(0.08 * setup.gaussian()); start.hmf.freq *= exp(0.08 * setup.gaussian())
            start.lmf.q *= exp(0.15 * setup.gaussian()); start.hmf.q *= exp(0.15 * setup.gaussian())
            start = RecallSimulation.clamped(start)
            if ProcessInfo.processInfo.environment["GSR_FAR"] == "1" { start = RecallSimulation.clamped(sim.randomSettings()) }     // knobs left anywhere by the previous session
            for policy in Policy.allCases {
                var rng = SplitMix(seed: UInt64(5000 + index))
                var user = start
                var result = RecallSimulation.Result(percent: 0, moves: 41, start: 0)
                var cursor = 0, passDone = false
                for move in 0...40 {
                    let live = curve(user, &rng)
                    let acc = EQMeasure.accuracy(target: target, live: live)!
                    if move == 0 { result.start = acc.percent }
                    result.percent = acc.percent
                    if acc.percent >= 90 { result.moves = move; break }
                    let around = oracle ? user : EQFit.fit(freq: live.freq, db: live.db)
                    var knob: EQGuide.Knob?, amount = 0.0
                    if let order = policy.order {
                        for step in 0..<order.count {                                     // next knob in the order that is not in place
                            let k = order[(cursor + step) % order.count]
                            if let r = EQGuide.remaining(live: live, target: target, knob: k, around: around), abs(r) > 0.2 * EQGuide.tolerance(k) {
                                knob = k; amount = r; cursor = (cursor + step + 1) % order.count; break
                            }
                        }
                    } else if policy == .targetFirst, !passDone, acc.percent < 65 {
                        let pass: [EQGuide.Knob] = [.hf, .hmfGain, .lmfGain, .lf, .hmfFreq, .lmfFreq, .hmfQ, .lmfQ]
                        func delta(_ k: EQGuide.Knob) -> Double {
                            switch k {
                            case .lf: return targetFit.lf - user.lf
                            case .hf: return targetFit.hf - user.hf
                            case .lmfGain: return targetFit.lmf.gain - user.lmf.gain
                            case .hmfGain: return targetFit.hmf.gain - user.hmf.gain
                            case .lmfFreq: return log(targetFit.lmf.freq / user.lmf.freq)
                            case .hmfFreq: return log(targetFit.hmf.freq / user.hmf.freq)
                            case .lmfQ: return log(targetFit.lmf.q / user.lmf.q)
                            case .hmfQ: return log(targetFit.hmf.q / user.hmf.q)
                            }
                        }
                        if cursor < pass.count { knob = pass[cursor]; amount = delta(pass[cursor]); cursor += 1 }
                        if cursor >= pass.count { passDone = true }
                    } else if policy == .twoPhase, !passDone, acc.percent < 65 {
                        let pass: [EQGuide.Knob] = [.hf, .hmfGain, .lmfGain, .lf, .hmfFreq, .lmfFreq, .hmfQ, .lmfQ]       // gains, frequencies, then Q
                        if cursor < pass.count {
                            let k = pass[cursor]; cursor += 1
                            knob = k; amount = EQGuide.remaining(live: live, target: target, knob: k, around: around) ?? 0
                            if abs(amount) < 1e-9 { knob = nil }
                        }
                        if cursor >= pass.count { passDone = true }
                        if knob == nil && !passDone { continue }
                    } else if let g = EQGuide.guidance(live: live, target: target, around: around), let k = g.best {
                        knob = k; amount = g.amounts[k.rawValue]
                        let groups: [[EQGuide.Knob]]? = policy == .stagedGains ? [[.hf, .hmfGain, .lmfGain, .lf], [.hmfFreq, .lmfFreq], [.hmfQ, .lmfQ]]
                            : policy == .stagedTopDown ? [[.hf], [.hmfQ, .hmfFreq, .hmfGain], [.lmfQ, .lmfFreq, .lmfGain], [.lf]] : nil
                        if policy == .qLast || policy == .twoPhase || policy == .targetFirst {                                 // the Q knobs last: the Q of a bell depends on its gain
                            let nonQ: [EQGuide.Knob] = [.hf, .lf, .hmfGain, .lmfGain, .hmfFreq, .lmfFreq]
                            let open = nonQ.filter { abs(g.amounts[$0.rawValue]) > EQGuide.tolerance($0) }
                            if let best = open.max(by: { g.contributions[$0.rawValue] < g.contributions[$1.rawValue] }) { knob = best; amount = g.amounts[best.rawValue] }
                        }
                        for group in groups ?? [] {                                    // the first stage with a knob that is not in place; the best knob of that stage
                            let open = group.filter { abs(g.amounts[$0.rawValue]) > EQGuide.tolerance($0) }
                            if let best = open.max(by: { g.contributions[$0.rawValue] < g.contributions[$1.rawValue] }) { knob = best; amount = g.amounts[best.rawValue]; break }
                        }
                    }
                    guard let k = knob else { result.stopped = true; result.moves = move; break }
                    user = RecallSimulation.clamped(KnobSimulation.moved(user, k, amount * (1 + 0.25 * rng.gaussian())))
                }
                out[policy, default: []].append(result)
            }
        }
        return out
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GSR_SIM"] == "1"))
    func knobOrder() {
        let n = Int(ProcessInfo.processInfo.environment["GSR_TRIALS"] ?? "") ?? 60
        let oracle = ProcessInfo.processInfo.environment["GSR_ORACLE"] == "1"
        for error in [0.0, 0.3] {
            let results = Self.run(trials: n, oracle: oracle, modelError: error)
            for p in Policy.allCases {
                let r = results[p]!, ok = r.filter { $0.percent >= 90 }, moves = ok.map(\.moves).sorted()
                print("ORDERSIM model error \(error) dB, \(oracle ? "true knobs" : "fitted knobs"): \(p.rawValue): \(ok.count)/\(n) reach 90 %, median \(moves.isEmpty ? -1 : moves[moves.count / 2]) moves, mean \(moves.isEmpty ? 0 : moves.reduce(0, +) / moves.count)")
            }
        }
    }
}
