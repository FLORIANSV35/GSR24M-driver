import CoreMIDI
import Foundation

/// The console reached through a MIDI interface of the Mac wired to its MIDI IN and OUT sockets, instead of the card's own MIDI ports. One input and
/// one output, chosen by name; they are connected again when the interface is plugged back in. Callbacks come on `queue`.
public final class ExternalMIDI {
    public var onReceive: ((_ bytes: [UInt8]) -> Void)?
    public var onConnectionChange: ((Bool) -> Void)?
    public private(set) var connected = false

    private let queue: DispatchQueue
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef(), outPort = MIDIPortRef()
    private var source: MIDIEndpointRef?, destination: MIDIEndpointRef?
    private var wantedIn = "", wantedOut = ""
    public private(set) var failure: String?

    public init(queue: DispatchQueue) {
        self.queue = queue
        var st = MIDIClientCreateWithBlock("GS-R24M external" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged { self?.queue.async { self?.connect() } }
        }
        if st != noErr { failure = "MIDIClientCreate \(st)"; return }
        st = MIDIInputPortCreateWithBlock(client, "console in" as CFString, &inPort) { [weak self] list, _ in
            guard let self else { return }
            let bytes = CoreMIDIVirtual.bytes(in: list)
            if !bytes.isEmpty { self.queue.async { self.onReceive?(bytes) } }
        }
        if st != noErr { failure = "MIDIInputPortCreate \(st)"; return }
        st = MIDIOutputPortCreate(client, "console out" as CFString, &outPort)
        if st != noErr { failure = "MIDIOutputPortCreate \(st)" }
    }

    deinit { if client != 0 { MIDIClientDispose(client) } }

    // MARK: endpoints

    public static func name(of e: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &cf)
        return cf?.takeRetainedValue() as String? ?? ""
    }

    /// The names of the MIDI inputs and outputs of the Mac, without the virtual ports of this driver.
    public static func available() -> (inputs: [String], outputs: [String]) {
        func names(_ n: Int, _ get: (Int) -> MIDIEndpointRef) -> [String] {
            var out: [String] = []
            for i in 0..<n { let s = name(of: get(i)); if !s.isEmpty, !s.hasPrefix("GS-R24M"), !out.contains(s) { out.append(s) } }
            return out
        }
        return (names(MIDIGetNumberOfSources(), { MIDIGetSource($0) }), names(MIDIGetNumberOfDestinations(), { MIDIGetDestination($0) }))
    }

    private static func find(_ name: String, _ n: Int, _ get: (Int) -> MIDIEndpointRef) -> MIDIEndpointRef? {
        guard !name.isEmpty else { return nil }
        for i in 0..<n where Self.name(of: get(i)) == name { return get(i) }
        return nil
    }

    // MARK: connection

    /// Chooses the interface by the names of its input and output (empty: none). Used again when the choice changes.
    public func configure(input: String, output: String) {
        queue.async {
            guard input != self.wantedIn || output != self.wantedOut || self.client != 0 && !self.connected else { return }
            self.wantedIn = input; self.wantedOut = output
            self.connect()
        }
    }

    public func close() {
        queue.async {
            if let s = self.source { MIDIPortDisconnectSource(self.inPort, s) }
            self.source = nil; self.destination = nil; self.wantedIn = ""; self.wantedOut = ""
            self.setConnected(false)
        }
    }

    private func connect() {
        if let s = source { MIDIPortDisconnectSource(inPort, s); source = nil }
        destination = nil
        if let s = Self.find(wantedIn, MIDIGetNumberOfSources(), { MIDIGetSource($0) }), MIDIPortConnectSource(inPort, s, nil) == noErr { source = s }
        destination = Self.find(wantedOut, MIDIGetNumberOfDestinations(), { MIDIGetDestination($0) })
        setConnected(source != nil && destination != nil)
    }

    private func setConnected(_ c: Bool) {
        guard connected != c else { return }
        connected = c; onConnectionChange?(c)
    }

    public func send(_ bytes: [UInt8]) {
        queue.async {
            guard let dst = self.destination, !bytes.isEmpty else { return }
            var offset = 0
            while offset < bytes.count {
                let chunk = Array(bytes[offset..<min(bytes.count, offset + 256)]); offset += chunk.count
                var buffer = [UInt8](repeating: 0, count: 1024)
                buffer.withUnsafeMutableBytes { raw in
                    let list = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
                    let p = MIDIPacketListInit(list)
                    _ = MIDIPacketListAdd(list, 1024, p, 0, chunk.count, chunk)
                    MIDISend(self.outPort, dst, list)
                }
            }
        }
    }
}

/// What the host sees as the card: the daemon's MIDI ports, or the external interface when the settings name one. In the external case the console has
/// a single socket pair, so it is the card port of the console (`consolePort`); the other ports are not sent.
public final class RoutedCardMIDI: CardMIDI {
    public var onReceive: ((_ port: Int, _ bytes: [UInt8]) -> Void)?
    public var onConnectionChange: ((Bool) -> Void)?
    public var connected: Bool { external ? ext.connected : xpc.connected }
    public private(set) var external = false

    private let xpc: XPCCardMIDI
    private let ext: ExternalMIDI
    private let queue: DispatchQueue
    private var consolePort = 0

    public init(queue: DispatchQueue) {
        self.queue = queue
        xpc = XPCCardMIDI(queue: queue); ext = ExternalMIDI(queue: queue)
        xpc.onReceive = { [weak self] port, bytes in if let self, !self.external { self.onReceive?(port, bytes) } }
        ext.onReceive = { [weak self] bytes in if let self, self.external { self.onReceive?(self.consolePort, bytes) } }
        xpc.onConnectionChange = { [weak self] up in if let self, !self.external { self.onConnectionChange?(up) } }
        ext.onConnectionChange = { [weak self] up in if let self, self.external { self.onConnectionChange?(up) } }
    }

    public func start() { xpc.start() }

    /// Follows the settings (call on the agent's queue): the route and the interface chosen.
    public func apply(_ s: MIDISettings) {
        consolePort = s.consolePort
        if let r = s.externalRoute {
            let switching = !external
            external = true
            ext.configure(input: r.input, output: r.output)
            if switching { onConnectionChange?(ext.connected) }
        } else if external {
            external = false; ext.close()
            onConnectionChange?(xpc.connected)
        }
    }

    public func send(port: Int, bytes: [UInt8]) {
        if external { if port == consolePort { ext.send(bytes) } } else { xpc.send(port: port, bytes: bytes) }
    }
}
