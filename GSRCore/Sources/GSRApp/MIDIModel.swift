import Foundation
import SwiftUI
import GSRCore

struct TrafficLine: Identifiable {
    let id = UUID()
    let time = Date()
    let direction: String
    let bytes: [UInt8]
    var text: String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

@MainActor
final class MIDIModel: ObservableObject {
    @Published var settings = MIDISettings.load() { didSet { if settings != oldValue { scheduleSave() } } }
    @Published var selected: ConsoleControl?
    @Published var layer: Layer = .plain
    @Published private(set) var status: AgentStatus?
    @Published private(set) var traffic: [TrafficLine] = []
    @Published var learning = false
    @Published var message = ""
    @Published private(set) var unknownCode: ConsoleMap.Pattern?

    private let client = AgentClient()
    private var timer: Timer?
    private var saveTask: Task<Void, Never>?
    private var monitoring = false

    // MARK: life

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
    }

    func stop() { timer?.invalidate(); timer = nil; client.stopMonitor(); monitoring = false }

    private func poll() {
        let c = client
        Task.detached {
            let s = c.status()
            await MainActor.run {
                self.status = s
                if s != nil, !self.monitoring { self.startMonitor() }
                if s == nil { self.monitoring = false }
            }
        }
    }

    private func startMonitor() {
        monitoring = true
        let c = client
        Task.detached {
            c.startMonitor(onTraffic: { dir, bytes in Task { @MainActor in self.received(dir, bytes) } }, onEvent: { _ in })
        }
    }

    // MARK: settings

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.settings.save()
            let c = self.client
            Task.detached { c.reload() }
        }
    }

    func action(_ c: ConsoleControl, _ l: Layer) -> Action { settings.protools.action(c, l) }
    func setAction(_ a: Action, _ c: ConsoleControl, _ l: Layer) { var cfg = settings.protools; cfg.set(a, c, l); settings.protools = cfg }

    /// Summary lines shown in the inspector and used to mark the bound controls on the surface.
    func isBound(_ c: ConsoleControl) -> Bool {
        if c.id.hasPrefix("sel.") { return true }
        return Layer.allCases.contains { settings.protools.action(c, $0) != .none }
    }

    func codes(of c: ConsoleControl) -> [(String, Layer?)] {
        settings.consoleMap().codes(of: c).map { (ConsoleMap.describe($0.0), $0.1) }
    }

    func restoreDefaults() { settings.protools = .standard; settings.customCodes = [] }

    // MARK: traffic and learning

    func received(_ dir: String, _ bytes: [UInt8]) {
        traffic.append(TrafficLine(direction: dir, bytes: bytes))
        if traffic.count > 200 { traffic.removeFirst(traffic.count - 200) }
        guard learning, dir == "console in" else { return }
        let outcome = settings.consoleMap().learn(bytes)
        switch outcome {
        case .known(let c, let l):
            selected = c
            if let l { layer = l }
            message = "That is \(c.title)\(l == .shift ? " with Shift" : "")."
            unknownCode = nil; learning = false
        case .unknown(let p):
            unknownCode = p
            message = "The console sent a code the app does not know: \(ConsoleMap.describe(p)). Select the control it belongs to, then press Assign."
            learning = false
        case .ignored: break
        }
    }

    func startLearning() { learning = true; unknownCode = nil; message = "Press a control on the console…" }
    func cancelLearning() { learning = false; message = "" }

    /// Teaches the app that the unknown code stands for the selected control.
    func assignUnknown() {
        guard let p = unknownCode, let c = selected else { return }
        let l: Layer? = (c.id.hasPrefix("sel.") || c.id.hasPrefix("st.")) ? layer : nil
        settings.customCodes.removeAll { $0.control == c && $0.layer == l }
        settings.customCodes.append(CustomCode(pattern: p, control: c, layer: l))
        message = "\(c.title) now answers to \(ConsoleMap.describe(p))."
        unknownCode = nil
    }

    // MARK: trying HUI switches in Pro Tools

    @Published var lastTested: HUISwitch?

    /// Presses and releases a HUI switch in Pro Tools, to see what it does. Needs Pro Tools mode and the agent.
    func testHUI(_ s: HUISwitch) {
        guard settings.mode == .protools else { message = "Switch to Pro Tools mode to try a HUI switch."; return }
        guard status != nil else { message = "The MIDI agent is not running."; return }
        lastTested = s
        let bytes = HUI.switchMessage(zone: s.zone, port: s.port, pressed: true) + HUI.switchMessage(zone: s.zone, port: s.port, pressed: false)
        let c = client
        Task.detached { _ = c.sendHUI(device: 0, bytes: bytes) }
        message = String(format: "Sent HUI zone 0x%02X, port %d. Watch Pro Tools.", s.zone, s.port)
    }

    func saveUserSwitch(name: String, _ s: HUISwitch) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        settings.userSwitches.removeAll { $0.target == s }
        settings.userSwitches.append(UserSwitch(name: n, zone: s.zone, port: s.port))
        settings.userSwitches.sort { ($0.zone, $0.port) < ($1.zone, $1.port) }
    }

    func removeUserSwitch(_ s: HUISwitch) { settings.userSwitches.removeAll { $0.target == s } }

    var catalog: [HUICatalog.Entry] { HUICatalog.all(user: settings.userSwitches) }

    func askAccessibility() { let c = client; Task.detached { c.askAccessibility() } }
}
