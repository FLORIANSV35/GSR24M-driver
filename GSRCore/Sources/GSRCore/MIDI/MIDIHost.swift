import Foundation

public enum MIDIMode: String, Codable, CaseIterable {
    case legacy                                       // the card's three MIDI ports go through unchanged
    case protools                                     // the console is translated to three HUI devices
    public var title: String { self == .legacy ? "Legacy" : "Pro Tools" }
}

/// A virtual MIDI endpoint seen by the applications.
public enum MIDIEndpoint: Hashable {
    case legacy(Int)                                  // "GS-R24M MIDI 1 to 3"
    case hui(Int)                                     // "GS-R24M HUI 1 to 3"
}

/// The card side: bytes of the three MIDI ports of the card (gsrd).
public protocol CardMIDI: AnyObject {
    func send(port: Int, bytes: [UInt8])
    var onReceive: ((_ port: Int, _ bytes: [UInt8]) -> Void)? { get set }
}

/// The application side: virtual CoreMIDI sources and destinations.
public protocol VirtualMIDI: AnyObject {
    func sendToApplications(_ endpoint: MIDIEndpoint, bytes: [UInt8])
    var onFromApplications: ((_ endpoint: MIDIEndpoint, _ bytes: [UInt8]) -> Void)? { get set }
}

/// A code the user taught the app by pressing a control on the console (for codes that are not documented).
public struct CustomCode: Codable, Equatable {
    public var pattern: ConsoleMap.Pattern
    public var control: ConsoleControl
    public var layer: Layer?
    public init(pattern: ConsoleMap.Pattern, control: ConsoleControl, layer: Layer?) { self.pattern = pattern; self.control = control; self.layer = layer }
}

public struct MIDISettings: Codable, Equatable {
    public var mode: MIDIMode = .legacy
    public var consolePort = 0                        // card port the console is on (to be confirmed on the real card)
    public var consoleChannel = 0                     // MIDI channel set on the console, 0 for channel 1
    public var protools = ProToolsConfig.standard
    public var customCodes: [CustomCode] = []
    public var userSwitches: [UserSwitch] = []        // HUI switches the user found with the explorer and named
    public init() {}

    /// The console's codes: the documented ones, then what was learned (which wins, and replaces the codes the control had).
    public func consoleMap() -> ConsoleMap {
        var m = ConsoleMap.mode3(channel: UInt8(consoleChannel))
        for c in customCodes { m.set(c.pattern, c.control, layer: c.layer) }
        return m
    }

    public static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GSR24M", isDirectory: true).appendingPathComponent("midi.json")
    }
    public static func load(from url: URL = MIDISettings.fileURL) -> MIDISettings {
        (try? JSONDecoder().decode(MIDISettings.self, from: Data(contentsOf: url))) ?? MIDISettings()
    }
    @discardableResult
    public func save(to url: URL = MIDISettings.fileURL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(self).write(to: url, options: .atomic)
            return true
        } catch { return false }
    }
}

/// Routes MIDI between the card and the applications, in Legacy or Pro Tools mode. No I/O of its own and no clock: the owner calls `tick`.
public final class MIDIHost {
    public private(set) var settings: MIDISettings
    public private(set) var bridge: ProToolsBridge
    public var onKeystroke: ((KeyShortcut) -> Void)?
    /// Called with every byte string sent to the console or to the applications in Pro Tools mode (for a monitor in the app).
    public var onTraffic: ((_ direction: String, _ bytes: [UInt8]) -> Void)?

    private let card: CardMIDI
    private let virtual: VirtualMIDI
    private var consoleParser = MIDIParser()
    /// Everything sent to the console goes through here (see `ConsoleShaper`).
    public let shaper = ConsoleShaper()
    private var huiParsers = [MIDIParser](repeating: MIDIParser(), count: 3)

    public init(card: CardMIDI, virtual: VirtualMIDI, settings: MIDISettings = MIDISettings()) {
        self.card = card; self.virtual = virtual; self.settings = settings
        bridge = ProToolsBridge(config: settings.protools, map: settings.consoleMap())
        card.onReceive = { [weak self] port, bytes in self?.fromCard(port: port, bytes: bytes) }
        virtual.onFromApplications = { [weak self] endpoint, bytes in self?.fromApplications(endpoint, bytes) }
    }

    /// Applies new settings; a change of mode restarts the translation (and lights the console's LEDs in Pro Tools mode).
    public func apply(_ s: MIDISettings, now: TimeInterval) {
        let modeChanged = s.mode != settings.mode || s.consoleChannel != settings.consoleChannel || s.consolePort != settings.consolePort || s.customCodes != settings.customCodes
        settings = s
        if modeChanged || bridge.config != s.protools {
            bridge = ProToolsBridge(config: s.protools, map: s.consoleMap())
            consoleParser.reset(); shaper.reset()
        }
        if modeChanged { huiParsers = [MIDIParser](repeating: MIDIParser(), count: 3) }
        if s.mode == .protools { emit(bridge.startup(), now: now) }
    }

    /// Sends HUI bytes to Pro Tools on one device (the explorer and the test button use it).
    public func sendToHUI(device: Int, bytes: [UInt8]) {
        guard device >= 0, device < 3 else { return }
        virtual.sendToApplications(.hui(device), bytes: bytes)
        onTraffic?("hui\(device + 1) out", bytes)
    }

    public func start(now: TimeInterval) { if settings.mode == .protools { emit(bridge.startup(), now: now) } }

    public func tick(now: TimeInterval) {
        guard settings.mode == .protools else { return }
        emit(bridge.tick(now: now), now: now)
        sendToConsole(shaper.drain(now: now))
    }

    /// Moves the motorised fader of a channel (1 to 24) to a position (0 to 127): the console takes the controller of the channel number as the position
    /// to go to when READ is on. Goes through the rate limit in Pro Tools mode.
    public func moveFader(channel n: Int, to value: Int, now: TimeInterval) {
        guard (1...24).contains(n) else { return }
        let m: [UInt8] = [0xB0 | UInt8(settings.consoleChannel & 0x0F), UInt8(n), UInt8(min(127, max(0, value)))]
        if settings.mode == .protools { sendToConsole(shaper.push(m, now: now)) }
        else { card.send(port: settings.consolePort, bytes: m); onTraffic?("card \(settings.consolePort + 1) out", m) }
    }

    private func sendToConsole(_ messages: [[UInt8]]) {
        for m in messages { card.send(port: settings.consolePort, bytes: m); onTraffic?("console out", m) }
    }

    // MARK: card side

    private func fromCard(port: Int, bytes: [UInt8]) {
        switch settings.mode {
        case .legacy:
            onTraffic?("card \(port + 1) in", bytes)
            virtual.sendToApplications(.legacy(port), bytes: bytes)
        case .protools:
            guard port == settings.consolePort else { return }
            let now = ProcessInfo.processInfo.systemUptime
            for m in consoleParser.feed(bytes) { onTraffic?("console in", m); emit(bridge.receiveFromConsole(m, now: now), now: now) }
        }
    }

    // MARK: application side

    private func fromApplications(_ endpoint: MIDIEndpoint, _ bytes: [UInt8]) {
        switch (settings.mode, endpoint) {
        case (.legacy, .legacy(let p)):
            onTraffic?("card \(p + 1) out", bytes)
            card.send(port: p, bytes: bytes)
        case (.protools, .hui(let d)):
            guard d >= 0, d < huiParsers.count else { return }
            let now = ProcessInfo.processInfo.systemUptime
            for m in huiParsers[d].feed(bytes) {
                onTraffic?("hui\(d + 1) in", m)
                emit(bridge.receiveFromHUI(device: d, m), now: now)
            }
        default: break                                // the endpoints of the other mode are silent
        }
    }

    private func emit(_ outputs: [BridgeOutput], now: TimeInterval) {
        for o in outputs {
            switch o {
            case .hui(let d, let b): virtual.sendToApplications(.hui(d), bytes: b); onTraffic?("hui\(d + 1) out", b)
            case .console(let b): for m in midiMessages(b) { sendToConsole(shaper.push(m, now: now)) }
            case .key(let k): onKeystroke?(k)
            }
        }
    }
}
