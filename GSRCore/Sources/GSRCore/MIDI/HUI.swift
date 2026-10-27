import Foundation

/// The part of the Mackie/Digidesign HUI protocol that Pro Tools needs from a surface, as used by the owner's Bome project (which works
/// with Pro Tools). One HUI device is 8 channel strips; 24 channels need three devices.
public enum HUI {
    public static let ping: [UInt8] = [0x90, 0x00, 0x7F]                     // answer to the keep-alive `90 00 00` Pro Tools sends
    public static let pingRequest: [UInt8] = [0x90, 0x00, 0x00]

    /// Switch press or release. Both parts are always sent together, as the Bome project does.
    public static func switchMessage(zone: UInt8, port: UInt8, pressed: Bool) -> [UInt8] {
        [0xB0, 0x0F, zone, 0xB0, 0x2F, (pressed ? 0x40 : 0x00) | (port & 0x0F)]
    }

    /// Fader position of a strip (0 to 7) from a 7-bit controller value (the console's faders are 7-bit).
    public static func fader(strip: Int, value: UInt8) -> [UInt8] {
        [0xB0, UInt8(strip & 7), value & 0x7F, 0xB0, 0x20 + UInt8(strip & 7), 0x00]
    }

    /// Jog wheel from the console's jog controller value (`B0 7B pp`): 00 to 3E clockwise steps, 7F downwards counter-clockwise.
    public static func jog(console pp: UInt8) -> [UInt8] {
        [0xB0, 0x0D, pp < 0x40 ? pp + 0x40 : 0x7F - pp]
    }

    // MARK: host to surface

    public enum FromHost: Equatable {
        case ping
        case fader(strip: Int, value: UInt8)             // 7-bit high part
        case led(zone: UInt8, port: UInt8, on: Bool)
        case smallDisplay(zone: UInt8, text: String)     // four characters of a channel strip
        case meter(zone: UInt8, level: UInt8)
        case other
    }

    /// Reads what Pro Tools sends to a surface. The parser is stateful because LEDs and faders arrive as pairs of controllers.
    public struct HostReader {
        private var zone: UInt8?
        private var faderHigh: [UInt8: UInt8] = [:]
        public init() {}

        public mutating func read(_ m: [UInt8]) -> FromHost {
            if m == pingRequest { return .ping }
            if m.count == 3, m[0] == 0xB0 {
                let c = m[1], v = m[2]
                switch c {
                case 0x0C: zone = v; return .other                                   // zone for the next LED message
                case 0x2C:
                    guard let z = zone else { return .other }
                    return .led(zone: z, port: v & 0x0F, on: v & 0x40 != 0)
                case 0x00...0x07: faderHigh[c] = v; return .other                     // hi byte of a fader
                case 0x20...0x27:
                    if let hi = faderHigh[c - 0x20] { return .fader(strip: Int(c - 0x20), value: hi) }
                    return .other
                default: return .other
                }
            }
            if m.count == 3, m[0] == 0xA0 { return .meter(zone: m[1], level: m[2]) }
            // small display: F0 00 00 66 05 00 10 zone c1 c2 c3 c4 F7
            if m.count == 13, m[0] == 0xF0, Array(m[1...6]) == [0x00, 0x00, 0x66, 0x05, 0x00, 0x10], m[12] == 0xF7 {
                return .smallDisplay(zone: m[7], text: String(decoding: m[8...11], as: UTF8.self))
            }
            return .other
        }
    }
}

/// A HUI switch address.
public struct HUISwitch: Codable, Hashable {
    public var zone: UInt8
    public var port: UInt8
    public init(zone: UInt8, port: UInt8) { self.zone = zone; self.port = port }
}

/// What a channel strip's switches are, as HUI numbers them (ports 5 and 6 are not confirmed by the Bome project).
public enum ChannelFunction: Int, Codable, CaseIterable {
    case touch = 0, select, mute, solo, auto, vSelect, insert, recRdy
    public var title: String {
        switch self {
        case .touch: return "Fader touch"
        case .select: return "Select"
        case .mute: return "Mute"
        case .solo: return "Solo"
        case .auto: return "Auto"
        case .vSelect: return "V-pot select"
        case .insert: return "Insert"
        case .recRdy: return "Record ready"
        }
    }
}

/// A HUI switch the user found and named with the explorer.
public struct UserSwitch: Codable, Equatable, Identifiable {
    public var name: String
    public var zone: UInt8
    public var port: UInt8
    public var id: String { "\(zone).\(port)" }
    public var target: HUISwitch { HUISwitch(zone: zone, port: port) }
    public init(name: String, zone: UInt8, port: UInt8) { self.name = name; self.zone = zone; self.port = port }
}

/// Names for the HUI switches, for the choice menus of the editor. Entries marked `verified` are the ones the owner's Bome project uses
/// with Pro Tools. The others follow the layout of the HUI (channel and bank keys next to the bank keys, the window keys next to Mix and Edit)
/// but were not tried: the explorer of the app lets the user test and name any zone and port.
public enum HUICatalog {
    public struct Entry: Equatable {
        public let title: String, group: String, target: HUISwitch, verified: Bool
        public init(title: String, group: String, target: HUISwitch, verified: Bool = true) { self.title = title; self.group = group; self.target = target; self.verified = verified }
    }

    public static let entries: [Entry] = [
        Entry(title: "Transport: stop", group: "Transport", target: HUISwitch(zone: 0x0E, port: 3)),
        Entry(title: "Transport: play", group: "Transport", target: HUISwitch(zone: 0x0E, port: 4)),
        Entry(title: "Transport: record", group: "Transport", target: HUISwitch(zone: 0x0E, port: 5)),
        Entry(title: "Transport: jog step left", group: "Transport", target: HUISwitch(zone: 0x0E, port: 1)),
        Entry(title: "Transport: jog step right", group: "Transport", target: HUISwitch(zone: 0x0E, port: 2)),
        Entry(title: "Transport: return to zero", group: "Transport", target: HUISwitch(zone: 0x0F, port: 0)),
        Entry(title: "Transport: return to end", group: "Transport", target: HUISwitch(zone: 0x0F, port: 1)),
        Entry(title: "Window: Mix", group: "Windows", target: HUISwitch(zone: 0x09, port: 0)),
        Entry(title: "Window: Edit", group: "Windows", target: HUISwitch(zone: 0x09, port: 1)),
        Entry(title: "Window: Transport", group: "Windows", target: HUISwitch(zone: 0x09, port: 2), verified: false),
        Entry(title: "Window: Memory locations", group: "Windows", target: HUISwitch(zone: 0x09, port: 3), verified: false),
        Entry(title: "Window: Status", group: "Windows", target: HUISwitch(zone: 0x09, port: 4), verified: false),
        Entry(title: "Bank left", group: "Navigation", target: HUISwitch(zone: 0x0A, port: 1)),
        Entry(title: "Bank right", group: "Navigation", target: HUISwitch(zone: 0x0A, port: 3)),
        Entry(title: "Channel left", group: "Navigation", target: HUISwitch(zone: 0x0A, port: 0), verified: false),
        Entry(title: "Channel right", group: "Navigation", target: HUISwitch(zone: 0x0A, port: 2), verified: false),
        Entry(title: "Cursor up (zoom)", group: "Navigation", target: HUISwitch(zone: 0x0D, port: 4)),
        Entry(title: "Cursor down (zoom)", group: "Navigation", target: HUISwitch(zone: 0x0D, port: 0)),
        Entry(title: "Cursor left (zoom)", group: "Navigation", target: HUISwitch(zone: 0x0D, port: 1)),
        Entry(title: "Cursor right (zoom)", group: "Navigation", target: HUISwitch(zone: 0x0D, port: 3)),
        Entry(title: "Zoom mode", group: "Navigation", target: HUISwitch(zone: 0x0D, port: 2)),
        Entry(title: "Scrub", group: "Navigation", target: HUISwitch(zone: 0x0D, port: 5)),
        Entry(title: "Shuttle", group: "Navigation", target: HUISwitch(zone: 0x0D, port: 6)),
        Entry(title: "Enter", group: "Keypad", target: HUISwitch(zone: 0x14, port: 0)),
    ]

    /// The catalog with what the user named.
    public static func all(user: [UserSwitch] = []) -> [Entry] {
        let known = Set(entries.map(\.target))
        return entries + user.filter { !known.contains($0.target) }.map { Entry(title: $0.name, group: "Mine", target: $0.target) }
    }

    public static func title(of s: HUISwitch, user: [UserSwitch] = []) -> String? { all(user: user).first { $0.target == s }?.title }
    public static func isVerified(_ s: HUISwitch) -> Bool { entries.first { $0.target == s }?.verified ?? false }
}

/// Keyboard shortcuts of Pro Tools in its default key map, for the keyboard action. They act on the computer, whatever the HUI says.
public enum ProToolsKeys {
    public struct Preset { public let title: String, group: String, shortcut: KeyShortcut }
    public static let presets: [Preset] = [
        Preset(title: "Undo", group: "Edit", shortcut: KeyShortcut(key: "z", command: true)),
        Preset(title: "Redo", group: "Edit", shortcut: KeyShortcut(key: "z", shift: true, command: true)),
        Preset(title: "Save", group: "Edit", shortcut: KeyShortcut(key: "s", command: true)),
        Preset(title: "Cut", group: "Edit", shortcut: KeyShortcut(key: "x", command: true)),
        Preset(title: "Copy", group: "Edit", shortcut: KeyShortcut(key: "c", command: true)),
        Preset(title: "Paste", group: "Edit", shortcut: KeyShortcut(key: "v", command: true)),
        Preset(title: "Select all", group: "Edit", shortcut: KeyShortcut(key: "a", command: true)),
        Preset(title: "Delete", group: "Edit", shortcut: KeyShortcut(key: "delete")),
        Preset(title: "Edit mode: Shuffle", group: "Edit modes", shortcut: KeyShortcut(key: "f1")),
        Preset(title: "Edit mode: Slip", group: "Edit modes", shortcut: KeyShortcut(key: "f2")),
        Preset(title: "Edit mode: Spot", group: "Edit modes", shortcut: KeyShortcut(key: "f3")),
        Preset(title: "Edit mode: Grid", group: "Edit modes", shortcut: KeyShortcut(key: "f4")),
        Preset(title: "Tool: Trim", group: "Tools", shortcut: KeyShortcut(key: "f5")),
        Preset(title: "Tool: Selector", group: "Tools", shortcut: KeyShortcut(key: "f6")),
        Preset(title: "Tool: Grabber", group: "Tools", shortcut: KeyShortcut(key: "f7")),
        Preset(title: "Toggle Mix and Edit windows", group: "Windows", shortcut: KeyShortcut(key: "=", control: true)),
        Preset(title: "Play or stop", group: "Transport", shortcut: KeyShortcut(key: "space")),
    ]
    public static func title(of k: KeyShortcut) -> String? { presets.first { $0.shortcut == k }?.title }
}
