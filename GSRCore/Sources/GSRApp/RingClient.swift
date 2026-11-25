import Foundation
import GSRCore

/// Asks gsrd for the shared audio rings, the way the CoreAudio plug-in does (XPC shared memory), and keeps the mapping alive as long as the tap lives.
/// Read only use: nothing is ever written into the rings from here.
enum RingClient {
    private final class Mapping { // unmaps when the last reader is gone
        let addr: UnsafeMutableRawPointer, size: Int
        init(addr: UnsafeMutableRawPointer, size: Int) { self.addr = addr; self.size = size }
        deinit { munmap(addr, size) }
    }

    /// Blocks for the round trip: call it off the main thread. nil when gsrd does not answer or hands out something that is not a ring.
    static func fetch() -> RingTap? {
        let q = DispatchQueue(label: "gsr.ringclient")
        let c = xpc_connection_create_mach_service(DaemonClient.serviceName, q, 0)
        xpc_connection_set_event_handler(c) { _ in }
        xpc_connection_resume(c)
        defer { xpc_connection_cancel(c) }
        let m = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(m, "op", "ring")
        let reply = xpc_connection_send_message_with_reply_sync(c, m)
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY, let shm = xpc_dictionary_get_value(reply, "ring") else { return nil }
        var addr: UnsafeMutableRawPointer?
        let size = xpc_shmem_map(shm, &addr)
        guard size > 4096, let a = addr else { return nil }
        let map = Mapping(addr: a, size: size)
        return RingTap(region: UnsafeRawPointer(a), bytes: size, keep: map)
    }
}
