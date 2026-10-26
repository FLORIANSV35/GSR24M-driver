import Foundation

/// IEC 61883-6 sample-rate codes (FDF low bits for AM824) and the per-rate
/// packet parameters used by DICE devices in blocking mode.
public enum SampleRate: Int, CaseIterable {
    case r32000 = 32000, r44100 = 44100, r48000 = 48000
    case r88200 = 88200, r96000 = 96000, r176400 = 176400, r192000 = 192000

    /// FDF value for AM824 (SFC code).
    public var fdf: UInt8 {
        switch self {
        case .r32000: return 0
        case .r44100: return 1
        case .r48000: return 2
        case .r88200: return 3
        case .r96000: return 4
        case .r176400: return 5
        case .r192000: return 6
        }
    }
    public init?(fdf: UInt8) {
        guard let r = SampleRate.allCases.first(where: { $0.fdf == fdf }) else { return nil }
        self = r
    }
    /// SYT interval: audio frames per packet in blocking mode.
    public var sytInterval: Int {
        switch self {
        case .r32000, .r44100, .r48000: return 8
        case .r88200, .r96000: return 16
        case .r176400, .r192000: return 32
        }
    }
}

/// CIP header (two quadlets) for AM824 streams.
public struct CIPHeader: Equatable {
    public static let noInfoSYT: UInt16 = 0xFFFF
    public static let formatAM824: UInt8 = 0x10

    public var sourceID: UInt8      // 6 bits
    public var dataBlockSize: UInt8 // DBS, quadlets per data block
    public var dataBlockCount: UInt8 // DBC
    public var fdf: UInt8
    public var syt: UInt16

    public init(sourceID: UInt8, dataBlockSize: UInt8, dataBlockCount: UInt8, fdf: UInt8, syt: UInt16) {
        self.sourceID = sourceID & 0x3F
        self.dataBlockSize = dataBlockSize
        self.dataBlockCount = dataBlockCount
        self.fdf = fdf
        self.syt = syt
    }

    public func encoded() -> [UInt8] {
        [sourceID & 0x3F, dataBlockSize, 0x00, dataBlockCount,
         0x80 | CIPHeader.formatAM824, fdf, UInt8(syt >> 8), UInt8(syt & 0xFF)]
    }

    /// Returns nil unless both end-of-header bits and the format are as expected.
    public init?(_ b: [UInt8]) {
        guard b.count >= 8, b[0] & 0xC0 == 0x00, b[4] & 0xC0 == 0x80, b[4] & 0x3F == CIPHeader.formatAM824 else { return nil }
        self.init(sourceID: b[0] & 0x3F, dataBlockSize: b[1], dataBlockCount: b[3], fdf: b[5],
                  syt: UInt16(b[6]) << 8 | UInt16(b[7]))
    }
}

/// AM824 quadlets: label byte then 24 bits.
public enum AM824 {
    public static let labelMBLA: UInt8 = 0x40        // raw 24-bit audio
    public static let labelMIDINoData: UInt8 = 0x80
    public static let labelMIDI1Byte: UInt8 = 0x81

    /// Wire (big-endian) quadlet for a signed 32-bit sample whose top 24 bits are used.
    public static func audioQuadlet(fromInt32 s: Int32) -> UInt32 {
        UInt32(AM824.labelMBLA) << 24 | (UInt32(bitPattern: s) >> 8)
    }
    /// Signed 32-bit sample, left-justified, from a received quadlet. The label is ignored.
    public static func int32(fromQuadlet q: UInt32) -> Int32 {
        Int32(bitPattern: (q & 0x00FF_FFFF) << 8)
    }
    public static func midiQuadlet(byte: UInt8?) -> UInt32 {
        guard let b = byte else { return UInt32(labelMIDINoData) << 24 }
        return UInt32(labelMIDI1Byte) << 24 | UInt32(b) << 16
    }
    public static func midiByte(fromQuadlet q: UInt32) -> UInt8? {
        (q >> 24) == UInt32(labelMIDI1Byte) ? UInt8((q >> 16) & 0xFF) : nil
    }

    /// Packs interleaved frames into a data payload (big-endian quadlets).
    /// `frames` holds `frameCount * pcmChannels` samples; when `midiSlot` is true one extra
    /// MIDI quadlet is appended to every data block (value taken from `midi[frame]`, or no-data).
    public static func pack(frames: [Int32], pcmChannels: Int, frameCount: Int,
                            midiSlot: Bool, midi: [UInt8?] = []) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(frameCount * (pcmChannels + (midiSlot ? 1 : 0)) * 4)
        func put(_ q: UInt32) { out += [UInt8(q >> 24), UInt8((q >> 16) & 0xFF), UInt8((q >> 8) & 0xFF), UInt8(q & 0xFF)] }
        for f in 0..<frameCount {
            for c in 0..<pcmChannels { put(audioQuadlet(fromInt32: frames[f * pcmChannels + c])) }
            if midiSlot { put(midiQuadlet(byte: f < midi.count ? midi[f] : nil)) }
        }
        return out
    }

    public static func unpack(payload: [UInt8], pcmChannels: Int, midiSlot: Bool) -> (frames: [Int32], midi: [UInt8?]) {
        let dbs = pcmChannels + (midiSlot ? 1 : 0)
        let blocks = payload.count / (dbs * 4)
        var frames = [Int32](); frames.reserveCapacity(blocks * pcmChannels)
        var midi = [UInt8?]()
        func q(_ i: Int) -> UInt32 {
            UInt32(payload[i]) << 24 | UInt32(payload[i + 1]) << 16 | UInt32(payload[i + 2]) << 8 | UInt32(payload[i + 3])
        }
        for b in 0..<blocks {
            let base = b * dbs * 4
            for c in 0..<pcmChannels { frames.append(int32(fromQuadlet: q(base + c * 4))) }
            if midiSlot { midi.append(midiByte(fromQuadlet: q(base + pcmChannels * 4))) }
        }
        return (frames, midi)
    }
}
