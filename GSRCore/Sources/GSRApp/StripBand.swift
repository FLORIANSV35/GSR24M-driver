import SwiftUI
import GSRCore

/// The channel strip as on the console, one block after the other: input, EQ, aux sends, pan and routing, interface switches and mute, fader. The knobs
/// are turned with the mouse to note what is set on the console while capturing; the EQ knobs also carry the arrows of the recall.
struct StripBand: View {
    @EnvironmentObject var model: RecallModel
    var scrolls = true                      // false only for the preview image, which cannot draw scroll views

    private var ch: Int { model.channel }

    private func manual<T>(_ path: WritableKeyPath<ManualEQ, T>) -> Binding<T> {
        Binding(get: { model.manual(channel: ch)[keyPath: path] }, set: { v in var m = model.manual(channel: ch); m[keyPath: path] = v; model.setManual(m, channel: ch) })
    }

    private func strip<T>(_ path: WritableKeyPath<StripSheet, T>) -> Binding<T> {
        Binding(get: { model.strip(channel: ch)[keyPath: path] }, set: { v in var s = model.strip(channel: ch); s[keyPath: path] = v; model.setStrip(s, channel: ch) })
    }

    private func aux(_ i: Int) -> Binding<Double?> {
        Binding(get: { model.strip(channel: ch).aux[i] }, set: { v in var s = model.strip(channel: ch); s.aux[i] = v; model.setStrip(s, channel: ch) })
    }

    // MARK: formats

    private static func round2(_ v: Double) -> Double { let m = pow(10, floor(log10(v)) - 1); return (v / m).rounded() / (1 / m) }
    private func gainText(_ v: Double) -> String { String(format: "%+.1f", v) }
    private func freqText(_ v: Double) -> String { v >= 1000 ? String(format: "%.2gk", v / 1000) : String(format: "%.0f", v) }
    private func auxText(_ v: Double) -> String { v <= -90 ? "off" : String(format: "%+.0f", v) }

    private func eqDial(_ label: String, _ knob: EQGuide.Knob, _ path: WritableKeyPath<ManualEQ, Double?>, _ scale: DialScale,
                        colour: Color, format: @escaping (Double) -> String, snap: @escaping (Double) -> Double, estimate: Double?) -> some View {
        DialKnob(label: label, scale: scale, value: manual(path), estimate: estimate, colour: colour, format: format, snap: snap, size: 44,
                 guided: true, amount: model.advisor.shown(knob), tolerance: EQGuide.tolerance(knob),
                 active: model.activeKnob == knob, suggested: model.activeKnob == nil && model.advisor.suggested?.knob == knob)
    }

    private func block<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.55))
            content()
        }
        .padding(8)
        .background(Color(red: 0.15, green: 0.18, blue: 0.2), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: blocks

    private var input: some View {
        let line = model.strip(channel: ch).line == true
        return block("INPUT") {
            DialKnob(label: "GAIN", scale: line ? .lineGain : .micGain, value: strip(\.gain), colour: Color(red: 0.55, green: 0.1, blue: 0.1),
                     format: { String(format: "%+.0f", $0) }, snap: { $0.rounded() }, size: 54)
            HStack(spacing: 4) { StateButton(title: "LINE", state: strip(\.line), width: 50); StateButton(title: "+48V", state: strip(\.phantom), width: 50) }
            HStack(spacing: 4) { StateButton(title: "POL", state: strip(\.polarity), width: 50); StateButton(title: "HPF", state: strip(\.hpf), width: 50) }
        }
    }

    private var eq: some View {
        let est = model.estimate(channel: ch)
        func bell(_ b: EQSettings.Bell?, freq: Bool) -> Double? {
            guard let b, !b.isFlat else { return nil }
            return freq ? b.freq : (abs(b.gain) < 1.5 ? nil : EQFit.knobQ(effective: b.q, gain: b.gain))
        }
        let blue = Color(red: 0.1, green: 0.4, blue: 0.95), grey = Color(white: 0.5), black = Color(white: 0.08)
        let g1: (Double) -> Double = { ($0 * 2).rounded() / 2 }, f2: (Double) -> Double = { Self.round2($0) }, q1: (Double) -> Double = { ($0 * 10).rounded() / 10 }
        return block("EQ") {
            VStack(alignment: .leading, spacing: 2) {                           // one column of knobs, from the top of the strip to the bottom
                eqRow("HF", first: true) { eqDial("G", .hf, \.hf, .gain, colour: blue, format: gainText, snap: g1, estimate: est?.hf) }
                eqRow("HM", first: true) { eqDial("Q", .hmfQ, \.hmfQ, .q, colour: grey, format: { String(format: "%.1f", $0) }, snap: q1, estimate: bell(est?.hmf, freq: false)) }
                eqRow("HM") { eqDial("F", .hmfFreq, \.hmfFreq, .hmfFreq, colour: black, format: freqText, snap: f2, estimate: bell(est?.hmf, freq: true)) }
                eqRow("HM") { eqDial("G", .hmfGain, \.hmfGain, .gain, colour: blue, format: gainText, snap: g1, estimate: est?.hmf.gain) }
                eqRow("LM", first: true) { eqDial("Q", .lmfQ, \.lmfQ, .q, colour: grey, format: { String(format: "%.1f", $0) }, snap: q1, estimate: bell(est?.lmf, freq: false)) }
                eqRow("LM") { eqDial("F", .lmfFreq, \.lmfFreq, .lmfFreq, colour: black, format: freqText, snap: f2, estimate: bell(est?.lmf, freq: true)) }
                eqRow("LM") { eqDial("G", .lmfGain, \.lmfGain, .gain, colour: blue, format: gainText, snap: g1, estimate: est?.lmf.gain) }
                eqRow("LF", first: true) { eqDial("G", .lf, \.lf, .gain, colour: blue, format: gainText, snap: g1, estimate: est?.lf) }
            }
            HStack(spacing: 6) {
                StateButton(title: "EQ IN", state: strip(\.eqIn), width: 50)
                VStack(alignment: .leading, spacing: 4) {
                    Button("Use the estimate") { useEstimate() }.disabled(est == nil).controlSize(.small)
                    Button("Clear the EQ") { model.setManual(ManualEQ(), channel: ch) }.disabled(model.manual(channel: ch).isEmpty).controlSize(.small)
                }
            }
            Group {
                if est == nil { Text("The estimate needs the reference of this channel (EQ IN up)").foregroundStyle(.white.opacity(0.55)) }
                else if let r = model.manualResidual(channel: ch) {
                    Text(String(format: "These values reproduce the curve within %.1f dB", r)).foregroundStyle(r < 1.5 ? Color.green : Color.orange)
                } else { Text("Cyan marker: the estimate of the app. Double-click clears a knob").foregroundStyle(.white.opacity(0.55)) }
            }.font(.system(size: 9)).frame(width: 185, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One knob of the EQ column; the name of the section stands at the left of its first knob.
    private func eqRow<C: View>(_ title: String, first: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 0) {
            Text(first ? title : "").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).frame(width: 26, alignment: .leading)
            content()
        }
    }

    private var auxBlock: some View {
        let cream = Color(red: 0.75, green: 0.7, blue: 0.5)
        func knob(_ i: Int) -> some View { DialKnob(label: "AUX \(i + 1)", scale: .aux, value: aux(i), colour: cream, format: auxText, snap: { $0 < -92 ? StripSheet.off : $0.rounded() }, size: 40) }
        return block("AUX") {                                              // one column, as on the strip: 1 and 2, 3 and 4 with their Pre switch, 5 and 6
            knob(0); knob(1); knob(2); knob(3)
            StateButton(title: "PRE 3-4", state: strip(\.auxPre34), width: 70)
            knob(4); knob(5)
        }
    }

    private var panBlock: some View {
        block("PAN / BUS") {
            DialKnob(label: "PAN", scale: .pan, value: strip(\.pan), colour: Color(white: 0.3),
                     format: { $0 == 0 ? "C" : String(format: "%@%.0f", $0 < 0 ? "L" : "R", abs($0)) }, snap: { abs($0) < 6 ? 0 : ($0 / 5).rounded() * 5 }, size: 46)
            HStack(spacing: 4) { StateButton(title: "L-R", state: strip(\.routeLR), width: 44); StateButton(title: "M", state: strip(\.routeMono), width: 44) }
            HStack(spacing: 4) { StateButton(title: "1-2", state: strip(\.route12), width: 44); StateButton(title: "3-4", state: strip(\.route34), width: 44) }
        }
    }

    private var interfaceBlock: some View {
        block("INTERFACE") {
            HStack(spacing: 4) { StateButton(title: "A", state: strip(\.switchA), width: 40); StateButton(title: "C", state: strip(\.switchC), width: 40) }     // as on the strip: A C over B D
            HStack(spacing: 4) { StateButton(title: "B", state: strip(\.switchB), width: 40); StateButton(title: "D", state: strip(\.switchD), width: 40) }
            StateButton(title: "MUTE", state: strip(\.mute), width: 84)
        }
    }

    /// The fader by hand (this also sets its MIDI position) or from the console: the button reads the position the console sends.
    private var faderBlock: some View {
        let fader = Binding<Double?>(get: { model.strip(channel: ch).fader },
                                     set: { v in var s = model.strip(channel: ch); s.fader = v; s.faderMIDI = v.map { StripSheet.faderMIDI(db: $0) }; model.setStrip(s, channel: ch) })
        let waiting = model.faderCapture == ch
        return block("LEVEL") {
            FaderView(value: fader)
            Button(waiting ? "Move the fader…" : "Capture fader\nlevel (MIDI)") { model.captureFaderLevel(channel: ch) }
                .controlSize(.small).multilineTextAlignment(.center).disabled(waiting || !model.canNote(channel: ch))
            Button("Recall fader") { model.recallFader(channel: ch) }
                .controlSize(.small).disabled(model.strip(channel: ch).faderMIDI == nil || !model.canNote(channel: ch))
            if let v = model.strip(channel: ch).faderMIDI { Text("MIDI \(v)").font(.system(size: 9).monospacedDigit()).foregroundStyle(.white.opacity(0.6)) }
        }
    }

    private func useEstimate() {
        guard let est = model.estimate(channel: ch) else { return }
        var m = model.manual(channel: ch)
        func g(_ v: Double) -> Double { (v * 2).rounded() / 2 }
        func bellValues(_ b: EQSettings.Bell, gain: WritableKeyPath<ManualEQ, Double?>, freq: WritableKeyPath<ManualEQ, Double?>, q: WritableKeyPath<ManualEQ, Double?>) {
            if m[keyPath: gain] == nil { m[keyPath: gain] = g(b.gain) }
            guard !b.isFlat else { return }
            if m[keyPath: freq] == nil { m[keyPath: freq] = Self.round2(b.freq) }
            if m[keyPath: q] == nil, abs(b.gain) >= 1.5 { m[keyPath: q] = (EQFit.knobQ(effective: b.q, gain: b.gain) * 10).rounded() / 10 }
        }
        if m.hf == nil { m.hf = g(est.hf) }
        if m.lf == nil { m.lf = g(est.lf) }
        bellValues(est.hmf, gain: \.hmfGain, freq: \.hmfFreq, q: \.hmfQ)
        bellValues(est.lmf, gain: \.lmfGain, freq: \.lmfFreq, q: \.lmfQ)
        model.setManual(m, channel: ch)
    }

    // MARK: console rotaries

    /// Rotaries 1 to 6, 11 and 12 turn the eight EQ knobs from the top of the strip to the bottom, 7 the input gain, 8 the pan, 9 and 10 the first
    /// aux sends (3 and 4 with Shift held). The rotary is absolute (0 to 127): the knob goes to the position it has on the console.
    private static let eqPots: [Int: (WritableKeyPath<ManualEQ, Double?>, DialScale, (Double) -> Double)] = [
        1: (\.hf, .gain, { ($0 * 2).rounded() / 2 }),
        2: (\.hmfQ, .q, { ($0 * 10).rounded() / 10 }),
        3: (\.hmfFreq, .hmfFreq, { round2($0) }),
        4: (\.hmfGain, .gain, { ($0 * 2).rounded() / 2 }),
        5: (\.lmfQ, .q, { ($0 * 10).rounded() / 10 }),
        6: (\.lmfFreq, .lmfFreq, { round2($0) }),
        11: (\.lmfGain, .gain, { ($0 * 2).rounded() / 2 }),
        12: (\.lf, .gain, { ($0 * 2).rounded() / 2 }),
    ]

    private static func position(_ scale: DialScale, _ value: Int, _ snap: (Double) -> Double) -> Double {
        let a0 = scale.ticks.first!.angle, a1 = scale.ticks.last!.angle
        return snap(scale.value(angle: a0 + Double(min(127, max(0, value))) / 127 * (a1 - a0)))
    }

    private func turn(_ move: RecallModel.PotMove) {
        guard model.canNote(channel: ch) else { return }
        let v = move.value
        if let (path, scale, snap) = Self.eqPots[move.pot] {
            var m = model.manual(channel: ch); m[keyPath: path] = Self.position(scale, v, snap); model.setManual(m, channel: ch)
            return
        }
        var s = model.strip(channel: ch)
        switch move.pot {
        case 7: s.gain = Self.position(s.line == true ? .lineGain : .micGain, v) { $0.rounded() }
        case 8: s.pan = Self.position(.pan, v) { abs($0) < 6 ? 0 : ($0 / 5).rounded() * 5 }
        case 9, 10: s.aux[move.pot - 9 + (move.shift ? 2 : 0)] = Self.position(.aux, v) { $0 < -92 ? StripSheet.off : $0.rounded() }
        default: return
        }
        model.setStrip(s, channel: ch)
    }

    private var blocks: some View { HStack(alignment: .top, spacing: 6) { input; eq; auxBlock; panBlock; interfaceBlock; faderBlock } }

    var body: some View {
        let can = model.canNote(channel: ch)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Channel \(ch)").font(.headline).foregroundStyle(.white)
                Text(can ? "Turn the knobs and press the switches as they are on the console; they are kept with the capture" : "Capture this channel, or choose a target that has it, to note its settings")
                    .font(.caption).foregroundStyle(.white.opacity(0.65))
                Spacer()
                Button("Clear the channel") { model.setStrip(StripSheet(), channel: ch); model.setManual(ManualEQ(), channel: ch) }.controlSize(.small).disabled(!can)
            }
            Group {
                if scrolls { ScrollView(.horizontal, showsIndicators: false) { blocks } } else { blocks }
            }
            .opacity(can ? 1 : 0.45).allowsHitTesting(can)
        }
        .onAppear { model.requestEstimate(channel: ch); model.startPots() }
        .onDisappear { model.stopPots() }
        .onReceive(model.$potMove) { if let move = $0 { turn(move) } }
        .onChange(of: ch) { c in model.requestEstimate(channel: c) }
        .onChange(of: model.workingCount) { _ in model.requestEstimate(channel: model.channel) }
        .onChange(of: model.targetName) { _ in model.requestEstimate(channel: model.channel) }
    }
}

// MARK: preview image (development: `GSRApp --render-strip file.png`)

@MainActor
enum StripPreview {
    static func render(to path: String) {
        let model = RecallModel()
        model.loadPreview()
        let view = StripBand(scrolls: false).environmentObject(model).padding(12).background(Theme.panel).preferredColorScheme(.dark)
        let r = ImageRenderer(content: view); r.scale = 2
        if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
