import Foundation

/// The program that sits between gsrd and the applications: virtual CoreMIDI ports, the translation, the keystrokes, and a small Mach service
/// (`com.gsr24m.midiagent`) the app uses to see the state and the traffic.
public final class MIDIAgent {
    public static let serviceName = "com.gsr24m.midiagent"

    private let queue = DispatchQueue(label: "gsr.midi.agent")
    private let card: RoutedCardMIDI
    private let virtual: CoreMIDIVirtual
    private let host: MIDIHost
    private var timer: DispatchSourceTimer?
    private var settingsStamp: Date?
    private var monitors: [xpc_connection_t] = []
    private var listener: xpc_connection_t?                // must be kept: Swift releases an XPC object that nothing refers to, which closes the service
    private var keystrokeWarned = false
    private var countersIn: UInt64 = 0, countersOut: UInt64 = 0

    public init?() {
        card = RoutedCardMIDI(queue: queue)
        virtual = CoreMIDIVirtual(queue: queue)
        if let f = virtual.failure { FileHandle.standardError.write(Data("gsrmidiagent: \(f)\n".utf8)); return nil }
        let settings = MIDISettings.load()
        card.apply(settings)
        host = MIDIHost(card: card, virtual: virtual, settings: settings)
        host.onKeystroke = { [weak self] k in self?.keystroke(k) }
        host.onTraffic = { [weak self] dir, bytes in self?.traffic(dir, bytes) }
    }

    public func run() -> Never {
        card.onConnectionChange = { [weak self] up in
            guard let self else { return }
            self.pushEvent(["op": "connection", "up": up])
            if up { self.host.start(now: ProcessInfo.processInfo.systemUptime) }       // the console's LEDs are lit again after a daemon restart
        }
        card.start()
        startServer()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.02)
        var counter = 0
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.host.tick(now: ProcessInfo.processInfo.systemUptime)
            counter += 1
            if counter % 50 == 0 { self.reloadSettingsIfChanged() }                    // once a second
        }
        t.resume(); timer = t
        while true { RunLoop.main.run() }                          // CoreMIDI and XPC need the main run loop, which dispatchMain() does not give
    }

    private func reloadSettingsIfChanged() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: MIDISettings.fileURL.path)[.modificationDate]) as? Date
        guard stamp != settingsStamp else { return }
        settingsStamp = stamp
        guard stamp != nil else { return }
        let s = MIDISettings.load()
        card.apply(s)
        host.apply(s, now: ProcessInfo.processInfo.systemUptime)
    }

    private func keystroke(_ k: KeyShortcut) {
        if !KeyInjector.press(k) && !keystrokeWarned {
            keystrokeWarned = true
            KeyInjector.askForPermission()
            pushEvent(["op": "needsAccessibility"])
        }
    }

    // MARK: service for the app

    private func traffic(_ dir: String, _ bytes: [UInt8]) {
        if dir.hasSuffix("in") { countersIn += UInt64(bytes.count) } else { countersOut += UInt64(bytes.count) }
        guard !monitors.isEmpty else { return }
        let m = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(m, "op", "traffic")
        xpc_dictionary_set_string(m, "dir", dir)
        xpc_dictionary_set_double(m, "t", ProcessInfo.processInfo.systemUptime)
        bytes.withUnsafeBytes { xpc_dictionary_set_data(m, "data", $0.baseAddress!, bytes.count) }
        for c in monitors { xpc_connection_send_message(c, m) }
    }

    private func pushEvent(_ fields: [String: Any]) {
        let m = xpc_dictionary_create(nil, nil, 0)
        for (k, v) in fields {
            if let s = v as? String { xpc_dictionary_set_string(m, k, s) } else if let b = v as? Bool { xpc_dictionary_set_bool(m, k, b) }
        }
        for c in monitors { xpc_connection_send_message(c, m) }
    }

    private func startServer() {
        let l = xpc_connection_create_mach_service(Self.serviceName, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        xpc_connection_set_event_handler(l) { [weak self] peer in
            guard let self, xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            xpc_connection_set_event_handler(peer) { [weak self] msg in
                guard let self else { return }
                if xpc_get_type(msg) == XPC_TYPE_ERROR { self.monitors.removeAll { $0 === peer }; return }
                guard xpc_get_type(msg) == XPC_TYPE_DICTIONARY, let reply = xpc_dictionary_create_reply(msg) else { return }
                let op = xpc_dictionary_get_string(msg, "op").map { String(cString: $0) } ?? ""
                switch op {
                case "status":
                    xpc_dictionary_set_bool(reply, "card", self.card.connected)
                    xpc_dictionary_set_bool(reply, "external", self.card.external)
                    xpc_dictionary_set_string(reply, "mode", self.host.settings.mode.rawValue)
                    xpc_dictionary_set_bool(reply, "accessibility", KeyInjector.isTrusted)
                    xpc_dictionary_set_uint64(reply, "bytesIn", self.countersIn)
                    xpc_dictionary_set_uint64(reply, "bytesOut", self.countersOut)
                    xpc_dictionary_set_uint64(reply, "queued", UInt64(self.host.shaper.queued))
                    xpc_dictionary_set_uint64(reply, "peakQueued", UInt64(self.host.shaper.peakQueued))
                    xpc_dictionary_set_uint64(reply, "coalesced", UInt64(self.host.shaper.coalesced))
                    xpc_dictionary_set_uint64(reply, "dropped", UInt64(self.host.shaper.dropped))
                    xpc_dictionary_set_uint64(reply, "sentToConsole", UInt64(self.host.shaper.sentBytes))
                    xpc_dictionary_set_bool(reply, "ok", true)
                case "monitorSubscribe":
                    if !self.monitors.contains(where: { $0 === peer }) { self.monitors.append(peer) }
                    xpc_dictionary_set_bool(reply, "ok", true)
                case "monitorUnsubscribe":
                    self.monitors.removeAll { $0 === peer }
                    xpc_dictionary_set_bool(reply, "ok", true)
                case "askAccessibility":
                    KeyInjector.askForPermission()
                    xpc_dictionary_set_bool(reply, "ok", true)
                case "huiSend":
                    var n = 0
                    let device = Int(xpc_dictionary_get_uint64(msg, "device"))
                    if let p = xpc_dictionary_get_data(msg, "data", &n), n > 0, n <= 64 {
                        self.host.sendToHUI(device: device, bytes: Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt8.self), count: n)))
                        xpc_dictionary_set_bool(reply, "ok", true)
                    } else { xpc_dictionary_set_bool(reply, "ok", false) }
                case "faderSet":
                    let n = Int(xpc_dictionary_get_uint64(msg, "channel")), v = Int(xpc_dictionary_get_uint64(msg, "value"))
                    self.host.moveFader(channel: n, to: v, now: ProcessInfo.processInfo.systemUptime)
                    xpc_dictionary_set_bool(reply, "ok", (1...24).contains(n))
                case "reload":
                    self.settingsStamp = nil
                    xpc_dictionary_set_bool(reply, "ok", true)
                default: xpc_dictionary_set_bool(reply, "ok", false)
                }
                xpc_connection_send_message(peer, reply)
            }
            xpc_connection_resume(peer)
        }
        xpc_connection_resume(l)
        listener = l
    }
}
