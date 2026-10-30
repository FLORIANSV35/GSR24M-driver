import SwiftUI
import AppKit
import CoreMIDI
import UniformTypeIdentifiers
import GSRCore

/// Dev tab: collects, on request, a report that helps the development (ZED-R16, two chained consoles, Intel Macs, anything else). Read only; the app sends nothing anywhere:
/// the user saves a zip, can look inside, and attaches it to a message himself.
@MainActor
final class DevModel: ObservableObject {
    @Published var zedR16 = false
    @Published var twoConsoles = false
    @Published var intelMac: Bool = DevModel.runsOnIntel
    @Published var notes = ""
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    @Published private(set) var saved: URL?

    /// True for the Intel half of the application (an Intel Mac, or Rosetta).
    static var runsOnIntel: Bool {
        #if arch(x86_64)
        return true
        #else
        return false
        #endif
    }

    var context: DevReport.Context { .init(zedR16: zedR16, twoConsoles: twoConsoles, intelMac: intelMac, notes: notes) }

    func collect(app: AppModel) {
        guard !busy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = DevReport.archiveName()
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.message = "Save the report, look inside it, then attach it to your message."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; saved = nil; status = "Collecting… (about 30 seconds)"
        var state = DevReport.AppState()
        state.appVersion = UpdateChecker.currentVersion
        state.daemonInstalled = AppModel.daemonInstalled; state.daemonAnswers = app.live != nil
        state.ownedGUID = app.live != nil ? app.devices.first?.report.guid : nil
        state.dicedump = Bundle.main.url(forResource: "dicedump", withExtension: nil)?.path
        if let i = app.live {
            state.daemon = (AppModel.daemonLog(i) + ["generation \(i.generation), state \(i.state), owned \(i.owned), version \(i.version), IO clients \(i.ioClients), lead \(i.leadMs) ms"]
                + (app.devices.first.map { ["", "Card as the daemon reports it:"] + Self.cardLines($0.report) } ?? [])).joined(separator: "\n")
        }
        state.midiPorts = Self.midiPortNames()
        state.settings = (try? String(contentsOf: MIDISettings.fileURL, encoding: .utf8)) ?? "(no midi.json)"
        let context = self.context
        Task.detached {
            let agent = AgentClient()
            var a = "(not reachable)"
            if let s = agent.status() { a = "card link \(s.card), mode \(s.mode), bytes in \(s.bytesIn), out \(s.bytesOut), sent to the console \(s.sentToConsole), queued \(s.queued), peak \(s.peakQueued), coalesced \(s.coalesced), dropped \(s.dropped)" }
            state.agent = a
            let files = DevReport.files(context: context, state: state, runner: DevReport.run, readFile: { try? String(contentsOfFile: $0, encoding: .utf8) })
            var message = ""
            do { try DevReport.write(files, to: url); message = "Saved: " + url.lastPathComponent } catch { message = "Could not write the report: \(error.localizedDescription)" }
            let result = message
            await MainActor.run { self.status = result; self.busy = false; if FileManager.default.fileExists(atPath: url.path) { self.saved = url } }
        }
    }

    static func cardLines(_ r: DiceReport) -> [String] {
        func hex(_ v: UInt32?) -> String { v.map { String(format: "0x%06X", $0) } ?? "?" }
        var l = ["vendor '\(r.vendor)', model '\(r.model)', GUID " + (r.guid.map { String(format: "0x%016llX", $0) } ?? "?"),
                 "Vendor_ID \(hex(r.vendorID)), Model_ID \(hex(r.modelID)), Unit_Spec_ID \(hex(r.unitSpecID)), TCAT category \(r.tcatCategory.map { String($0) } ?? "?")",
                 "firmware '\(r.version)', nickname '\(r.nickName)', clock source '\(r.clockSourceID)', rate \(r.currentRate.map { String($0) } ?? "?"), locked \(r.locked)",
                 "supported rates \(r.supportedRates), \(r.captureChannels) inputs, \(r.playbackChannels) outputs"]
        for (dir, streams) in [("TX (card to Mac)", r.tx), ("RX (Mac to card)", r.rx)] {
            for s in streams { l.append("\(dir) stream \(s.index): iso \(s.isochronous), \(s.pcmChannels) PCM, \(s.midiPorts) MIDI port(s), speed \(s.speed ?? "?"), names \(s.names.joined(separator: " | "))") }
        }
        return l
    }

    static func midiPortNames() -> String {
        var l: [String] = ["## destinations"]
        for i in 0..<MIDIGetNumberOfDestinations() { l.append(ExternalMIDI.name(of: MIDIGetDestination(i))) }
        l.append("## sources")
        for i in 0..<MIDIGetNumberOfSources() { l.append(ExternalMIDI.name(of: MIDIGetSource(i))) }
        return l.joined(separator: "\n")
    }
}

struct DevView: View {
    @ObservedObject var model: AppModel
    @StateObject private var dev = DevModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Help the development").font(.title3.bold()).foregroundStyle(.white)
            Text("Tick what you use, press Collect, and attach the zip to a message. It only reads; the application sends nothing.").font(.callout).foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 18) {
                Toggle("ZED-R16", isOn: $dev.zedR16)
                Toggle("Two chained consoles", isOn: $dev.twoConsoles)
                Toggle("Intel Mac", isOn: $dev.intelMac)
            }.toggleStyle(.checkbox).foregroundStyle(.white)
            TextField("Notes: your set-up, what you tried, what happened", text: $dev.notes, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Button(dev.busy ? "Collecting…" : "Collect and save…") { dev.collect(app: model) }.disabled(dev.busy)
                Button("Open the GitHub page") { if let u = DevReport.issueURL(dev.context) { NSWorkspace.shared.open(u) } }
                if let u = dev.saved { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                Text(dev.status).font(.callout).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
            }
            Text("Reading a second FireWire unit can interrupt the sound for about 3 seconds.").font(.caption).foregroundStyle(.white.opacity(0.7))
            DisclosureGroup("What is in the report") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(["The Mac: macOS version, model, processor, whether it runs under Rosetta",
                             "The FireWire bus as macOS lists it (devices, identifiers, speeds)",
                             "A read-only dump of the DICE units the daemon does not hold (a ZED-R16, a second console)",
                             "The state of the gsrd daemon and of the MIDI agent, the MIDI ports, the settings file",
                             "The last lines of the logs; your name, home folder and computer name are blanked",
                             "It does contain your devices' identifiers (GUID, nickname): look inside before you send it"], id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.white.opacity(0.8)) }
                }.padding(.top, 4)
            }.foregroundStyle(.white)
        }
    }
}

// MARK: preview image (development: `GSRApp --render-dev file.png`)

@MainActor
enum DevPreview {
    static func render(to path: String) {
        let view = DevView(model: AppModel()).padding(14).frame(width: 760, alignment: .leading).background(Theme.panel).preferredColorScheme(.dark)
        let r = ImageRenderer(content: view); r.scale = 2
        if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
