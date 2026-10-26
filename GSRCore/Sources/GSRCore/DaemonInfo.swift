import Foundation

/// What `gsrd` reports to the app (JSON string in the reply to the "info" request).
/// Everything about the card is optional: with no card the daemon still answers with its own state.
public struct DaemonInfo: Codable, Equatable {
    public struct Stream: Codable, Equatable {
        public var index: Int
        public var iso: Int
        public var pcm: Int
        public var midi: Int
        public var speed: String
        public var names: [String]
    }
    public struct ClockSource: Codable, Equatable {
        public var id: String
        public var label: String
    }

    public var version: Int
    /// 0 = no card, 1 = card found but not streaming, 2 = streaming
    public var state: Int
    public var generation: Int
    public var haveCard: Bool
    public var owned: Bool
    public var sessions: Int
    public var busResets: Int
    public var uptime: Double
    public var leadMs: Int
    public var ioClients: Int
    public var inLate: UInt64
    public var outLate: UInt64
    public var inWritten: UInt64
    public var cipErrors: UInt64
    public var dbcJumps: UInt64
    public var maxGapMs: Double
    public var error: String
    public var customIn: [String]
    public var customOut: [String]

    public var guid: String?
    public var vendor: String?
    public var model: String?
    public var vendorID: UInt32?
    public var modelID: UInt32?
    public var unitSpecID: UInt32?
    public var nickName: String?
    public var clockSource: String?
    public var rate: Int?
    public var locked: Bool?
    public var ext: UInt32?
    public var dice: String?
    public var rates: [Int]?
    public var sources: [String]?
    public var clockSources: [ClockSource]?
    public var tx: [Stream]?
    public var rx: [Stream]?

    public static func decode(_ json: String) -> DaemonInfo? {
        try? JSONDecoder().decode(DaemonInfo.self, from: Data(json.utf8))
    }

    public var isStreaming: Bool { state == 2 }

    /// The same structure the rest of the app uses for a card read with `dicedump`.
    public func report() -> DiceReport? {
        guard haveCard, let g = guid, let guidValue = UInt64(g.replacingOccurrences(of: "0x", with: ""), radix: 16) else { return nil }
        var r = DiceReport()
        r.guid = guidValue
        r.vendor = vendor ?? ""; r.model = model ?? ""
        r.vendorID = vendorID; r.modelID = modelID; r.unitSpecID = unitSpecID
        r.nickName = nickName ?? ""
        r.clockSourceID = clockSource ?? ""
        r.currentRate = rate
        r.locked = locked ?? false
        r.version = dice ?? ""
        r.supportedRates = rates ?? []
        r.supportedSources = sources ?? []
        r.clockSources = (clockSources ?? []).enumerated().map { DiceClockSource(index: $0.offset, id: $0.element.id, label: $0.element.label) }
        func conv(_ s: [Stream]?) -> [DiceStream] {
            (s ?? []).map { DiceStream(index: $0.index, isochronous: $0.iso, pcmChannels: $0.pcm, midiPorts: $0.midi,
                                       speed: $0.speed.isEmpty ? nil : $0.speed, names: $0.names) }
        }
        r.tx = conv(tx); r.rx = conv(rx)
        return r
    }

    /// Lead of the playback stream chosen by each operation mode of the vendor panel, in milliseconds.
    public static let modeLeads: [(name: String, ms: Int)] = [
        ("Lowest Latency", 40), ("Normal Mode", 80), ("Safe Mode Level 1", 160), ("Safe Mode Level 2", 300),
    ]
    /// The playback lead is also the output safety offset announced to CoreAudio, plus 3 ms.
    public static func outputLatencyMs(forLead ms: Int) -> Int { ms + 3 }
    /// Input safety offset announced for each lead (covers the late callbacks of the capture side).
    public static func inputSafetyMs(forLead ms: Int) -> Int { ms <= 40 ? 6 : ms <= 80 ? 10 : ms <= 160 ? 16 : 30 }

    public static func modeName(forLead ms: Int) -> String {
        modeLeads.min { abs($0.ms - ms) < abs($1.ms - ms) }?.name ?? "Normal Mode"
    }
}

/// Builds the 32-entry lists sent to the daemon from the stored names: index 0 is channel 1, "" means the card's name.
public extension ChannelNameStore {
    func lists(guid: UInt64, channels: Int = 32) -> (inputs: [String], outputs: [String]) {
        (  (1...channels).map { name(guid: guid, .input, channel: $0) ?? "" },
           (1...channels).map { name(guid: guid, .output, channel: $0) ?? "" } )
    }
}
