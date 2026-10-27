import Foundation

/// Turns a stream of MIDI bytes (one port) into whole messages: running status, system exclusive and real-time bytes included.
public struct MIDIParser {
    private var status: UInt8 = 0
    private var data: [UInt8] = []
    private var need = 0
    private var sysex: [UInt8]?

    public init() {}

    public mutating func reset() { status = 0; data = []; need = 0; sysex = nil }

    /// Feeds one byte; returns a complete message (status byte included) when this byte finishes one.
    public mutating func feed(_ b: UInt8) -> [UInt8]? {
        if b >= 0xF8 { return [b] }                                   // real-time bytes can fall anywhere, even inside a system exclusive
        if sysex != nil {
            if b == 0xF7 { let m = sysex! + [0xF7]; sysex = nil; return m }
            if b & 0x80 != 0 { sysex = nil } else { sysex!.append(b); return nil }      // a status byte aborts the system exclusive
        }
        if b & 0x80 != 0 {
            data = []
            switch b {
            case 0xF0: sysex = [0xF0]; status = 0; return nil
            case 0xF1, 0xF3: status = b; need = 1
            case 0xF2: status = b; need = 2
            case 0xF4, 0xF5, 0xF6, 0xF7: status = 0; return b == 0xF6 ? [b] : nil
            default: status = b; need = (b & 0xF0) == 0xC0 || (b & 0xF0) == 0xD0 ? 1 : 2
            }
            return nil
        }
        guard status != 0 else { return nil }                          // data byte without a status: ignored
        data.append(b)
        if data.count < need { return nil }
        let m = [status] + data
        data = []
        if status >= 0xF0 { status = 0 }                               // system common messages cancel running status
        return m
    }

    /// Convenience for tests and for whole buffers.
    public mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] { bytes.compactMap { feed($0) } }
}

/// Splits bytes that are already known to be complete messages back into messages (used by the bridge for several messages in one buffer).
public func midiMessages(_ bytes: [UInt8]) -> [[UInt8]] {
    var p = MIDIParser()
    return p.feed(bytes)
}
