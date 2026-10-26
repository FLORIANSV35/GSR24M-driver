import SwiftUI
import GSRCore

struct Device: Identifiable, Equatable {
    var id: UInt64 { report.guid ?? 0 }
    var report: DiceReport
    var kind: AHDeviceKind
}

/// Simulated GS-R24 used only by the demo switch, to preview the interface without the card.
/// Names, clock sources and the 2 x 16 stream split come from the vendor firmware tables (mode "32/32 FW").
/// The MIDI port count and the rate-dependent layout are not established.
enum Demo {
    static func gsr24() -> Device {
        var r = DiceReport()
        let guid = UInt64(0x0004C4) << 40 | UInt64(0x04) << 32 | UInt64(1) << 22 | 1234
        r.guid = guid
        r.vendor = "Allen and Heath Ltd."; r.model = "GS R 24"
        r.unitSpecID = 0x0004C4
        r.nickName = "GS R-24"
        r.clockSourceID = "internal"; r.currentRate = 44100; r.locked = true
        r.version = "démo (simulé)"
        r.supportedRates = [44100, 48000, 88200, 96000]
        r.supportedSources = ["adat", "wc", "internal"]
        let ids = ["aes1", "aes2", "aes3", "aes4", "aes_any", "adat", "tdif", "wc",
                   "arx1", "arx2", "arx3", "arx4", "internal"]
        let labels = ["AES12", "AES34", "AES56", "AES78", "AES_ANY", "ADAT", "ADAT_AUX", "Word Clock",
                      "Unused", "Unused", "Unused", "Unused", "Internal"]
        r.clockSources = zip(ids.indices, zip(ids, labels)).map { DiceClockSource(index: $0, id: $1.0, label: $1.1) }
        // Mode "GSR-24 32/32 FW" from the firmware tables: 2 streams per direction, 16 names each.
        // Names are the exact strings the firmware stores (mono label, then stereo-pair label).
        func ch(_ i: Int) -> String { "CH\(i)/CH\((i + 1) / 2 * 2 - 1)/\((i + 1) / 2 * 2)" }
        let adat = ["ADAT1/2", "ADAT1/2", "ADAT3/4", "ADAT3/4", "ADAT5/6", "ADAT5/6", "ADAT7/8", "ADAT7/8"]
        func streams(_ first: Int) -> [DiceStream] {
            [DiceStream(index: 0, isochronous: -1, pcmChannels: 16, midiPorts: 1, speed: "S400",
                        names: (1...16).map(ch)),
             DiceStream(index: 1, isochronous: -1, pcmChannels: 16, midiPorts: 0, speed: "S400",
                        names: (17...24).map(ch) + adat)]
        }
        r.tx = streams(0); r.rx = streams(0)
        return Device(report: r, kind: .gsr24)
    }
}

/// Reads Allen & Heath units through the bundled read-only `dicedump` tool.
/// With no unit connected the app shows why nothing was found. Demo data appears only when
/// the user turns the demo switch on.
final class AppModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var selectedID: UInt64?
    @Published var busy = false
    @Published var log: [String] = []
    @Published var fileLabel: String?
    @Published var names = ChannelNameStore.load()
    @Published var demo = false { didSet { demo ? startDemo() : refresh() } }
    /// Latest answer of the daemon `gsrd`; nil when it is not running (the app then falls back to the read-only dicedump scan).
    @Published var live: DaemonInfo?
    @Published var daemonNote = ""
    private let client = DaemonClient()
    private var timer: Timer?
    private var polling = false
    private var pushedNamesFor: UInt64?
    var viaDaemon: Bool { live != nil && !demo }
    /// With the daemon installed the card belongs to it. Running dicedump then opens the same FireWire device and makes the daemon
    /// see a bus reset (measured: the audio stops for about 3 s), so the app never scans while the daemon is installed.
    static var daemonInstalled: Bool { FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.gsr24m.gsrd.plist") }

    /// Demo devices never write names to disk: the demo GUID is not a real card.
    func setName(_ d: Device, _ dir: ChannelNameStore.Direction, channel: Int, name: String) {
        guard let g = d.report.guid else { return }
        names.set(guid: g, dir, channel: channel, name: name)
        if !demo { names.save(); pushNames(g) }
    }
    func resetNames(_ d: Device) {
        guard let g = d.report.guid else { return }
        names.reset(guid: g)
        if !demo { names.save(); pushNames(g) }
    }

    /// The stored names are the master copy: the daemon keeps a copy so the audio plug-in has them even when this app is closed.
    func pushNames(_ guid: UInt64) {
        guard viaDaemon else { return }
        let l = names.lists(guid: guid)
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.client.setNames(inputs: l.inputs, outputs: l.outputs)
            DispatchQueue.main.async { if !ok { self.daemonNote = "Le démon a refusé les noms." } }
        }
    }

    func setRate(_ hz: Int) {
        guard viaDaemon else { demoSetRate(hz); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.client.setRate(hz)
            DispatchQueue.main.async { self.daemonNote = ok ? "Changement de fréquence demandé : \(hz) Hz" : "Fréquence refusée par le démon." }
        }
    }

    func setSource(_ id: String) {
        guard viaDaemon else { demoSetSource(id); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.client.setSource(id)
            DispatchQueue.main.async { self.daemonNote = ok ? "Changement de source demandé : \(id)" : "Source refusée par le démon." }
        }
    }

    func setOperationMode(_ name: String) {
        guard viaDaemon, let ms = DaemonInfo.modeLeads.first(where: { $0.name == name })?.ms else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.client.setLead(ms: ms)
            DispatchQueue.main.async { self.daemonNote = ok ? "Mode demandé : \(name) (\(ms) ms d'avance)" : "Mode refusé par le démon." }
        }
    }

    var selected: Device? { devices.first { $0.id == selectedID } ?? devices.first }

    init() {
        // `--demo` on the command line starts in the demonstration mode (used to preview the interface).
        if CommandLine.arguments.contains("--demo") { demo = true; startDemo() } else if !AppModel.daemonInstalled { refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    /// Asks the daemon every second. When it answers, its view of the card replaces the dicedump scan:
    /// the daemon holds the card open, so dicedump could not read it at the same time anyway.
    private func poll() {
        guard !demo, !polling else { return }
        polling = true
        DispatchQueue.global(qos: .utility).async {
            let info = self.client.info()
            DispatchQueue.main.async {
                self.polling = false
                guard !self.demo else { return }
                let wasLive = self.live != nil
                self.live = info
                guard let i = info else {
                    if wasLive && !AppModel.daemonInstalled { self.refresh() }
                    return
                }
                if let r = i.report(), let k = r.ahCheck().kind {
                    let d = Device(report: r, kind: k)
                    if self.devices != [d] { self.devices = [d] }
                    if self.selectedID != d.id { self.selectedID = d.id }
                    if self.pushedNamesFor != d.id { self.pushedNamesFor = d.id; self.pushNames(d.id) }
                } else {
                    if !self.devices.isEmpty { self.devices = [] }
                    self.pushedNamesFor = nil
                }
                self.log = AppModel.daemonLog(i)
            }
        }
    }

    static func daemonLog(_ i: DaemonInfo) -> [String] {
        var l = ["Démon gsrd : actif depuis \(Int(i.uptime)) s, \(i.sessions) session(s), \(i.busResets) reset(s) du bus."]
        if !i.haveCard { l.append("Aucune carte prise en charge : " + (i.error.isEmpty ? "carte absente ou éteinte." : i.error)) }
        else {
            l.append(i.isStreaming ? "Flux audio en marche à \(i.rate ?? 0) Hz." : "Carte vue, flux arrêté.")
            l.append("Paquets : erreurs CIP \(i.cipErrors), sauts DBC \(i.dbcJumps), plus long trou \(String(format: "%.1f", i.maxGapMs)) ms.")
            l.append("Trames en retard : entrée \(i.inLate), sortie \(i.outLate). Applications audio actives : \(i.ioClients).")
            l.append("Avance de lecture : \(i.leadMs) ms. Génération des flux : \(i.generation).")
            if !i.error.isEmpty { l.append("Dernier incident : " + i.error) }
        }
        return l
    }

    private func startDemo() {
        devices = [Demo.gsr24()]; selectedID = devices[0].id; fileLabel = nil
        log = ["Mode démonstration : données simulées, rien n'est lu sur la carte."]
    }

    // Simulated changes, demo only.
    func demoSetRate(_ hz: Int) { guard demo, !devices.isEmpty else { return }; devices[0].report.currentRate = hz }
    func demoSetSource(_ id: String) { guard demo, !devices.isEmpty else { return }; devices[0].report.clockSourceID = id }

    func refresh() {
        guard !busy, !demo else { return }
        if live != nil || AppModel.daemonInstalled {
            poll()
            if live == nil { log = ["Le démon gsrd est installé mais ne répond pas (il redémarre peut-être). Aucune lecture directe de la carte n'est faite pour ne pas la perturber."] }
            return
        }
        busy = true; fileLabel = nil; log = ["Recherche des appareils FireWire…"]
        DispatchQueue.global(qos: .userInitiated).async {
            let (found, lines) = AppModel.scan()
            DispatchQueue.main.async {
                guard !self.demo else { self.busy = false; return }
                self.devices = found
                if !found.contains(where: { $0.id == self.selectedID }) { self.selectedID = found.first?.id }
                self.log = lines
                self.busy = false
            }
        }
    }

    private static func run(_ tool: URL, _ args: [String]) -> (code: Int32, out: String, err: String) {
        let p = Process(); p.executableURL = tool; p.arguments = args
        let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e
        do { try p.run() } catch { return (-1, "", "Impossible de lancer dicedump : \(error)") }
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: od, as: UTF8.self), String(decoding: ed, as: UTF8.self))
    }

    static func scan() -> ([Device], [String]) {
        guard let tool = Bundle.main.url(forResource: "dicedump", withExtension: nil) else {
            return ([], ["Outil de lecture dicedump absent de l'application."])
        }
        var lines: [String] = []
        let list = run(tool, ["-l"])
        if list.code != 0 && list.out.isEmpty {
            lines.append("Aucun appareil FireWire vu par le Mac.")
            lines.append("Vérifiez : carte allumée, câble FireWire 800 vers 400, chaîne d'adaptateurs Thunderbolt, puis Actualiser.")
            if !list.err.isEmpty { lines.append(list.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return ([], lines)
        }
        var out: [Device] = []
        for l in list.out.split(separator: "\n") {
            lines.append("Vu : " + l)
            guard l.contains("allen_heath=1"), let g = l.split(separator: " ").dropFirst().first else { continue }
            let dump = run(tool, ["-g", String(g)])
            if dump.code != 0 {
                lines.append("Lecture de \(g) impossible : " + dump.err.trimmingCharacters(in: .whitespacesAndNewlines))
                continue
            }
            do {
                let r = try DiceReport.parse(dump.out)
                let check = r.ahCheck()
                if let k = check.kind { out.append(Device(report: r, kind: k)) } else { lines.append(check.reason) }
            } catch { lines.append("Rapport illisible pour \(g) : \(error)") }
        }
        if out.isEmpty && !lines.contains(where: { $0.hasPrefix("Lecture") || $0.hasPrefix("Pas un") }) {
            lines.append("Des appareils FireWire sont présents mais aucun n'est une GS-R24 ou une ZED-R16.")
        }
        return (out, lines)
    }

    /// Opens a saved report. Only accepted if it is a GS-R24 or ZED-R16.
    func load(_ url: URL) {
        demo = false
        do {
            let r = try DiceReport.parse(try String(contentsOf: url, encoding: .utf8))
            let check = r.ahCheck()
            guard let k = check.kind else { log = ["Rapport refusé : " + check.reason]; return }
            devices = [Device(report: r, kind: k)]; selectedID = devices[0].id
            fileLabel = url.lastPathComponent; log = []
        } catch { log = ["Lecture impossible : \(error)"] }
    }
}
