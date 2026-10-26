import Foundation

/// User-chosen channel names, per device (GUID) and direction. Channel numbers start at 1 and count
/// across all streams of a direction, so they match the channel numbers a DAW shows.
///
/// "input" is a DAW input (card to Mac, the TX streams of the device); "output" is a DAW output.
/// The names are stored on the Mac only. Nothing is written to the card.
public struct ChannelNameStore: Codable, Equatable {
    public enum Direction: String, Codable { case input, output }

    public struct DeviceNames: Codable, Equatable {
        public var inputs: [String: String] = [:]
        public var outputs: [String: String] = [:]
        public init() {}
    }

    public var devices: [String: DeviceNames] = [:]
    public init() {}

    private static func key(_ guid: UInt64) -> String { String(format: "%016llX", guid) }

    public func name(guid: UInt64, _ dir: Direction, channel: Int) -> String? {
        guard let d = devices[Self.key(guid)] else { return nil }
        return (dir == .input ? d.inputs : d.outputs)[String(channel)]
    }

    /// An empty or whitespace-only name removes the custom name.
    public mutating func set(guid: UInt64, _ dir: Direction, channel: Int, name: String) {
        let k = Self.key(guid)
        var d = devices[k] ?? DeviceNames()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if dir == .input {
            if clean.isEmpty { d.inputs[String(channel)] = nil } else { d.inputs[String(channel)] = clean }
        } else {
            if clean.isEmpty { d.outputs[String(channel)] = nil } else { d.outputs[String(channel)] = clean }
        }
        devices[k] = (d.inputs.isEmpty && d.outputs.isEmpty) ? nil : d
    }

    public mutating func reset(guid: UInt64) { devices[Self.key(guid)] = nil }

    /// Shared location, so the future CoreAudio plug-in and daemon can read the same file.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GSR24M", isDirectory: true)
            .appendingPathComponent("channel-names.json")
    }

    public static func load(from url: URL = defaultURL) -> ChannelNameStore {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(ChannelNameStore.self, from: data) else { return ChannelNameStore() }
        return s
    }

    @discardableResult
    public func save(to url: URL = defaultURL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(self).write(to: url, options: .atomic)
            return true
        } catch { return false }
    }
}
