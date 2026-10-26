import Foundation
import GSRCore

/// Talks to `gsrd` over its Mach service (XPC, C API). All calls block for the round trip: use them off the main thread.
final class DaemonClient {
    static let serviceName = "com.gsr24m.gsrd"
    private var connection: xpc_connection_t?
    private let queue = DispatchQueue(label: "gsr.daemonclient")

    private func conn() -> xpc_connection_t {
        if let c = connection { return c }
        let c = xpc_connection_create_mach_service(Self.serviceName, queue, 0)
        xpc_connection_set_event_handler(c) { [weak self] _ in
            // invalid or interrupted: drop it, the next call opens a new one
            self?.queue.async { self?.connection = nil }
        }
        xpc_connection_resume(c)
        connection = c
        return c
    }

    private func call(_ message: xpc_object_t) -> xpc_object_t {
        let reply = xpc_connection_send_message_with_reply_sync(conn(), message)
        return reply
    }

    private func simple(_ op: String, _ fill: (xpc_object_t) -> Void) -> Bool {
        let m = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(m, "op", op)
        fill(m)
        let r = call(m)
        return xpc_dictionary_get_bool(r, "ok")
    }

    /// nil when the daemon does not answer (not installed, not running, or an old version).
    func info() -> DaemonInfo? {
        let m = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(m, "op", "info")
        let r = call(m)
        guard let c = xpc_dictionary_get_string(r, "json") else {
            queue.async { self.connection = nil }
            return nil
        }
        return DaemonInfo.decode(String(cString: c))
    }

    func setRate(_ hz: Int) -> Bool { simple("setRate") { xpc_dictionary_set_uint64($0, "rate", UInt64(hz)) } }
    func setSource(_ id: String) -> Bool { simple("setSource") { xpc_dictionary_set_string($0, "id", id) } }
    func setLead(ms: Int) -> Bool { simple("setLead") { xpc_dictionary_set_uint64($0, "ms", UInt64(ms)) } }

    /// 32 entries per direction, "" = the card's own name.
    func setNames(inputs: [String], outputs: [String]) -> Bool {
        simple("setNames") { m in
            let a = xpc_array_create(nil, 0), b = xpc_array_create(nil, 0)
            for k in 0..<32 {
                xpc_array_set_string(a, -1, k < inputs.count ? inputs[k] : "")    // -1 = XPC_ARRAY_APPEND
                xpc_array_set_string(b, -1, k < outputs.count ? outputs[k] : "")
            }
            xpc_dictionary_set_value(m, "in", a); xpc_dictionary_set_value(m, "out", b)
        }
    }
}
