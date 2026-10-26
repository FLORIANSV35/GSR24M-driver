import Foundation

/// One isochronous stream block as listed in a DICE report (TX = device to host).
public struct DiceStream: Equatable {
    public var index: Int
    public var isochronous: Int
    public var pcmChannels: Int
    public var midiPorts: Int
    public var speed: String?
    public var names: [String]

    public init(index: Int, isochronous: Int, pcmChannels: Int, midiPorts: Int, speed: String?, names: [String]) {
        self.index = index; self.isochronous = isochronous; self.pcmChannels = pcmChannels
        self.midiPorts = midiPorts; self.speed = speed; self.names = names
    }
}

/// A clock source as listed in CLOCK_SOURCE_NAMES.
public struct DiceClockSource: Equatable {
    public var index: Int
    public var id: String
    public var label: String

    public init(index: Int, id: String, label: String) {
        self.index = index; self.id = id; self.label = label
    }
}

/// Read-only snapshot of a DICE device, parsed from the text report written by
/// `dicedump` or by the ASFW report app (same layout).
public struct DiceReport: Equatable {
    public var guid: UInt64?
    public var vendor = ""
    public var model = ""
    public var vendorID: UInt32?
    public var modelID: UInt32?
    public var unitSpecID: UInt32?
    public var nickName = ""
    public var clockSourceID = ""
    public var currentRate: Int?
    public var locked = false
    public var version = ""
    public var supportedRates: [Int] = []
    public var supportedSources: [String] = []
    public var clockSources: [DiceClockSource] = []
    public var tx: [DiceStream] = []
    public var rx: [DiceStream] = []

    public var captureChannels: Int { tx.reduce(0) { $0 + $1.pcmChannels } }
    public var playbackChannels: Int { rx.reduce(0) { $0 + $1.pcmChannels } }

    /// TCAT GUID layout: oui(24) category(8) product(10) serial(22).
    public var tcatOUI: UInt32? { guid.map { UInt32($0 >> 40) } }
    public var tcatCategory: UInt8? { guid.map { UInt8(($0 >> 32) & 0xFF) } }
    public var tcatProduct: UInt16? { guid.map { UInt16(($0 >> 22) & 0x3FF) } }
    public var tcatSerial: UInt32? { guid.map { UInt32($0 & 0x3FFFFF) } }

    public init() {}

    public enum ParseError: Error, Equatable { case noIdentity }

    public static func parse(_ text: String) throws -> DiceReport {
        var r = DiceReport()
        enum Section { case none, global, tx, rx, names }
        var section = Section.none
        var inClockNames = false
        var current: DiceStream?
        var inStreamNames = false

        func flush(_ direction: Section) {
            guard let s = current else { return }
            if direction == .tx { r.tx.append(s) } else if direction == .rx { r.rx.append(s) }
            current = nil
        }
        var direction = Section.none

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let t = line.trimmingCharacters(in: .whitespaces)

            if t.hasPrefix("TX STREAMS") { flush(direction); direction = .tx; section = .tx; inClockNames = false; continue }
            if t.hasPrefix("RX STREAMS") { flush(direction); direction = .rx; section = .rx; inClockNames = false; continue }
            if t == "GLOBAL" { flush(direction); direction = .none; section = .global; continue }
            if t == "EXT_SYNC" || t.hasPrefix("EAP ") || t == "NOTES" || t.hasPrefix("CONFIG ROM") {
                flush(direction); direction = .none; section = .none; inClockNames = false; continue
            }

            switch section {
            case .none:
                if let v = value(t, "GUID:") { r.guid = UInt64(v.replacingOccurrences(of: "0x", with: ""), radix: 16) }
                else if let v = value(t, "Vendor:") { r.vendor = v }
                else if let v = value(t, "Model:") { r.model = v }
                else if let v = value(t, "Vendor_ID:") { r.vendorID = hex32(v) }
                else if let v = value(t, "Model_ID:") { r.modelID = hex32(v) }
                else if let v = value(t, "Unit_Spec_ID:") { r.unitSpecID = hex32(v) }
            case .global:
                if t.hasPrefix("NICK_NAME") { r.nickName = quoted(t) ?? "" }
                else if t.hasPrefix("CLOCK_SELECT") {
                    if let a = t.range(of: "("), let b = t.range(of: ")", range: a.upperBound..<t.endIndex) {
                        r.clockSourceID = String(t[a.upperBound..<b.lowerBound])
                    }
                    if let rr = t.range(of: "rate=") {
                        let rest = t[rr.upperBound...]
                        if let a = rest.firstIndex(of: "("), let b = rest.firstIndex(of: ")") {
                            r.currentRate = Int(rest[rest.index(after: a)..<b])
                        }
                    }
                }
                else if t.hasPrefix("STATUS") { r.locked = t.contains("locked=yes") }
                else if t.hasPrefix("VERSION") {
                    if let a = t.range(of: "("), let b = t.range(of: ")", range: a.upperBound..<t.endIndex) {
                        r.version = String(t[a.upperBound..<b.lowerBound])
                    }
                }
                else if t.hasPrefix("rates") { r.supportedRates = rest(t).split(separator: " ").compactMap { Int($0) } }
                else if t.hasPrefix("sources") { r.supportedSources = rest(t).split(separator: " ").map(String.init) }
                else if t.hasPrefix("CLOCK_SOURCE_NAMES") { inClockNames = true }
                else if inClockNames {
                    let parts = t.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                    if parts.count >= 2, let idx = Int(parts[0]) {
                        let label = parts.count > 2 ? (quoted(String(parts[2])) ?? "") : ""
                        r.clockSources.append(DiceClockSource(index: idx, id: String(parts[1]), label: label))
                    }
                }
            case .tx, .rx:
                if t.hasPrefix("[stream ") {
                    flush(direction)
                    let n = Int(t.dropFirst(8).prefix(while: { $0.isNumber })) ?? 0
                    current = DiceStream(index: n, isochronous: -1, pcmChannels: 0, midiPorts: 0, speed: nil, names: [])
                    inStreamNames = false
                } else if current != nil {
                    if t.hasPrefix("ISOCHRONOUS") { current?.isochronous = Int(t.split(separator: " ").first { Int($0) != nil } ?? "") ?? -1 }
                    else if t.hasPrefix("PCM channels") { current?.pcmChannels = intAfterEquals(t) }
                    else if t.hasPrefix("MIDI ports") { current?.midiPorts = intAfterEquals(t) }
                    else if t.hasPrefix("SPEED") { current?.speed = t.split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespaces) } }
                    else if t.hasPrefix("NAMES:") { inStreamNames = true }
                    else if inStreamNames, let q = quoted(t) { current?.names.append(q) }
                }
            case .names: break
            }
        }
        flush(direction)
        guard r.guid != nil || !r.model.isEmpty else { throw ParseError.noIdentity }
        return r
    }

    private static func value(_ t: String, _ key: String) -> String? {
        guard t.hasPrefix(key) else { return nil }
        return t.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
    }
    private static func hex32(_ v: String) -> UInt32? {
        let digits = v.split(separator: " ").first.map(String.init) ?? v
        return UInt32(digits.replacingOccurrences(of: "0x", with: ""), radix: 16)
    }
    private static func rest(_ t: String) -> String {
        guard let i = t.firstIndex(of: ":") else { return "" }
        return t[t.index(after: i)...].trimmingCharacters(in: .whitespaces)
    }
    private static func quoted(_ t: String) -> String? {
        guard let a = t.firstIndex(of: "'"), let b = t.lastIndex(of: "'"), a < b else { return nil }
        return String(t[t.index(after: a)..<b])
    }
    private static func intAfterEquals(_ t: String) -> Int {
        guard let i = t.firstIndex(of: "=") else { return 0 }
        return Int(t[t.index(after: i)...].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") ?? 0
    }
}


public extension String {
    /// The card announces a channel as "CH16/CH15/16": channel name, then the label of its stereo pair.
    /// Only the first part is the name to show.
    var channelShortName: String {
        String(split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(self))
    }
}
