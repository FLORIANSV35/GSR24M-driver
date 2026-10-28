import Testing
import Foundation
@testable import GSRCore

@Suite struct CalibrationFromTypedValues {
    /// Compares the fit of each measured curve with the values typed from the console. GSR_CALIB=<capture name>, prints only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GSR_CALIB"] != nil))
    func printsFitAgainstTyped() throws {
        let name = ProcessInfo.processInfo.environment["GSR_CALIB"]!
        let cap = try #require(EQCapture.loadAll().first { $0.name == name })
        let refs = EQReferences.load()
        for ch in 1...24 {
            guard let m = cap.manual[String(ch)], !m.isEmpty, let c = cap.channels[String(ch)], let flat = refs.channels[String(ch)], let rel = c.relative(to: flat) else { continue }
            let fit = EQFit.fit(freq: rel.freq, db: rel.db)
            let typed = m.settings(fallback: fit)
            func res(_ s: EQSettings) -> Double { (zip(rel.freq, rel.db).reduce(0.0) { $0 + pow(EQFit.response(s, at: $1.0) - $1.1, 2) } / Double(rel.freq.count)).squareRoot() }
            func line(_ s: EQSettings) -> String {
                String(format: "LF %5.1f HF %5.1f | LM %5.1f dB %6.0f Hz Q %4.2f | HM %5.1f dB %6.0f Hz Q %4.2f", s.lf, s.hf, s.lmf.gain, s.lmf.freq, s.lmf.q, s.hmf.gain, s.hmf.freq, s.hmf.q)
            }
            print(String(format: "CAL ch%d typed  rms %.2f  ", ch, res(typed)) + line(typed))
            print(String(format: "CAL ch%d fit    rms %.2f  ", ch, res(fit)) + line(fit))
            // the best that the model can do with the typed gains and frequencies kept and only Q free, and with the gains kept only
            var bestQ = typed
            for qi in stride(from: 0.4, through: 6.5, by: 0.1) {
                for hi in stride(from: 0.4, through: 6.5, by: 0.1) {
                    var s = typed; s.lmf.q = qi; s.hmf.q = hi
                    if res(s) < res(bestQ) { bestQ = s }
                }
            }
            print(String(format: "CAL ch%d typed+bestQ rms %.2f  LM Q %.2f (typed %.2f, knob %.1f) HM Q %.2f (typed %.2f, knob %.1f)", ch, res(bestQ), bestQ.lmf.q, typed.lmf.q, m.lmfQ ?? 0, bestQ.hmf.q, typed.hmf.q, m.hmfQ ?? 0))
            // worst deviations of the typed model against the measure
            let worst = zip(rel.freq, rel.db).map { ($0.0, EQFit.response(typed, at: $0.0) - $0.1) }.max { abs($0.1) < abs($1.1) }!
            print(String(format: "CAL ch%d worst typed-model error %.2f dB at %.0f Hz", ch, worst.1, worst.0))
        }
    }
}
