import SwiftUI
import AppKit
import GSRCore

/// Only one copy of the application at a time: two of them would both talk to the daemon and to the MIDI agent. A second launch brings the first
/// window to the front and quits. The copy the updater starts (`--after-update`) first waits for the old one, which is quitting.
enum SingleInstance {
    static func enforce() {
        guard let id = Bundle.main.bundleIdentifier, !CommandLine.arguments.contains("--render-midi") else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        func others() -> [NSRunningApplication] { NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != me && !$0.isTerminated } }
        if CommandLine.arguments.contains("--after-update") {
            for _ in 0..<80 where !others().isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        }
        if let other = others().first {
            other.activate(options: [.activateAllWindows])
            exit(0)
        }
    }
}

@main
struct GSRApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updates = UpdateChecker()
    @StateObject private var recall = RecallModel()
    @StateObject private var midi = MIDIModel()
    init() {
        SingleInstance.enforce()
        if let i = CommandLine.arguments.firstIndex(of: "--render-strip"), i + 1 < CommandLine.arguments.count {
            StripPreview.render(to: CommandLine.arguments[i + 1]); exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-midi"), i + 1 < CommandLine.arguments.count {
            MIDIPreview.render(to: CommandLine.arguments[i + 1]); exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-dev"), i + 1 < CommandLine.arguments.count {
            DevPreview.render(to: CommandLine.arguments[i + 1]); exit(0)
        }
    }
    var body: some Scene {
        WindowGroup("Allen and Heath Firewire") {
            ContentView().environmentObject(model).environmentObject(updates).environmentObject(recall).environmentObject(midi)
                .onAppear { if !CommandLine.arguments.contains("--demo") { updates.check() } }
                .frame(minWidth: 760, minHeight: 640)
                .preferredColorScheme(.dark)
        }
    }
}

enum GlobalTab: String, CaseIterable { case monitor = "Monitor", bus = "Bus", system = "System", info = "Info", diag = "Diagnostic", dev = "Dev" }
enum DeviceTab: String, CaseIterable { case general = "General", channels = "Channels", recall = "Recall", midi = "MIDI", firmware = "Firmware" }

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updates: UpdateChecker
    @State private var gTab = GlobalTab.monitor
    @State private var restarting: Services.Piece?
    @State private var restartMessage: String?
    @State private var dTab = CommandLine.arguments.contains("--recall") ? DeviceTab.recall : CommandLine.arguments.contains("--midi") ? DeviceTab.midi : DeviceTab.general
    @State private var importing = false
    @AppStorage("opMode") private var opMode = "Normal Mode"
    @AppStorage("hideCapture") private var hideCapture = false
    @AppStorage("hidePlayback") private var hidePlayback = false
    @AppStorage("hiddenChannels") private var hiddenChannels = ""
    @AppStorage("showHiddenChannels") private var showHidden = false
    @State private var renaming: RenameTarget?

    struct RenameTarget: Identifiable {
        let id = UUID()
        let dir: ChannelNameStore.Direction
        let channel: Int
        let original: String
    }

    var body: some View {
        VStack(spacing: 8) {
            topStrip
            if model.demo {
                Text("DEMO: simulated GS-R24. These values do not come from the card.")
                    .font(.callout.bold()).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding(6)
                    .background(.yellow, in: RoundedRectangle(cornerRadius: 6))
            }
            if dTab != .recall && dTab != .midi {          // the Recall and MIDI tabs need the whole window
                Bar(title: "Global Settings")
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        TabRow(items: GlobalTab.allCases, title: { $0.rawValue }, selection: $gTab)
                        ScrollView { globalContent.frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }
                .frame(height: 330)
            }
            Bar(title: "Device Settings")
            HStack(alignment: .top, spacing: 10) {
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        TabRow(items: DeviceTab.allCases, title: { $0.rawValue }, selection: $dTab)
                        ScrollView { deviceContent.frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }
                VStack(spacing: 8) {
                    Bar(title: "Devices")
                    deviceList
                    Spacer()
                }
                .frame(width: 210)
            }
        }
        .padding(10)
        .background(Theme.window)
        .sheet(item: $renaming) { t in
            RenameSheet(target: t, onSave: { newName in
                if let d = model.selected { model.setName(d, t.dir, channel: t.channel, name: newName) }
            })
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .data]) { result in
            if case .success(let url) = result {
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                model.load(url)
            }
        }
    }

    // MARK: top strip

    private var topStrip: some View {
        HStack(spacing: 10) {
            Text(model.demo ? "Demonstration" : (model.fileLabel.map { "Report: \($0)" } ?? (model.viaDaemon ? "Connected to the gsrd daemon" : "Reading the card directly (daemon not running)")))
                .font(.callout).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            if model.busy { ProgressView().controlSize(.small) }
            Spacer()
            switch updates.state {
            case .available(let v):
                Button("Update \(v): install") { updates.install() }.tint(.orange).buttonStyle(.borderedProminent)
            case .downloading: HStack(spacing: 4) { ProgressView().controlSize(.small); Text("Downloading…").font(.callout) }
            case .opened: Text("Installer opened: the application restarts when it is done").font(.callout).foregroundStyle(.green)
            case .restarting: HStack(spacing: 4) { ProgressView().controlSize(.small); Text("Restarting…").font(.callout).foregroundStyle(.green) }
            case .failed(let m): Text("Update: \(m)").font(.callout).foregroundStyle(.orange).lineLimit(1)
            default: EmptyView()
            }
            Toggle("GSR24M demo", isOn: $model.demo).toggleStyle(.checkbox)
            Button("Refresh") { model.refresh() }.disabled(model.busy || model.demo)
            Button("Open a report…") { importing = true }
        }
    }

    // MARK: device list

    private var deviceList: some View {
        VStack(spacing: 6) {
            if model.devices.isEmpty {
                Text("No device").foregroundStyle(.white.opacity(0.6)).padding(.top, 8)
            }
            ForEach(model.devices) { d in
                let sel = d.id == model.selected?.id
                HStack(spacing: 8) {
                    Image(systemName: "slider.vertical.3").font(.title2).foregroundStyle(.orange)
                    Text(d.report.nickName.isEmpty ? d.kind.rawValue : d.report.nickName)
                        .foregroundStyle(Theme.boxText).lineLimit(1).frame(maxWidth: .infinity)
                    VStack(spacing: 4) {
                        Image(systemName: "clock").foregroundStyle(Theme.boxText)
                        Image(systemName: d.report.locked ? "lock.fill" : "lock.open.fill")
                            .foregroundStyle(d.report.locked ? .green : .orange)
                    }
                }
                .padding(8)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(sel ? Color.accentColor : .clear, lineWidth: 2))
                .onTapGesture { model.selectedID = d.id }
            }
        }
    }

    // MARK: global tabs

    @ViewBuilder private var globalContent: some View {
        switch gTab {
        case .monitor: LoadPanel().environmentObject(model.load)
        case .bus: busTab
        case .system: systemTab
        case .info: infoTab
        case .diag: diagTab
        case .dev: DevView(model: model)
        }
    }

    private var busTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let d = model.selected {
                let r = d.report
                HStack { FieldLabel("Master"); ValueBox(text: d.kind.rawValue, width: 150)
                    Image(systemName: r.locked ? "lock.fill" : "lock.open.fill").foregroundStyle(r.locked ? .green : .orange)
                    Text(r.locked ? "Locked" : "Not locked").foregroundStyle(.white) }
                HStack { FieldLabel("Sample Rate")
                    Picker("", selection: Binding(get: { r.currentRate ?? 0 }, set: { model.setRate($0) })) {
                        if let c = r.currentRate, !r.supportedRates.contains(c) { Text("\(c) Hz").tag(c) }
                        ForEach(r.supportedRates, id: \.self) { Text("\($0) Hz").tag($0) }
                    }.labelsHidden().frame(width: 150).disabled(!(model.demo || model.viaDaemon)) }
                HStack { FieldLabel("Sync Source")
                    Picker("", selection: Binding(get: { r.clockSourceID }, set: { model.setSource($0) })) {
                        ForEach(r.supportedSources, id: \.self) { id in
                            Text(r.clockSources.first { $0.id == id }?.label ?? id).tag(id)
                        }
                    }.labelsHidden().frame(width: 150).disabled(!(model.demo || model.viaDaemon)) }
                HStack { FieldLabel("Operation Mode")
                    Picker("", selection: Binding(get: { model.viaDaemon ? DaemonInfo.modeName(forLead: model.live?.leadMs ?? 80) : opMode },
                                                  set: { opMode = $0; model.setOperationMode($0) })) {
                        ForEach(DaemonInfo.modeLeads.map(\.name), id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 170).disabled(!(model.demo || model.viaDaemon)) }
                if model.viaDaemon { operationModeTable(current: DaemonInfo.modeName(forLead: model.live?.leadMs ?? 80)) }
                if model.viaDaemon {
                    Text("Changing the rate, the source or the mode restarts the audio streams (2 to 3 s). Word Clock: the card only locks if the signal is at the chosen rate; otherwise (or if the signal disappears) the daemon goes back to the internal clock by itself.")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                    if !model.daemonNote.isEmpty { Text(model.daemonNote).font(.caption).foregroundStyle(.yellow) }
                } else if !model.demo {
                    Text("Settings are read-only: the gsrd daemon does not answer.")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            } else { Text("No device.").foregroundStyle(.white) }
        }
    }

    /// The four operation modes and what they cost. The row of the active mode is highlighted.
    private func operationModeTable(current: String) -> some View {
        let rate = Double(model.live?.rate ?? 48000)
        return VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow { Text("Mode"); Text("Lead"); Text("Output"); Text("Input") }
                    .font(.caption2.bold()).foregroundStyle(.white.opacity(0.6))
                ForEach(DaemonInfo.modeLeads, id: \.name) { m in
                    let on = m.name == current
                    let out = DaemonInfo.outputLatencyMs(forLead: m.ms), inp = DaemonInfo.inputSafetyMs(forLead: m.ms)
                    GridRow {
                        Text(m.name).fontWeight(on ? .bold : .regular)
                        Text("\(m.ms) ms")
                        Text("≈ \(out) ms (\(Int(rate * Double(out) / 1000)) fr.)")
                        Text("≈ \(inp) ms")
                    }
                    .font(.caption).foregroundStyle(on ? Color.yellow : .white)
                }
            }
            if let i = model.live.map({ $0.minus(model.counterBase) }) {
                Text("Longest gap: \(String(format: "%.1f", i.maxGapMs)) ms · late input: \(i.inLate) fr. · late output: \(i.outLate) fr.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(.top, 4)
    }

    private var systemTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoRow("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
            infoRow("FireWire controller (OHCI)", "not read in this version")
            infoRow("Driver", model.viaDaemon ? "gsrd daemon + GS-R24M audio plug-in" : "none: read-only through IOFireWireLib")
            Divider()
            Text("Restart").font(.headline).foregroundStyle(.white)
            ForEach(Services.Piece.allCases, id: \.self) { piece in
                HStack(spacing: 10) {
                    Button(piece.rawValue) { restartPiece(piece) }.frame(width: 130).disabled(restarting != nil)
                    Text(restarting == piece ? "restarting…" : piece.detail).font(.caption).foregroundStyle(.white.opacity(0.65))
                }
            }
            if let m = restartMessage { Text(m).font(.callout).foregroundStyle(.white) }
        }
    }

    private func restartPiece(_ piece: Services.Piece) {
        restarting = piece; restartMessage = nil
        Services.restart(piece) { error in
            restarting = nil
            restartMessage = error.map { "\(piece.rawValue): \($0)" } ?? "\(piece.rawValue) restarted."
            model.refresh()
        }
    }

    private var infoTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let d = model.selected {
                let r = d.report
                infoRow("Appareil", d.kind.rawValue)
                infoRow("Manufacturer", r.vendor); infoRow("Model", r.model)
                if let v = r.vendorID { infoRow("Vendor_ID", String(format: "0x%06X", v)) }
                if let v = r.modelID { infoRow("Model_ID", String(format: "0x%06X", v)) }
                if let v = r.unitSpecID { infoRow("Unit_Spec_ID", String(format: "0x%06X (%d)", v, v)) }
                if let g = r.guid { infoRow("GUID", String(format: "0x%016llX", g)) }
                infoRow("Firmware DICE", r.version.isEmpty ? "—" : r.version)
            }
            HStack(alignment: .top) { FieldLabel("Application"); Text(UpdateChecker.currentVersion).foregroundStyle(.white)
                Button(updates.state == .checking ? "Checking…" : "Check for updates") { updates.check(manual: true) }
                    .disabled(updates.state == .checking || updates.state == .downloading)
                if updates.state == .upToDate { Text("up to date").foregroundStyle(.green) }
            }
        }
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) { FieldLabel(k); Text(v).foregroundStyle(.white).textSelection(.enabled) }
    }

    // MARK: diagnostic

    private struct Check: Identifiable { let id = UUID(); let ok: Bool; let text: String }
    private func checks(_ d: Device) -> [Check] {
        let r = d.report
        var live: [Check] = []
        if let i = model.live.map({ $0.minus(model.counterBase) }), !model.demo {
            live = [
                Check(ok: true, text: "gsrd daemon reachable (owns the card: \(i.owned ? "yes" : "no"))"),
                Check(ok: i.isStreaming, text: "Audio streaming"),
                Check(ok: i.cipErrors == 0 && i.dbcJumps == 0, text: "No packet errors (CIP \(i.cipErrors), DBC jumps \(i.dbcJumps))"),
                Check(ok: !model.load.active(.lateIn), text: "No late input frames in the last 30 s (total since the daemon started or since Reset: \(i.inLate))"),
            ]
        }
        return live + [
            Check(ok: true, text: "Device recognised: \(d.kind.rawValue)"),
            Check(ok: r.tcatCategory == 0x04, text: "TCAT category 0x04 (standard DICE)"),
            Check(ok: r.locked, text: "Clock locked"),
            Check(ok: r.currentRate.map { r.supportedRates.contains($0) } ?? false, text: "Rate is in the list the card announces"),
            Check(ok: !r.tx.isEmpty && !r.rx.isEmpty, text: "Input and output streams announced (\(r.captureChannels) inputs, \(r.playbackChannels) outputs)"),
        ]
    }

    private var diagTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let d = model.selected {
                ForEach(checks(d)) { c in
                    HStack(spacing: 6) {
                        Image(systemName: c.ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(c.ok ? .green : .red)
                        Text(c.text).foregroundStyle(.white)
                    }
                }
                Divider()
            }
            ForEach(Array(model.log.enumerated()), id: \.offset) { _, l in
                Text(l).font(.callout.monospaced()).foregroundStyle(.white).textSelection(.enabled)
            }
            Button("Reset counters") { model.resetCounters() }.disabled(model.live == nil)
            Button("Copy the diagnostic") {
                var t = model.log.joined(separator: "\n")
                if let d = model.selected { t += "\n" + checks(d).map { ($0.ok ? "OK  " : "KO  ") + $0.text }.joined(separator: "\n") }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
            }
        }
    }

    // MARK: device tabs

    @ViewBuilder private var deviceContent: some View {
        if let d = model.selected {
            switch dTab {
            case .general: general(d)
            case .channels: channels(d)
            case .recall: RecallView()
            case .midi: MIDIView()
            case .firmware:
                VStack(alignment: .leading, spacing: 8) {
                    infoRow("Firmware DICE", d.report.version.isEmpty ? "—" : d.report.version)
                    Text("Display only. This application never writes firmware to the card.")
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("No GS-R24 or ZED-R16 detected").font(.title3.bold()).foregroundStyle(.white)
                Text("This application only drives these two devices. See the Diagnostic tab for the reason.")
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func general(_ d: Device) -> some View {
        let r = d.report
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) { FieldLabel("Device description:")
                Text(r.vendor + (r.model.isEmpty ? "" : " " + r.model)).foregroundStyle(Theme.boxText)
                    .padding(8).frame(width: 300, height: 56, alignment: .topLeading)
                    .background(Theme.box, in: RoundedRectangle(cornerRadius: 4)) }
            HStack { FieldLabel("Nickname:")
                Text(r.nickName.isEmpty ? "—" : r.nickName).foregroundStyle(Theme.boxText)
                    .frame(width: 300).padding(.vertical, 5).background(Color(white: 0.62), in: RoundedRectangle(cornerRadius: 4)) }
            HStack { FieldLabel("Measured Sampling Rate:"); ValueBox(text: r.currentRate.map { "\($0) Hz" } ?? "—") }
            HStack { FieldLabel("Status:"); ValueBox(text: r.locked ? "normal" : "not locked") }
        }
    }

    private func hiddenSet() -> Set<String> { Set(hiddenChannels.split(separator: "|").map(String.init)) }
    private func toggleChannel(_ key: String) {
        var s = hiddenSet(); if s.contains(key) { s.remove(key) } else { s.insert(key) }
        hiddenChannels = s.sorted().joined(separator: "|")
    }

    private func channels(_ d: Device) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Toggle("Inputs", isOn: Binding(get: { !hideCapture }, set: { hideCapture = !$0 })).toggleStyle(.checkbox)
                Toggle("Outputs", isOn: Binding(get: { !hidePlayback }, set: { hidePlayback = !$0 })).toggleStyle(.checkbox)
                Toggle("Show hidden channels", isOn: $showHidden).toggleStyle(.checkbox)
                Button("Show all") { hiddenChannels = "" }
            }
            .foregroundStyle(.white)
            if !hideCapture { streamGrid(d, d.report.tx, title: "Inputs (card to Mac)", prefix: "tx", dir: .input) }
            if !hidePlayback { streamGrid(d, d.report.rx, title: "Outputs (Mac to card)", prefix: "rx", dir: .output) }
            HStack {
                Text("Double-click or right-click a channel to rename or hide it. Names are kept on this Mac, never written to the card, and picked up by the audio plug-in for music software (gsrd daemon required).")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button("Original names") { model.resetNames(d) }
            }
        }
    }

    private func streamGrid(_ d: Device, _ streams: [DiceStream], title: String, prefix: String,
                            dir: ChannelNameStore.Direction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(.white)
            ForEach(streams, id: \.index) { s in
                Text("Stream \(s.index): \(s.pcmChannels) channels" + (s.speed.map { ", \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 5)], alignment: .leading, spacing: 5) {
                    ForEach(Array(s.names.map(\.channelShortName).enumerated()), id: \.offset) { i, name in
                        let key = "\(prefix)\(s.index).\(i)"
                        let hidden = hiddenSet().contains(key)
                        let number = streams.filter { $0.index < s.index }.reduce(0) { $0 + $1.pcmChannels } + i + 1
                        let custom = d.report.guid.flatMap { model.names.name(guid: $0, dir, channel: number) }
                        if !hidden || showHidden {
                            ValueBox(text: custom ?? name, width: 114)
                                .fontWeight(custom == nil ? .regular : .semibold)
                                .opacity(hidden ? 0.4 : 1)
                                .help("Canal \(number) · nom d'origine : \(name)")
                                .onTapGesture(count: 2) { renaming = RenameTarget(dir: dir, channel: number, original: custom ?? name) }
                                .contextMenu {
                                    Button("Rename…") { renaming = RenameTarget(dir: dir, channel: number, original: custom ?? name) }
                                    if custom != nil {
                                        Button("Original name") { model.setName(d, dir, channel: number, name: "") }
                                    }
                                    Button(hidden ? "Show this channel" : "Hide this channel") { toggleChannel(key) }
                                }
                        }
                    }
                }
            }
        }
    }
}


struct RenameSheet: View {
    let target: ContentView.RenameTarget
    let onSave: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(target.dir == .input ? "input" : "output") \(target.channel)").font(.headline)
            TextField("Name shown in music software", text: $text)
                .textFieldStyle(.roundedBorder).frame(width: 320)
                .onSubmit { onSave(text); dismiss() }
            Text("Leave empty to go back to the original name.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(text); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .onAppear { text = target.original }
    }
}
