import Foundation
import GSRCore

struct AgentStatus: Equatable {
    var card: Bool                // the agent is subscribed to the card's MIDI through gsrd
    var mode: String
    var accessibility: Bool       // allowed to press keys on the computer
    var bytesIn: UInt64
    var bytesOut: UInt64
    var queued = 0, peakQueued = 0, coalesced = 0, dropped = 0       // what waits to go to the console, and what the rate limit replaced or threw away
    var sentToConsole = 0
}

/// Talks to `gsrmidiagent` (Mach service in the user's session). Calls block for the round trip: use them off the main thread.
final class AgentClient {
    static let serviceName = MIDIAgent.serviceName
    private let queue = DispatchQueue(label: "gsr.agentclient")
    private var connection: xpc_connection_t?
    private var monitor: xpc_connection_t?

    private func conn() -> xpc_connection_t {
        if let c = connection { return c }
        let c = xpc_connection_create_mach_service(Self.serviceName, queue, 0)
        xpc_connection_set_event_handler(c) { [weak self] _ in self?.queue.async { self?.connection = nil } }
        xpc_connection_resume(c)
        connection = c
        return c
    }

    private func call(_ op: String) -> xpc_object_t {
        let m = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(m, "op", op)
        return xpc_connection_send_message_with_reply_sync(conn(), m)
    }

    /// nil when the agent does not answer (not installed, not running).
    func status() -> AgentStatus? {
        let r = call("status")
        guard xpc_get_type(r) == XPC_TYPE_DICTIONARY, xpc_dictionary_get_bool(r, "ok") else { queue.async { self.connection = nil }; return nil }
        return AgentStatus(card: xpc_dictionary_get_bool(r, "card"),
                           mode: xpc_dictionary_get_string(r, "mode").map { String(cString: $0) } ?? "",
                           accessibility: xpc_dictionary_get_bool(r, "accessibility"),
                           bytesIn: xpc_dictionary_get_uint64(r, "bytesIn"), bytesOut: xpc_dictionary_get_uint64(r, "bytesOut"),
                           queued: Int(xpc_dictionary_get_uint64(r, "queued")), peakQueued: Int(xpc_dictionary_get_uint64(r, "peakQueued")),
                           coalesced: Int(xpc_dictionary_get_uint64(r, "coalesced")), dropped: Int(xpc_dictionary_get_uint64(r, "dropped")),
                           sentToConsole: Int(xpc_dictionary_get_uint64(r, "sentToConsole")))
    }

    func reload() { _ = call("reload") }

    /// Sends bytes to a HUI port of Pro Tools through the agent (the test button and the explorer).
    func sendHUI(device: Int, bytes: [UInt8]) -> Bool {
        let m = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(m, "op", "huiSend")
        xpc_dictionary_set_uint64(m, "device", UInt64(device))
        bytes.withUnsafeBytes { xpc_dictionary_set_data(m, "data", $0.baseAddress!, bytes.count) }
        let r = xpc_connection_send_message_with_reply_sync(conn(), m)
        return xpc_get_type(r) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_bool(r, "ok")
    }
    /// Moves the motorised fader of a channel to a MIDI position (the console must have READ on).
    func setFader(channel: Int, value: Int) -> Bool {
        let m = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(m, "op", "faderSet")
        xpc_dictionary_set_uint64(m, "channel", UInt64(channel)); xpc_dictionary_set_uint64(m, "value", UInt64(value))
        let r = xpc_connection_send_message_with_reply_sync(conn(), m)
        return xpc_get_type(r) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_bool(r, "ok")
    }
    func askAccessibility() { _ = call("askAccessibility") }

    /// Opens a second connection that receives the traffic. `onTraffic(direction, bytes)` is called on a private queue.
    func startMonitor(onTraffic: @escaping (String, [UInt8]) -> Void, onEvent: @escaping (String) -> Void) {
        stopMonitor()
        let c = xpc_connection_create_mach_service(Self.serviceName, queue, 0)
        xpc_connection_set_event_handler(c) { event in
            guard xpc_get_type(event) == XPC_TYPE_DICTIONARY, let op = xpc_dictionary_get_string(event, "op").map({ String(cString: $0) }) else { return }
            if op == "traffic", let dir = xpc_dictionary_get_string(event, "dir").map({ String(cString: $0) }) {
                var n = 0
                guard let p = xpc_dictionary_get_data(event, "data", &n), n > 0 else { return }
                onTraffic(dir, Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt8.self), count: n)))
            } else { onEvent(op) }
        }
        xpc_connection_resume(c)
        let m = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(m, "op", "monitorSubscribe")
        _ = xpc_connection_send_message_with_reply_sync(c, m)
        monitor = c
    }

    func stopMonitor() {
        if let c = monitor { xpc_connection_cancel(c) }
        monitor = nil
    }
}
