import SwiftUI
import GSRCore

/// Analysis plug-ins (AU effects) fed with two channels of the card: two inputs of the console, or two outputs of the Mac towards the console.
/// There is no output: whatever the plug-ins render is thrown away.
struct AnalyzerView: View {
    @EnvironmentObject var model: AnalyzerModel
    @EnvironmentObject var app: AppModel

    private func channelTitle(_ ch: Int) -> String {
        let names = model.status.names[model.source == .consoleInputs ? 0 : 1]
        let n = ch < names.count ? names[ch] : ""
        return n.isEmpty ? "CH\(ch + 1)" : "\(ch + 1)  \(n)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !app.viaDaemon { Text("The analyzer reads the audio from the gsrd daemon.").foregroundStyle(.orange) }
            routing
            if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.white.opacity(0.85)) }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.items) { SlotView(item: $0) }
                    if model.items.isEmpty { Text("No plug-in yet. Add one with the menu above.").foregroundStyle(.white.opacity(0.7)) }
                }
                .padding(.trailing, 6)
            }
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }

    private var routing: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("", selection: $model.source) {
                    ForEach(RingTap.Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 250).labelsHidden()
                channelPicker("L", $model.left)
                channelPicker("R", $model.right)
                Spacer()
            }
            HStack(spacing: 10) {
                VStack(spacing: 3) { Meter(peak: model.status.peakL); Meter(peak: model.status.peakR) }.frame(width: 120)
                Text(statusText).font(.callout).foregroundStyle(model.status.streaming ? .white.opacity(0.8) : .orange)
                Spacer()
                Menu {
                    ForEach(Dictionary(grouping: model.plugins, by: \.maker).keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, id: \.self) { maker in
                        Menu(maker) {
                            ForEach(model.plugins.filter { $0.maker == maker }) { p in Button(p.title) { Task { await model.add(p) } } }
                        }
                    }
                } label: { Label("Add plug-in", systemImage: "plus") }
                    .disabled(model.busy || model.items.count >= AnalyzerModel.maxSlots).frame(width: 140)
            }
        }
    }

    private func channelPicker(_ label: String, _ sel: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.white)
            Picker("", selection: sel) { ForEach(0..<32, id: \.self) { Text(channelTitle($0)).tag($0) } }.labelsHidden().frame(width: 130)
        }
    }

    private var statusText: String {
        let s = model.status
        if !s.connected { return "Waiting for gsrd" }
        if !s.streaming { return "Card not streaming" }
        return String(format: "%.1f kHz", s.rate / 1000)
    }
}

private struct Meter: View {
    let peak: Float
    var body: some View {
        let db = peak > 0 ? 20 * log10(Double(peak)) : -90
        let frac = max(0, min(1, (db + 60) / 60))
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.45))
                Capsule().fill(db > -1 ? Color.red : db > -12 ? Color.yellow : Color.green).frame(width: g.size.width * frac)
            }
        }.frame(height: 6)
    }
}

private struct SlotView: View {
    @ObservedObject var item: AnalyzerItem
    @EnvironmentObject var model: AnalyzerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.slot.title).font(.headline).foregroundStyle(.white)
                Text(String(format: "%.0f %%", item.load * 100)).font(.caption.monospaced()).foregroundStyle(item.load > 0.8 ? .red : .white.opacity(0.6))
                Spacer()
                Button(item.detached ? "Bring back" : "Window") { Task { if item.detached { await item.attach() } else { await item.detach() } } }
                Button("Remove") { model.remove(item) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.bar, in: RoundedRectangle(cornerRadius: 6))
            if let e = item.error { Text(e).font(.callout).foregroundStyle(.red) }
            if item.detached {
                Text("Open in its own window").foregroundStyle(.white.opacity(0.7)).padding(8)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    PluginHost(view: item.host).frame(width: item.size.width, height: item.size.height)
                }
                .frame(height: min(item.size.height + 14, 560))
            }
        }
        .padding(8)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
    }
}
