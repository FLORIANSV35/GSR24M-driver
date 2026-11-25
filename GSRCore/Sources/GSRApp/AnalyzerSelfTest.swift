import Foundation
import AVFoundation
import GSRCore

/// `GSRApp --analyzer-selftest [in|out] [seconds] [plug-in name]`: mounts one plug-in, feeds it from the real rings for a few seconds and prints what happened.
/// Nothing is sent to the card.
enum AnalyzerSelfTest {
    @MainActor static func run(_ args: [String]) async {
        if args.first == "scan" {                      // peak of every channel of both rings over the last second
            guard let tap = RingClient.fetch() else { print("no ring"); return }
            let n = 48000, now = tap.now
            var a = [Float](repeating: 0, count: n), b = [Float](repeating: 0, count: n)
            print("card time \(now), rate \(tap.sampleRate)")
            for src in RingTap.Source.allCases {
                var line = src.rawValue + ":"
                do { let v = tap.read(src, left: 0, right: 1, from: now - UInt64(n) - 2048, into: &a, &b, frames: n); line += " [ch1 valid frames \(v)]" }
                for ch in 0..<32 {
                    let valid = tap.read(src, left: ch, right: ch, from: now - UInt64(n) - 2048, into: &a, &b, frames: n)
                    let p = a.map { abs($0) }.max() ?? 0
                    if p > 0 { line += String(format: " ch%d=%.1f dB(%d valid)", ch + 1, 20 * log10(Double(p)), valid) }
                }
                print(line)
            }
            return
        }
        if args.first == "ahead" {                      // the playback ring around "now": what is already written for the next moments
            guard let tap = RingClient.fetch() else { print("no ring"); return }
            let n = 8192, now = tap.now
            var a = [Float](repeating: 0, count: n), b = [Float](repeating: 0, count: n)
            for off in stride(from: -20000, through: 4000, by: 4000) {
                var line = "from now\(off >= 0 ? "+" : "")\(off):"
                let from = UInt64(Int64(now) + Int64(off))
                for ch in 0..<32 {
                    let v = tap.read(.macOutputs, left: ch, right: ch, from: from, into: &a, &b, frames: n)
                    let p = a.map { abs($0) }.max() ?? 0
                    if p > 0 { line += String(format: " ch%d=%.1f dB(%d)", ch + 1, 20 * log10(Double(p)), v) }
                }
                print(line)
            }
            return
        }
        let source: RingTap.Source = args.first == "out" ? .macOutputs : .consoleInputs
        let seconds = args.count > 1 ? Double(args[1]) ?? 4 : 4
        let wanted = args.count > 2 ? args[2] : "AUPeakLimiter"
        let model = AnalyzerModel()
        model.refreshPlugins()
        print("plug-ins found: \(model.plugins.count)")
        guard let info = model.plugins.first(where: { $0.title == wanted }) ?? model.plugins.first(where: { $0.title.localizedCaseInsensitiveContains(wanted) }) else { print("no plug-in named \(wanted)"); return }
        model.source = source; model.left = args.count > 3 ? Int(args[3]) ?? 0 : 0; model.right = args.count > 4 ? Int(args[4]) ?? 1 : 1
        model.engine.start()
        await model.add(info)
        print("mounted: \(info.title) (\(info.maker)); message: \(model.message)")
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        let st = model.engine.snapshot()
        print("ring connected \(st.connected), streaming \(st.streaming), rate \(st.rate), source \(source.rawValue)")
        print("peaks of the two channels: L \(st.peakL) R \(st.peakR)")
        print("channel 1 name in/out: '\(st.names[0].first ?? "")' / '\(st.names[1].first ?? "")'")
        for i in model.items {
            print("slot \(i.slot.title): rendered \(i.slot.rendered) blocks (expected about \(Int(seconds * st.rate / 512))), failures \(i.slot.failures), overloads \(i.slot.overloads), load avg \(String(format: "%.2f", i.slot.loadAverage * 100)) % peak \(String(format: "%.2f", i.slot.loadPeak * 100)) %, plug-in output peak \(i.slot.outPeak), error \(i.slot.error ?? "none"), view \(i.size)")
        }
        model.engine.stop()
    }
}
