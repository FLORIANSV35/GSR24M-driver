import CoreMIDI
import Foundation

/// The virtual MIDI ports the applications see: "GS-R24M MIDI 1 to 3" (Legacy) and "GS-R24M HUI 1 to 3" (Pro Tools). Both sets always exist,
/// so that an application keeps its settings when the mode changes; the ones of the inactive mode are silent. Callbacks come on `queue`.
public final class CoreMIDIVirtual: VirtualMIDI {
    public var onFromApplications: ((_ endpoint: MIDIEndpoint, _ bytes: [UInt8]) -> Void)?

    private let queue: DispatchQueue
    private var client = MIDIClientRef()
    private var sources: [MIDIEndpoint: MIDIEndpointRef] = [:]
    private var destinations: [MIDIEndpoint: MIDIEndpointRef] = [:]
    public private(set) var failure: String?

    public static func name(of e: MIDIEndpoint, prefix: String = "GS-R24M") -> String {
        switch e { case .legacy(let n): return "\(prefix) MIDI \(n + 1)"; case .hui(let n): return "\(prefix) HUI \(n + 1)" }
    }

    /// `prefix` and `idBase` let a test create its own ports next to the real ones.
    public init(queue: DispatchQueue, prefix: String = "GS-R24M", idBase: Int32 = 0x47535200) {
        self.queue = queue
        var st = MIDIClientCreateWithBlock("\(prefix) agent" as CFString, &client) { _ in }
        if st != noErr { failure = "MIDIClientCreate \(st)"; return }
        let all: [MIDIEndpoint] = (0..<3).map { .legacy($0) } + (0..<3).map { .hui($0) }
        for (i, e) in all.enumerated() {
            let name = Self.name(of: e, prefix: prefix) as CFString
            var src = MIDIEndpointRef(), dst = MIDIEndpointRef()
            st = MIDISourceCreate(client, name, &src)
            if st != noErr { failure = "MIDISourceCreate \(st)"; return }
            st = MIDIDestinationCreateWithBlock(client, name, &dst) { [weak self] list, _ in
                guard let self else { return }
                let bytes = Self.bytes(in: list)
                if !bytes.isEmpty { self.queue.async { self.onFromApplications?(e, bytes) } }
            }
            if st != noErr { failure = "MIDIDestinationCreate \(st)"; return }
            MIDIObjectSetIntegerProperty(src, kMIDIPropertyUniqueID, idBase + Int32(i * 2))          // stable ids: applications remember the ports
            MIDIObjectSetIntegerProperty(dst, kMIDIPropertyUniqueID, idBase + Int32(i * 2 + 1))
            sources[e] = src; destinations[e] = dst
        }
    }

    deinit {
        for r in sources.values { MIDIEndpointDispose(r) }
        for r in destinations.values { MIDIEndpointDispose(r) }
        if client != 0 { MIDIClientDispose(client) }
    }

    /// The bytes of all the packets of a list. The packets are walked in place: copying the first one (a 256-byte structure) and walking from the
    /// copy reads outside of it as soon as the list has a second packet or a packet longer than 256 bytes, which crashed the agent when Pro Tools
    /// sent a burst.
    public static func bytes(in list: UnsafePointer<MIDIPacketList>) -> [UInt8] {
        var out: [UInt8] = []
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data)!
        var cur = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIPacketList>.offset(of: \.packet)!).assumingMemoryBound(to: MIDIPacket.self)
        for _ in 0..<Int(list.pointee.numPackets) {
            let n = Int(cur.pointee.length)
            let data = UnsafeRawPointer(cur).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
            out += UnsafeBufferPointer(start: data, count: n)
            cur = UnsafePointer(MIDIPacketNext(cur))
        }
        return out
    }

    public func sendToApplications(_ endpoint: MIDIEndpoint, bytes: [UInt8]) {
        guard let src = sources[endpoint], !bytes.isEmpty else { return }
        var offset = 0
        while offset < bytes.count {
            let chunk = Array(bytes[offset..<min(bytes.count, offset + 256)]); offset += chunk.count
            var buffer = [UInt8](repeating: 0, count: 1024)
            buffer.withUnsafeMutableBytes { raw in
                let list = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
                let p = MIDIPacketListInit(list)
                _ = MIDIPacketListAdd(list, 1024, p, 0, chunk.count, chunk)
                MIDIReceived(src, list)
            }
        }
    }
}
