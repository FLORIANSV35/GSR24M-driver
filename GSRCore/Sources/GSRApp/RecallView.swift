import SwiftUI
import Charts
import GSRCore

struct RecallView: View {
    @EnvironmentObject var model: RecallModel
    @EnvironmentObject var app: AppModel

    private func color(_ percent: Double) -> Color { percent >= 95 ? .green : percent >= 75 ? .yellow : .red }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !app.viaDaemon {
                Text("EQ recall needs the gsrd daemon and the GS-R24M audio device.").foregroundStyle(.orange)
            }
            header
            channelGrid
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    chart
                    HStack(alignment: .top, spacing: 16) { score.frame(width: 210, alignment: .leading); controls }
                }
                strip
            }
            if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.white.opacity(0.85)) }
        }
        .sheet(isPresented: $model.askChecklist) { ChecklistSheet() }
    }

    private var header: some View {
        HStack {
            Text("Target").foregroundStyle(.white)
            Picker("", selection: Binding(get: { model.targetName ?? "" }, set: { model.targetName = $0.isEmpty ? nil : $0 })) {
                Text("None").tag("")
                ForEach(model.captures) { c in Text("\(c.name) · \(c.channels.count) ch").tag(c.name) }
            }.labelsHidden().frame(width: 260)
            Spacer()
            if let p = model.progress { ProgressView(value: p).frame(width: 140) }
        }
    }

    private var channelGrid: some View {
        let cols = Array(repeating: GridItem(.flexible(minimum: 34), spacing: 4), count: 12)
        return LazyVGrid(columns: cols, spacing: 4) {
            ForEach(1...24, id: \.self) { c in
                let has = model.target?.channels[String(c)] != nil
                let captured = model.working.channels[String(c)] != nil
                let score = model.scores[c]
                Button { model.select(c) } label: {
                    Text("\(c)").frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(score.map { color($0).opacity(0.85) } ?? (has ? Color.blue.opacity(0.55) : Color(white: 0.45)), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(c == model.channel ? Color.white : (captured ? Color.orange : .clear), lineWidth: 2))
                }.buttonStyle(.plain).foregroundStyle(.white).disabled(model.mode == .capturingAll)
            }
        }
    }

    /// With a reference (EQ IN up) the plot is the EQ alone, 0 dB meaning flat. Without one the card path adds an arbitrary gain,
    /// so it is centred on the level at 1 kHz of the target (or of the live curve when there is none).
    private func shown(_ c: EQCurve, _ ref: EQCurve?, centre: Double) -> [Double] {
        if let ref, let rel = c.relative(to: ref) { return rel.db }
        return c.db.map { $0 - centre }
    }

    private func centre(_ t: EQCurve?, _ l: EQCurve?) -> Double {
        guard let c = t ?? l, let i = c.freq.indices.min(by: { abs(c.freq[$0] - 1000) < abs(c.freq[$1] - 1000) }) else { return 0 }
        return c.db[i].rounded()
    }

    private var chart: some View {
        let target = model.targetCurve, live = model.live, ref = model.reference
        let c0 = centre(target, live)
        let tdb = target.map { shown($0, ref, centre: c0) } ?? [], ldb = live.map { shown($0, ref, centre: c0) } ?? []
        return Chart {
            ForEach(Array(tdb.enumerated()), id: \.offset) { i, y in
                LineMark(x: .value("Hz", target!.freq[i]), y: .value("dB", min(20, max(-20, y))), series: .value("s", "Target")).foregroundStyle(.white)
            }
            ForEach(Array(ldb.enumerated()), id: \.offset) { i, y in
                LineMark(x: .value("Hz", live!.freq[i]), y: .value("dB", min(20, max(-20, y))), series: .value("s", "Live")).foregroundStyle(.orange)
            }
        }
        .chartXScale(domain: 20...20000, type: .log)
        .chartYScale(domain: -20...20)
        .chartYAxis { AxisMarks(values: [-20, -10, 0, 10, 20]) { v in
            AxisGridLine(); AxisValueLabel { if let y = v.as(Double.self) { Text("\(Int(y)) dB") } } } }
        .chartXAxis { AxisMarks(values: [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]) { v in
            AxisGridLine(); AxisValueLabel { if let x = v.as(Double.self) { Text(x >= 1000 ? "\(Int(x / 1000))k" : "\(Int(x))") } } } }
        .chartLegend(.hidden)
        .frame(height: 230)
        .padding(6).background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 10) {
                Label("Target", systemImage: "minus").foregroundStyle(.white)
                Label("Live", systemImage: "minus").foregroundStyle(.orange)
            }.font(.caption).padding(8)
        }
    }

    private var score: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let a = model.accuracy {
                Text("\(Int(a.percent.rounded())) %").font(.system(size: 46, weight: .bold)).foregroundStyle(color(a.percent))
                Text(a.percent >= 95 ? "Recalled" : "Adjust the knobs").font(.callout.bold()).foregroundStyle(.white)
                Text(String(format: "largest deviation %+.2f dB · tolerance 0.2 dB", a.maxDeviation)).font(.caption).foregroundStyle(.white.opacity(0.8))
                ForEach(a.bands, id: \.name) { b in
                    HStack { Text(b.name).frame(width: 36, alignment: .leading)
                        Text(String(format: "%+.2f dB", b.maxDeviation)).monospacedDigit()
                            .foregroundStyle(abs(b.maxDeviation) <= 0.2 ? Color.green : .orange) }.font(.caption).foregroundStyle(.white)
                }
            } else {
                Text("— %").font(.system(size: 46, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                Text(model.targetCurve == nil ? "No stored curve for this channel" : "Start the measurement").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    /// Q of the knob from the fitted bell; meaningless when the bell has hardly any gain.
    private static func knobQ(_ b: EQSettings.Bell) -> Double? {
        abs(b.gain) < 1.5 ? nil : EQFit.knobQ(effective: b.q, gain: b.gain)
    }

    // Scales printed on the console (GS-R24 user guide p.12-13): angle in degrees from 12 o'clock, clockwise.
    private static let gainTicks = [(-16.7, -150.0), (-15, -135), (0, 0), (15, 135), (16.7, 150)]   // the stops lie a little beyond the printed ±15
    private static let qTicks = [(0.74, -135.0), (1.12, 0), (4.75, 135)]   // measured on the LM Q knob (left, middle, right); the HM Q is assumed to follow the same law
    private static let hmfTicks = [(400.0, -135.0), (700, -90), (1000, -45), (2000, 0), (4000, 45), (6000, 90), (18000, 135)]
    private static let lmfTicks = [(18.0, -135.0), (30, -90), (60, -45), (120, 0), (300, 45), (600, 90), (1000, 135)]

    /// The channel strip as on the console, top to bottom: HF, HM (Q, F, G), LM (Q, F, G), LF. Orange pointer = live, white dot = target.
    private var strip: some View {
        let live = model.settings, tgt = model.targetSettings
        func gain(_ l: Double?, _ t: Double?, _ k: EQGuide.Knob) -> KnobView {
            KnobView(label: "G", hint: guide(k), active: model.activeKnob == k, suggested: isNext(k), knob: Color(red: 0.1, green: 0.4, blue: 0.95), ticks: Self.gainTicks, live: l, target: t, tolerance: 0.5, format: { String(format: "%+.1f dB", $0) })
        }
        func q(_ l: EQSettings.Bell?, _ t: EQSettings.Bell?, _ k: EQGuide.Knob) -> KnobView {
            KnobView(label: "Q", hint: guide(k), active: model.activeKnob == k, suggested: isNext(k), knob: Color(white: 0.5), ticks: Self.qTicks, logScale: true, live: l.flatMap { Self.knobQ($0) }, target: t.flatMap { Self.knobQ($0) },
                     relativeTolerance: 0.3, format: { String(format: "%.1f", $0) })
        }
        func freq(_ ticks: [(Double, Double)], _ l: EQSettings.Bell?, _ t: EQSettings.Bell?, _ k: EQGuide.Knob) -> KnobView {
            KnobView(label: "F", hint: guide(k), active: model.activeKnob == k, suggested: isNext(k), knob: Color(white: 0.08), ticks: ticks, logScale: true, live: l.flatMap { $0.isFlat ? nil : $0.freq }, target: t.flatMap { $0.isFlat ? nil : $0.freq },
                     relativeTolerance: 0.06, format: { $0 >= 1000 ? String(format: "%.1f kHz", $0 / 1000) : String(format: "%.0f Hz", $0) })
        }
        return VStack(alignment: .leading, spacing: 4) {
            stripSection("HF", hint: hint("HF")) { gain(live?.hf, tgt?.hf, .hf) }
            stripSection("HM", hint: hint("HMF")) { q(live?.hmf, tgt?.hmf, .hmfQ); freq(Self.hmfTicks, live?.hmf, tgt?.hmf, .hmfFreq); gain(live?.hmf.gain, tgt?.hmf.gain, .hmfGain) }
            stripSection("LM", hint: hint("LMF")) { q(live?.lmf, tgt?.lmf, .lmfQ); freq(Self.lmfTicks, live?.lmf, tgt?.lmf, .lmfFreq); gain(live?.lmf.gain, tgt?.lmf.gain, .lmfGain) }
            stripSection("LF", hint: hint("LF")) { gain(live?.lf, tgt?.lf, .lf) }
            if model.reference == nil {
                Text("Measure the reference (EQ IN up) to also see approximate knob positions and to follow the knob you turn").font(.caption2).foregroundStyle(.white.opacity(0.7)).frame(width: 190, alignment: .leading)
            } else {
                Text("Dashed knob = touch it next. Turn a knob: it lights up and shows which way to go").font(.caption2).foregroundStyle(.white.opacity(0.5)).frame(width: 190, alignment: .leading)
            }
        }
        .padding(8).background(Color(red: 0.15, green: 0.18, blue: 0.2), in: RoundedRectangle(cornerRadius: 6))
    }

    /// For the knob being turned: which way it still has to go, from the movement of the live curve (positive distance: clockwise).
    /// For the knob worth touching next (when none is being turned): which way to start.
    private func guide(_ k: EQGuide.Knob) -> (text: String, ok: Bool)? {
        if model.activeKnob == k, let r = model.activeRemaining {
            if abs(r) <= EQGuide.tolerance(k) { return ("✓ in place", true) }
            return (r > 0 ? "↻ turn right" : "↺ turn left", false)
        }
        if model.activeKnob == nil, model.suggestedKnob == k, let a = model.suggestedAmount { return (a > 0 ? "next: ↻ right" : "next: ↺ left", false) }
        return nil
    }

    private func isNext(_ k: EQGuide.Knob) -> Bool { model.activeKnob == nil && model.suggestedKnob == k }

    /// How far to turn a section, from the curves alone (live minus target in the section's band): reliable whatever the knob positions are.
    private func hint(_ band: String) -> (text: String, ok: Bool)? {
        guard let dev = model.accuracy?.bands.first(where: { $0.name == band })?.maxDeviation else { return nil }
        if abs(dev) <= 0.2 { return ("OK", true) }
        return (String(format: "%@ %.1f dB", dev < 0 ? "up" : "down", abs(dev)), false)
    }

    private func stripSection<C: View>(_ title: String, hint: (text: String, ok: Bool)?, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 2) {
                Text(title).font(.callout.bold()).foregroundStyle(.white)
                if let hint {
                    Text(hint.text).font(.caption2.bold()).multilineTextAlignment(.center).frame(width: 38)
                        .foregroundStyle(hint.ok ? Color.green : Color.orange)
                }
            }.frame(width: 40).padding(.top, 10)
            VStack(alignment: .leading, spacing: 2) { content() }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.running {
                Button("Stop") { model.stop() }.buttonStyle(.borderedProminent).tint(.red)
            } else {
                Button("Measure channel \(model.channel)") { model.request(.live) }.disabled(!app.viaDaemon || !model.deviceAvailable)
                Button("Capture channel \(model.channel)") { model.request(.capturingOne) }.disabled(!app.viaDaemon || !model.deviceAvailable)
                Button("Capture all 24 channels") { model.request(.capturingAll) }.disabled(!app.viaDaemon || !model.deviceAvailable)
                Divider()
                Button(model.reference == nil ? "Reference channel \(model.channel) (EQ IN up)" : "Redo reference channel \(model.channel)") { model.request(.capturingOne, reference: true) }
                    .disabled(!app.viaDaemon || !model.deviceAvailable)
                Button("Reference all 24 channels") { model.request(.capturingAll, reference: true) }.disabled(!app.viaDaemon || !model.deviceAvailable)
            }
            if model.workingCount > 0 && !model.running {
                Divider()
                Text("\(model.workingCount) channel(s) captured").font(.caption).foregroundStyle(.white)
                TextField("Capture name", text: $model.newName).textFieldStyle(.roundedBorder)
                Button("Save capture") { model.saveWorking() }.disabled(model.newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

struct ChecklistSheet: View {
    @EnvironmentObject var model: RecallModel
    @State private var monitorsOff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before any sound").font(.headline)
            Text("The measurement plays pink noise into the console.").font(.callout)
            Text("Press A and B on the channel to measure.").font(.callout)
            Text(model.pendingReference ? "For a reference, release EQ IN (EQ bypassed)." : "EQ IN pressed, to measure the EQ.").font(.callout)
            Toggle("Monitors and headphones are switched off", isOn: $monitorsOff)
            HStack {
                Spacer()
                Button("Cancel") { model.askChecklist = false }.keyboardShortcut(.cancelAction)
                Button("Start") { model.confirmChecklist() }.keyboardShortcut(.defaultAction).disabled(!monitorsOff)
            }
        }
        .padding(18).frame(width: 380)
    }
}

/// One EQ knob drawn like the console's: 270 degrees of travel, the scale given by printed ticks.
struct KnobView: View {
    let label: String
    var hint: (text: String, ok: Bool)? = nil      // which way to turn the knob
    var active = false                             // the knob being turned
    var suggested = false                          // the knob worth touching next
    let knob: Color
    let ticks: [(Double, Double)]       // (value, angle in degrees from 12 o'clock, clockwise), by increasing value
    var logScale = false
    let live: Double?
    let target: Double?
    var tolerance = 0.0                 // absolute, in the knob's unit
    var relativeTolerance = 0.0         // fraction of the target value
    let format: (Double) -> String

    private func angle(_ v: Double) -> Double {
        let c = min(ticks.last!.0, max(ticks[0].0, v))
        var i = 0
        while i < ticks.count - 2 && c > ticks[i + 1].0 { i += 1 }
        let (a, b) = (ticks[i], ticks[i + 1])
        let t = logScale ? log(c / a.0) / log(b.0 / a.0) : (c - a.0) / (b.0 - a.0)
        return a.1 + t * (b.1 - a.1)
    }

    private func point(_ deg: Double, _ r: Double, _ c: CGPoint) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: c.x + r * sin(a), y: c.y - r * cos(a))
    }

    private var matched: Bool? {
        guard let l = live, let t = target else { return nil }
        return abs(l - t) <= max(tolerance, relativeTolerance * abs(t))
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.6)).frame(width: 10)
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2), r = min(size.width, size.height) / 2 - 6
                for t in ticks {
                    var m = Path(); m.move(to: point(t.1, r + 2, c)); m.addLine(to: point(t.1, r + 5, c))
                    ctx.stroke(m, with: .color(.white.opacity(0.7)), lineWidth: 1.2)
                }
                if active { ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r - 4, y: c.y - r - 4, width: 2 * r + 8, height: 2 * r + 8)), with: .color(.white), lineWidth: 2) }
                if suggested { ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r - 4, y: c.y - r - 4, width: 2 * r + 8, height: 2 * r + 8)), with: .color(.cyan), style: StrokeStyle(lineWidth: 2, dash: [3, 3])) }
                let ring: Color = matched == true ? .green : (matched == false ? .red.opacity(0.85) : .clear)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(knob))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(ring == .clear ? Color(white: 0.55) : ring), lineWidth: 2.5)
                if let t = target {
                    let p = point(angle(t), r + 6, c)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(.white))
                }
                if let l = live {
                    var line = Path(); line.move(to: point(angle(l), r * 0.2, c)); line.addLine(to: point(angle(l), r - 2, c))
                    ctx.stroke(line, with: .color(.orange), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                }
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 0) {
                Text(live.map(format) ?? "—").font(.caption.monospacedDigit().bold()).foregroundStyle(live == nil ? .white.opacity(0.4) : .orange)
                if let t = target { Text(format(t)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.75)) }
                if let hint { Text(hint.text).font(.caption2.bold()).foregroundStyle(hint.ok ? Color.green : (suggested ? Color.cyan : .orange)) }
            }.frame(width: 62, alignment: .leading)
        }
    }
}
