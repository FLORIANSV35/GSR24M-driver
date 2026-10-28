import SwiftUI
import Charts
import GSRCore

struct RecallView: View {
    @EnvironmentObject var model: RecallModel
    @EnvironmentObject var app: AppModel

    private func color(_ percent: Double) -> Color { percent >= 95 ? .green : percent >= 75 ? .yellow : .red }

    var body: some View {
        ScrollView(.vertical) { content }
            .sheet(isPresented: $model.askChecklist) { ChecklistSheet() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !app.viaDaemon {
                Text("EQ recall needs the gsrd daemon and the GS-R24M audio device.").foregroundStyle(.orange)
            }
            header
            channelGrid
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) { score; controls }.frame(width: 225, alignment: .topLeading)
                chart
            }
            StripBand()
            if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.white.opacity(0.85)) }
        }
        .padding(.trailing, 6)
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
                Divider()
                Button("Recall all faders (\(model.fadersNoted.count))") { model.recallAllFaders() }.disabled(model.fadersNoted.isEmpty)
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
            Text(model.pendingMode == .capturingAll ? "Press A and B on every channel (all are measured at once)." : "Press A and B on the channel to measure.").font(.callout)
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
