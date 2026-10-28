import Foundation

/// Which knob to turn, which way and how far, in the order that works best (simulation, `RecallConvergence.swift`).
///
/// First pass: every knob once, in the order gains, frequencies, then Q, each towards the position the fit of the stored curve gives for it,
/// until the curves agree to 65 %. From knobs left anywhere this is what makes the difference: always taking the knob that explains most of the
/// gap reached 90 % in 21 cases out of 60 within 40 moves, this pass followed by the refinement in 48 to 50.
/// Refinement: the knobs that explain most of the gap between the live and the stored curve, the Q knobs last: the Q of a bell, as measured,
/// depends on its gain, so it is set once the gains and frequencies are in place.
public struct RecallAdvisor {
    public enum Phase { case firstPass, refine }

    /// Gains first (top to bottom), then the frequencies, then the Q.
    public static let passOrder: [EQGuide.Knob] = [.hf, .hmfGain, .lmfGain, .lf, .hmfFreq, .lmfFreq, .hmfQ, .lmfQ]
    /// Accuracy (%) at which the first pass stops and the refinement starts.
    public static let passTarget = 65.0
    /// A knob is placed well enough for the first pass within this many tolerances.
    public static let coarse = 3.0
    /// A knob turned and let go that still looks out of place is set aside this long, so the advice moves on (the console does not follow the model
    /// exactly, or the knob is at its stop); an advice that brings its knob no closer in `stagnation` seconds is set aside too.
    public static let skipSeconds = 25.0, settleSeconds = 3.0, stagnation = 20.0

    public private(set) var phase = Phase.firstPass
    public private(set) var suggested: (knob: EQGuide.Knob, amount: Double)?

    private var passIndex = 0
    private var deltas: [Double]?
    private var gap: EQGuide.Guidance?
    private var active: EQGuide.Knob?
    private var activeRemaining: Double?
    private var skipped: [EQGuide.Knob: Double] = [:]
    private var released: (knob: EQGuide.Knob, since: Double)?
    private var advice: (knob: EQGuide.Knob, since: Double, amount: Double)?
    private var now = 0.0

    public init() {}

    public static func isQ(_ k: EQGuide.Knob) -> Bool { k == .lmfQ || k == .hmfQ }

    public mutating func reset() { self = RecallAdvisor() }

    /// `deltas`: by `Knob.rawValue`, where each knob is against where the stored curve puts it (`EQGuide.fitDeltas`); `gap`: the joint advice from the
    /// gap between the curves; `active`: the knob being turned and how far it still has to go.
    public mutating func update(now: Double, accuracy: Double?, deltas: [Double]?, gap: EQGuide.Guidance?, active: EQGuide.Knob?, activeRemaining: Double?) {
        self.now = now; self.deltas = deltas; self.gap = gap; self.active = active; self.activeRemaining = activeRemaining
        guard deltas != nil || gap != nil else { suggested = nil; advice = nil; return }
        trackRelease()
        if phase == .firstPass {
            if let a = accuracy, a >= Self.passTarget { phase = .refine }
            while phase == .firstPass, passIndex < Self.passOrder.count {
                let k = Self.passOrder[passIndex]
                guard let d = deltas?[k.rawValue] else { break }
                if abs(d) <= Self.coarse * EQGuide.tolerance(k) || isSkipped(k) { passIndex += 1 } else { break }
            }
            if passIndex >= Self.passOrder.count { phase = .refine }
        }
        pickSuggestion()
        trackStagnation()
    }

    private func isSkipped(_ k: EQGuide.Knob) -> Bool { skipped[k].map { now - $0 < Self.skipSeconds } ?? false }

    private func amountOf(_ k: EQGuide.Knob) -> Double? {
        if active == k, let r = activeRemaining { return r }
        return phase == .firstPass ? deltas?[k.rawValue] : gap?.amounts[k.rawValue]
    }

    private func isOpen(_ k: EQGuide.Knob) -> Bool {
        guard !isSkipped(k), let a = amountOf(k) else { return false }
        return abs(a) > EQGuide.tolerance(k)
    }

    private mutating func trackRelease() {
        if let k = active { released = (k, now); skipped[k] = nil; return }
        guard let r = released, now - r.since >= Self.settleSeconds else { return }
        released = nil
        if isOpen(r.knob) { skipped[r.knob] = now }
    }

    private mutating func pickSuggestion() {
        switch phase {
        case .firstPass:
            let k = Self.passOrder[min(passIndex, Self.passOrder.count - 1)]
            suggested = amountOf(k).map { (k, $0) }
        case .refine:
            guard let g = gap else { suggested = nil; return }
            let nonQ = EQGuide.Knob.allCases.filter { !Self.isQ($0) && isOpen($0) }
            let pool = nonQ.isEmpty ? EQGuide.Knob.allCases.filter { Self.isQ($0) && isOpen($0) } : nonQ     // the Q knobs only when nothing else is out of place
            let strength = { (k: EQGuide.Knob) in g.contributions[k.rawValue] }
            if let cur = suggested?.knob, pool.contains(cur), strength(cur) >= 0.6 * (pool.map(strength).max() ?? 0) {
                suggested = (cur, g.amounts[cur.rawValue])             // the advice stays on its knob until another one is clearly worth more
            } else if let best = pool.max(by: { strength($0) < strength($1) }) {
                suggested = (best, g.amounts[best.rawValue])
            } else { suggested = nil }
        }
    }

    private mutating func trackStagnation() {
        guard let s = suggested else { advice = nil; return }
        guard let a = advice, a.knob == s.knob else { advice = (s.knob, now, abs(s.amount)); return }
        if abs(s.amount) < 0.85 * a.amount { advice = (s.knob, now, abs(s.amount)); return }       // getting closer: the clock starts again
        if now - a.since > Self.stagnation { skipped[s.knob] = now; advice = nil; suggested = nil }
    }

    /// What the strip shows for a knob (the distance still to go, positive = clockwise), nil for a knob that waits for its turn.
    public func shown(_ k: EQGuide.Knob) -> Double? {
        switch phase {
        case .firstPass:
            return k == Self.passOrder[min(passIndex, Self.passOrder.count - 1)] ? amountOf(k) : nil
        case .refine:
            if isSkipped(k) { return nil }
            if Self.isQ(k), EQGuide.Knob.allCases.contains(where: { !Self.isQ($0) && isOpen($0) }) { return nil }
            return amountOf(k)
        }
    }
}

extension EQGuide {
    /// Where each knob has to go to reach the settings the fit of the stored curve gives, from the settings the fit of the live curve gives (by
    /// `Knob.rawValue`; dB for the gains, ln of the ratio for the frequencies and the Q; positive = clockwise). The frequency and Q of a bell that has
    /// (nearly) no gain mean nothing, so they count as in place.
    public static func fitDeltas(live: EQSettings, target: EQSettings) -> [Double] {
        func ratio(_ a: Double, _ b: Double) -> Double { log(a / b) }
        func bell(_ l: EQSettings.Bell, _ t: EQSettings.Bell) -> (gain: Double, freq: Double, q: Double) {
            (t.gain - l.gain, l.isFlat || t.isFlat ? 0 : ratio(t.freq, l.freq), l.isFlat || t.isFlat ? 0 : ratio(t.q, l.q))
        }
        let lm = bell(live.lmf, target.lmf), hm = bell(live.hmf, target.hmf)
        var out = [Double](repeating: 0, count: Knob.allCases.count)
        out[Knob.lf.rawValue] = target.lf - live.lf
        out[Knob.hf.rawValue] = target.hf - live.hf
        out[Knob.lmfGain.rawValue] = lm.gain; out[Knob.lmfFreq.rawValue] = lm.freq; out[Knob.lmfQ.rawValue] = lm.q
        out[Knob.hmfGain.rawValue] = hm.gain; out[Knob.hmfFreq.rawValue] = hm.freq; out[Knob.hmfQ.rawValue] = hm.q
        return out
    }
}
