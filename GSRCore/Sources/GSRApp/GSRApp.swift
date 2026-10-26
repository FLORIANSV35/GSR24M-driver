import SwiftUI
import AppKit
import GSRCore

@main
struct GSRApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updates = UpdateChecker()
    var body: some Scene {
        WindowGroup("Allen and Heath Firewire") {
            ContentView().environmentObject(model).environmentObject(updates)
                .onAppear { if !CommandLine.arguments.contains("--demo") { updates.check() } }
                .frame(minWidth: 760, minHeight: 640)
                .preferredColorScheme(.dark)
        }
    }
}

enum GlobalTab: String, CaseIterable { case bus = "Bus", system = "System", info = "Info", diag = "Diagnostic" }
enum DeviceTab: String, CaseIterable { case general = "General", channels = "Channels", firmware = "Firmware" }

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updates: UpdateChecker
    @State private var gTab = GlobalTab.bus
    @State private var dTab = DeviceTab.general
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
                Text("DÉMO : GS-R24 simulée. Ces valeurs ne viennent pas de la carte.")
                    .font(.callout.bold()).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding(6)
                    .background(.yellow, in: RoundedRectangle(cornerRadius: 6))
            }
            Bar(title: "Global Settings")
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    TabRow(items: GlobalTab.allCases, title: { $0.rawValue }, selection: $gTab)
                    ScrollView { globalContent.frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            .frame(height: 330)
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
            Text(model.demo ? "Démonstration" : (model.fileLabel.map { "Rapport : \($0)" } ?? (model.viaDaemon ? "Connecté au démon gsrd" : "Lecture directe de la carte (démon absent)")))
                .font(.callout).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            if model.busy { ProgressView().controlSize(.small) }
            Spacer()
            switch updates.state {
            case .available(let v):
                Button("Mise à jour \(v) : installer") { updates.install() }.tint(.orange).buttonStyle(.borderedProminent)
            case .downloading: HStack(spacing: 4) { ProgressView().controlSize(.small); Text("Téléchargement…").font(.callout) }
            case .opened: Text("Installateur ouvert").font(.callout).foregroundStyle(.green)
            case .failed(let m): Text("Mise à jour : \(m)").font(.callout).foregroundStyle(.orange).lineLimit(1)
            default: EmptyView()
            }
            Toggle("Démo GSR24M", isOn: $model.demo).toggleStyle(.checkbox)
            Button("Actualiser") { model.refresh() }.disabled(model.busy || model.demo)
            Button("Ouvrir un rapport…") { importing = true }
        }
    }

    // MARK: device list

    private var deviceList: some View {
        VStack(spacing: 6) {
            if model.devices.isEmpty {
                Text("Aucun appareil").foregroundStyle(.white.opacity(0.6)).padding(.top, 8)
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
        case .bus: busTab
        case .system: systemTab
        case .info: infoTab
        case .diag: diagTab
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
                    Text("Le changement de fréquence, de source ou de mode redémarre les flux audio (2 à 3 s). Word Clock : la carte ne verrouille que si le signal est à la fréquence choisie ; sinon (ou si le signal disparaît), le démon revient seul sur l'horloge interne.")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                    if !model.daemonNote.isEmpty { Text(model.daemonNote).font(.caption).foregroundStyle(.yellow) }
                } else if !model.demo {
                    Text("Réglages en lecture seule : le démon gsrd ne répond pas.")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            } else { Text("Aucun appareil.").foregroundStyle(.white) }
        }
    }

    /// The four operation modes and what they cost. The row of the active mode is highlighted.
    private func operationModeTable(current: String) -> some View {
        let rate = Double(model.live?.rate ?? 48000)
        return VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow { Text("Mode"); Text("Avance"); Text("Sortie"); Text("Entrée") }
                    .font(.caption2.bold()).foregroundStyle(.white.opacity(0.6))
                ForEach(DaemonInfo.modeLeads, id: \.name) { m in
                    let on = m.name == current
                    let out = DaemonInfo.outputLatencyMs(forLead: m.ms), inp = DaemonInfo.inputSafetyMs(forLead: m.ms)
                    GridRow {
                        Text(m.name).fontWeight(on ? .bold : .regular)
                        Text("\(m.ms) ms")
                        Text("≈ \(out) ms (\(Int(rate * Double(out) / 1000)) tr.)")
                        Text("≈ \(inp) ms")
                    }
                    .font(.caption).foregroundStyle(on ? Color.yellow : .white)
                }
            }
            if let i = model.live {
                Text("Plus long trou : \(String(format: "%.1f", i.maxGapMs)) ms · retard entrée : \(i.inLate) tr. · retard sortie : \(i.outLate) tr.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(.top, 4)
    }

    private var systemTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoRow("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
            infoRow("Contrôleur FireWire (OHCI)", "pas encore lu dans cette version")
            infoRow("Pilote", model.viaDaemon ? "démon gsrd + plug-in audio GS-R24M" : "aucun : lecture seule via IOFireWireLib")
        }
    }

    private var infoTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let d = model.selected {
                let r = d.report
                infoRow("Appareil", d.kind.rawValue)
                infoRow("Fabricant", r.vendor); infoRow("Modèle", r.model)
                if let v = r.vendorID { infoRow("Vendor_ID", String(format: "0x%06X", v)) }
                if let v = r.modelID { infoRow("Model_ID", String(format: "0x%06X", v)) }
                if let v = r.unitSpecID { infoRow("Unit_Spec_ID", String(format: "0x%06X (%d)", v, v)) }
                if let g = r.guid { infoRow("GUID", String(format: "0x%016llX", g)) }
                infoRow("Firmware DICE", r.version.isEmpty ? "—" : r.version)
            }
            HStack(alignment: .top) { FieldLabel("Application"); Text(UpdateChecker.currentVersion).foregroundStyle(.white)
                Button(updates.state == .checking ? "Recherche…" : "Rechercher une mise à jour") { updates.check(manual: true) }
                    .disabled(updates.state == .checking || updates.state == .downloading)
                if updates.state == .upToDate { Text("à jour").foregroundStyle(.green) }
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
        if let i = model.live, !model.demo {
            live = [
                Check(ok: true, text: "Démon gsrd joignable (propriétaire de la carte : \(i.owned ? "oui" : "non"))"),
                Check(ok: i.isStreaming, text: "Flux audio en marche"),
                Check(ok: i.cipErrors == 0 && i.dbcJumps == 0, text: "Aucune erreur de paquet (CIP \(i.cipErrors), sauts DBC \(i.dbcJumps))"),
                Check(ok: i.inLate == 0, text: "Aucune trame d'entrée en retard (\(i.inLate))"),
            ]
        }
        return live + [
            Check(ok: true, text: "Appareil reconnu : \(d.kind.rawValue)"),
            Check(ok: r.tcatCategory == 0x04, text: "Catégorie TCAT 0x04 (DICE standard)"),
            Check(ok: r.locked, text: "Horloge verrouillée"),
            Check(ok: r.currentRate.map { r.supportedRates.contains($0) } ?? false, text: "Fréquence dans la liste annoncée par la carte"),
            Check(ok: !r.tx.isEmpty && !r.rx.isEmpty, text: "Flux d'entrée et de sortie annoncés (\(r.captureChannels) entrées, \(r.playbackChannels) sorties)"),
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
            Button("Copier le diagnostic") {
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
            case .firmware:
                VStack(alignment: .leading, spacing: 8) {
                    infoRow("Firmware DICE", d.report.version.isEmpty ? "—" : d.report.version)
                    Text("Affichage seul. Cette application n'écrit jamais de firmware dans la carte.")
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Aucune GS-R24 ni ZED-R16 détectée").font(.title3.bold()).foregroundStyle(.white)
                Text("Cette application ne pilote que ces deux appareils. Voir l'onglet Diagnostic pour la raison.")
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
                Toggle("Entrées", isOn: Binding(get: { !hideCapture }, set: { hideCapture = !$0 })).toggleStyle(.checkbox)
                Toggle("Sorties", isOn: Binding(get: { !hidePlayback }, set: { hidePlayback = !$0 })).toggleStyle(.checkbox)
                Toggle("Montrer les canaux masqués", isOn: $showHidden).toggleStyle(.checkbox)
                Button("Tout réafficher") { hiddenChannels = "" }
            }
            .foregroundStyle(.white)
            if !hideCapture { streamGrid(d, d.report.tx, title: "Entrées (carte vers Mac)", prefix: "tx", dir: .input) }
            if !hidePlayback { streamGrid(d, d.report.rx, title: "Sorties (Mac vers carte)", prefix: "rx", dir: .output) }
            HStack {
                Text("Double-clic ou clic droit sur un canal pour le renommer ou le masquer. Les noms sont gardés sur ce Mac, jamais écrits dans la carte, et repris par le plug-in audio pour les logiciels de musique (démon gsrd requis).")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button("Noms d'origine") { model.resetNames(d) }
            }
        }
    }

    private func streamGrid(_ d: Device, _ streams: [DiceStream], title: String, prefix: String,
                            dir: ChannelNameStore.Direction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(.white)
            ForEach(streams, id: \.index) { s in
                Text("Flux \(s.index) : \(s.pcmChannels) canaux" + (s.speed.map { ", \($0)" } ?? ""))
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
                                    Button("Renommer…") { renaming = RenameTarget(dir: dir, channel: number, original: custom ?? name) }
                                    if custom != nil {
                                        Button("Nom d'origine") { model.setName(d, dir, channel: number, name: "") }
                                    }
                                    Button(hidden ? "Afficher ce canal" : "Masquer ce canal") { toggleChannel(key) }
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
            Text("Renommer \(target.dir == .input ? "l'entrée" : "la sortie") \(target.channel)").font(.headline)
            TextField("Nom affiché dans les logiciels de musique", text: $text)
                .textFieldStyle(.roundedBorder).frame(width: 320)
                .onSubmit { onSave(text); dismiss() }
            Text("Laisser vide pour revenir au nom d'origine.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") { onSave(text); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .onAppear { text = target.original }
    }
}
