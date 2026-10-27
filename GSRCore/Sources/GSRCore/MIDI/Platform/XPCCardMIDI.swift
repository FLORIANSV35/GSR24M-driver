import Foundation

/// The card's MIDI ports through gsrd (Mach service, XPC): subscribes to what the console sends and sends bytes to a port.
/// Callbacks come on `queue`. If the daemon goes away or is replaced, the subscription is made again by itself.
public final class XPCCardMIDI: CardMIDI {
    public var onReceive: ((_ port: Int, _ bytes: [UInt8]) -> Void)?
    public var onConnectionChange: ((Bool) -> Void)?
    public private(set) var connected = false

    private let service: String
    private let queue: DispatchQueue
    private var connection: xpc_connection_t?
    private var retry: DispatchSourceTimer?
    private var generation = 0

    public init(service: String = "com.gsr24m.gsrd", queue: DispatchQueue) {
        self.service = service; self.queue = queue
    }

    public func start() {
        queue.async { self.connect() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in if self?.connected == false { self?.connect() } }
        t.resume(); retry = t
    }

    private func setConnected(_ c: Bool) {
        guard connected != c else { return }
        connected = c; onConnectionChange?(c)
    }

    private func connect() {
        generation += 1
        let mine = generation
        if let old = connection { xpc_connection_cancel(old) }
        let c = xpc_connection_create_mach_service(service, queue, 0)
        xpc_connection_set_event_handler(c) { [weak self] event in
            guard let self, mine == self.generation else { return }
            if xpc_get_type(event) == XPC_TYPE_ERROR { self.setConnected(false); return }       // the retry timer connects again
            guard xpc_get_type(event) == XPC_TYPE_DICTIONARY, let op = xpc_dictionary_get_string(event, "op"), String(cString: op) == "midi" else { return }
            var n = 0
            guard let p = xpc_dictionary_get_data(event, "data", &n), n > 0 else { return }
            let bytes = Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt8.self), count: n))
            self.onReceive?(Int(xpc_dictionary_get_uint64(event, "port")), bytes)
        }
        xpc_connection_resume(c)
        connection = c
        let m = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(m, "op", "midiSubscribe")
        xpc_connection_send_message_with_reply(c, m, queue) { [weak self] reply in
            guard let self, mine == self.generation else { return }
            let ok = xpc_get_type(reply) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_bool(reply, "ok")
            self.setConnected(ok)
        }
    }

    public func send(port: Int, bytes: [UInt8]) {
        guard let c = connection, connected, !bytes.isEmpty else { return }
        var offset = 0
        while offset < bytes.count {                                   // the daemon queues up to 4 KB per port; stay well under
            let chunk = Array(bytes[offset..<min(bytes.count, offset + 512)]); offset += chunk.count
            let m = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(m, "op", "midiSend")
            xpc_dictionary_set_uint64(m, "port", UInt64(port))
            chunk.withUnsafeBytes { xpc_dictionary_set_data(m, "data", $0.baseAddress!, chunk.count) }
            xpc_connection_send_message_with_reply(c, m, queue) { _ in }          // gsrd drops a message that expects no reply
        }
    }
}
