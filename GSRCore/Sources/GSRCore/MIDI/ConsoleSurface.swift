import Foundation

/// A physical control of the GS-R24M's MIDI section, with the shift layer kept apart.
public struct ConsoleControl: Hashable, Codable, CustomStringConvertible {
    public let id: String
    public init(_ id: String) { self.id = id }
    public var description: String { id }

    public static func sel(_ n: Int) -> ConsoleControl { .init("sel.\(n)") }                 // 1 to 24
    public static func st(_ n: Int) -> ConsoleControl { .init("st.\(n)") }                   // 1 to 2
    public static func fader(_ n: Int) -> ConsoleControl { .init("fader.\(n)") }             // 1 to 24
    public static func button(_ n: Int) -> ConsoleControl { .init("button.\(n)") }           // 1 to 8
    public static func pot(_ n: Int) -> ConsoleControl { .init("pot.\(n)") }                 // 1 to 12
    public static func midiFader(_ n: Int) -> ConsoleControl { .init("midifader.\(n)") }     // 1 to 2
    public static let shift = ConsoleControl("shift")
    public static let arrowUp = ConsoleControl("arrow.up"), arrowLeft = ConsoleControl("arrow.left"), arrowCentre = ConsoleControl("arrow.centre")
    public static let arrowRight = ConsoleControl("arrow.right"), arrowDown = ConsoleControl("arrow.down")
    public static let gts = ConsoleControl("transport.gts"), stop = ConsoleControl("transport.stop"), play = ConsoleControl("transport.play")
    public static let gte = ConsoleControl("transport.gte"), rec = ConsoleControl("transport.rec")
    public static let jogSwitch = ConsoleControl("jog.switch"), jogWheel = ConsoleControl("jog.wheel")

    public var isFader: Bool { id.hasPrefix("fader.") }
    /// Number after the dot, for the controls that come in series.
    public var index: Int? { Int(id.split(separator: ".").last ?? "") }
}

public enum Layer: String, Codable, CaseIterable { case plain, shift }

public enum ControlEvent: Equatable {
    case down, up
    case value(UInt8)
}

/// How the console's MIDI messages map to controls. The codes come from the A&H user guide (p.32 to 34) and, for what the manual leaves out, from the codes
/// the owner's Bome project listens to; see docs/MIDI.md. Everything here can be replaced by `learn`.
public struct ConsoleMap {
    public enum Pattern: Hashable, Codable {
        case note(channel: UInt8, note: UInt8)
        case controller(channel: UInt8, number: UInt8)
        case mmc(UInt8)
    }
    public struct Entry: Hashable, Codable { public var control: ConsoleControl; public var layer: Layer?; public init(_ c: ConsoleControl, _ l: Layer?) { control = c; layer = l } }

    public private(set) var table: [Pattern: Entry] = [:]
    public init() {}

    public mutating func set(_ p: Pattern, _ control: ConsoleControl, layer: Layer? = nil) { table[p] = Entry(control, layer) }
    public mutating func remove(control: ConsoleControl) { table = table.filter { $0.value.control != control } }

    /// The pattern a message carries and the event it stands for. `layer` is nil when the console does not encode the shift layer in the code.
    public static func pattern(of m: [UInt8]) -> (Pattern, ControlEvent)? {
        if m.count == 3 {
            let kind = m[0] & 0xF0, ch = m[0] & 0x0F
            switch kind {
            case 0x90: return (.note(channel: ch, note: m[1]), m[2] > 0 ? .down : .up)
            case 0x80: return (.note(channel: ch, note: m[1]), .up)
            case 0xB0: return (.controller(channel: ch, number: m[1]), .value(m[2]))
            default: return nil
            }
        }
        // MMC: F0 7F device 06 command F7
        if m.count == 6, m[0] == 0xF0, m[1] == 0x7F, m[3] == 0x06, m[5] == 0xF7 { return (.mmc(m[4]), .down) }

        return nil
    }

    public func identify(_ m: [UInt8]) -> (control: ConsoleControl, layer: Layer?, event: ControlEvent)? {
        guard let (p, e) = Self.pattern(of: m) else { return nil }
        guard let hit = table[p] else { return nil }
        return (hit.control, hit.layer, e)
    }

    /// The owner's console: mode 3 (default MIDI, external tally, no tick), the mode his Bome project works with; the codes of the default map plus what that project listens to. `channel` is the MIDI channel set on the console (0 for channel 1).
    public static func mode3(channel ch: UInt8 = 0) -> ConsoleMap {
        var m = ConsoleMap()
        for n in 1...24 {
            m.set(.controller(channel: ch, number: UInt8(n)), .fader(n))
            m.set(.note(channel: ch, note: UInt8(n)), .sel(n))            // mode 3: Shift does not change the code, the bridge follows the Shift note
            m.set(.note(channel: ch, note: UInt8(0x22 + n)), .sel(n), layer: .shift)
        }
        m.set(.note(channel: ch, note: 0x21), .st(1)); m.set(.note(channel: ch, note: 0x43), .st(1), layer: .shift)
        m.set(.note(channel: ch, note: 0x22), .st(2)); m.set(.note(channel: ch, note: 0x44), .st(2), layer: .shift)
        for n in 1...8 { m.set(.note(channel: ch, note: UInt8(0x6C + n)), .button(n)) }
        m.set(.note(channel: ch, note: 0x6C), .shift)
        for (c, n) in [(ConsoleControl.arrowUp, 0x75), (.arrowLeft, 0x76), (.arrowCentre, 0x77), (.arrowRight, 0x78), (.arrowDown, 0x79)] { m.set(.note(channel: ch, note: UInt8(n)), c) }
        m.set(.note(channel: ch, note: 0x7A), .jogSwitch)
        m.set(.controller(channel: ch, number: 0x7B), .jogWheel)
        for (c, code) in [(ConsoleControl.gts, 0x05), (.stop, 0x01), (.play, 0x02), (.gte, 0x04), (.rec, 0x06)] { m.set(.mmc(UInt8(code)), c) }
        // the same buttons as notes, for the modes where the transport sends note on and off
        for (c, n) in [(ConsoleControl.gts, 0x67), (.stop, 0x68), (.play, 0x69), (.gte, 0x6A), (.rec, 0x6B)] { m.set(.note(channel: ch, note: UInt8(n)), c) }
        for n in 1...12 { m.set(.controller(channel: ch, number: UInt8(0x3F + n)), .pot(n)) }
        m.set(.controller(channel: ch, number: 0x4C), .midiFader(1)); m.set(.controller(channel: ch, number: 0x4D), .midiFader(2))
        return m
    }

    /// Note that lights the LED of a control (the console lights an LED when it receives a note on the same number: external tally).
    public static func ledNote(_ c: ConsoleControl) -> UInt8? {
        switch c.id {
        case "st.1": return 0x21
        case "st.2": return 0x22
        case "transport.stop": return 0x68
        case "transport.play": return 0x69
        case "transport.rec": return 0x6B
        case "shift": return 0x6C
        case "arrow.centre": return 0x77
        default:
            if c.id.hasPrefix("sel."), let n = c.index { return UInt8(n) }
            if c.id.hasPrefix("button."), let n = c.index { return UInt8(0x6C + n) }
            return nil
        }
    }
}
