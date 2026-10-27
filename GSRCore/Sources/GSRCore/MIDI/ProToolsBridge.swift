import Foundation

/// What a control does in Pro Tools mode.
public enum Action: Codable, Equatable {
    case none
    case hui(zone: UInt8, port: UInt8)                // pressed while the control is held
    case huiPulse(zone: UInt8, port: UInt8)           // pressed and released at once when the control goes down
    case channel(ChannelFunction)                     // for the SEL switches: this function of the channel the switch belongs to
    case setLayer(Layer, ChannelFunction)             // makes the plain or the shifted SEL switches act on this function
    case swapLayers                                   // plain and shifted SEL switches exchange their functions
    case jogToggle                                    // jogwheel: steps or scrub
    case key(KeyShortcut)                             // a keyboard shortcut on the computer
}

public struct KeyShortcut: Codable, Equatable {
    public var key: String                            // "f", "return", "space", "f5"...
    public var shift = false, control = false, option = false, command = false
    public init(key: String, shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false) {
        self.key = key; self.shift = shift; self.control = control; self.option = option; self.command = command
    }
}

/// The key of a binding: a control and its layer.
public struct BindingKey: Hashable, Codable, CustomStringConvertible {
    public var control: ConsoleControl
    public var layer: Layer
    public init(_ c: ConsoleControl, _ l: Layer = .plain) { control = c; layer = l }
    public var description: String { "\(control.id)/\(layer.rawValue)" }
}

public struct ProToolsConfig: Codable, Equatable {
    public var bindings: [String: Action]             // BindingKey.description to action
    public var plainLayer: ChannelFunction = .select  // what the plain SEL switches do at start
    public var shiftLayer: ChannelFunction = .solo    // what the shifted SEL switches do at start
    public var touchReleaseSeconds = 0.6
    public var devices = 3                            // HUI devices of 8 strips
    public var multiSelectHoldSeconds: Double?        // a SEL switch held at least this long (0.35 s when nil) lets the next one add to the selection; a quicker overlap replaces it
    public var overlapSelects: Bool?                  // true: a SEL switch pressed before the previous one is released adds to the selection (HUI's own rule); nil or false: it replaces it

    public init(bindings: [String: Action] = [:]) { self.bindings = bindings }

    public func action(_ c: ConsoleControl, _ l: Layer) -> Action { bindings[BindingKey(c, l).description] ?? .none }
    public mutating func set(_ a: Action, _ c: ConsoleControl, _ l: Layer = .plain) { bindings[BindingKey(c, l).description] = a }

    /// The owner's Bome project (active rules only), as bindings.
    public static var standard: ProToolsConfig {
        var c = ProToolsConfig()
        for n in 1...24 { c.set(.channel(.select), .sel(n), .plain); c.set(.channel(.solo), .sel(n), .shift) }    // replaced by the layers at run time
        c.set(.hui(zone: 0x0A, port: 1), .st(1)); c.set(.hui(zone: 0x0A, port: 3), .st(2))
        c.set(.jogToggle, .st(1), .shift)
        c.set(.setLayer(.shift, .solo), .button(1)); c.set(.setLayer(.shift, .mute), .button(2)); c.set(.setLayer(.shift, .recRdy), .button(3))
        c.set(.swapLayers, .button(4))
        c.set(.hui(zone: 0x14, port: 0), .button(6))
        c.set(.hui(zone: 0x09, port: 1), .button(7))
        c.set(.hui(zone: 0x09, port: 0), .button(8))
        c.set(.hui(zone: 0x0D, port: 4), .arrowUp); c.set(.hui(zone: 0x0D, port: 1), .arrowLeft); c.set(.hui(zone: 0x0D, port: 2), .arrowCentre)
        c.set(.hui(zone: 0x0D, port: 3), .arrowRight); c.set(.hui(zone: 0x0D, port: 0), .arrowDown)
        c.set(.huiPulse(zone: 0x0E, port: 3), .stop); c.set(.huiPulse(zone: 0x0E, port: 4), .play); c.set(.huiPulse(zone: 0x0E, port: 5), .rec)
        c.set(.huiPulse(zone: 0x0F, port: 0), .gts); c.set(.huiPulse(zone: 0x0F, port: 1), .gte)
        c.set(.key(KeyShortcut(key: "f", shift: true)), .button(5))       // "Pb mode" in the Bome project
        return c
    }
}

/// What the bridge asks its host to send.
public enum BridgeOutput: Equatable {
    case hui(device: Int, bytes: [UInt8])             // to HUI device 0, 1 or 2
    case console(bytes: [UInt8])                      // to the console, on its port
    case key(KeyShortcut)                             // a keystroke on the computer
}

/// Translates the console's MIDI into HUI for Pro Tools and back. Pure logic: no I/O, no clocks of its own (the caller gives the time), so it is
/// tested without hardware. Not thread safe: the owner serialises calls.
public final class ProToolsBridge {
    public var config: ProToolsConfig { didSet { applyLayers() } }
    public var map: ConsoleMap
    public private(set) var plainLayer: ChannelFunction
    public private(set) var shiftLayer: ChannelFunction
    public private(set) var layersSwapped = false
    public private(set) var scrub = false             // jogwheel mode: false = steps (the Bome project's start state), true = scrub
    public private(set) var shiftHeld = false

    private var touching: [Int: TimeInterval] = [:]   // fader number to the time its touch ends
    private var held: [ConsoleControl: (Layer, Action)] = [:]
    private var lastSEL: (control: ConsoleControl, time: TimeInterval)?     // the SEL switch pressed last, and the one before it: the console repeats
    private var previousSEL: ConsoleControl?                                 // the previous one together with the next press (seen on the hardware)
    private var heldSince: [ConsoleControl: TimeInterval] = [:]
    private var huiLEDs: [Int: Bool] = [:]          // LED states Pro Tools asked for, by device/zone/port: shown again when the SEL layer changes
    private var consoleLEDs: [[UInt8]: [UInt8]] = [:] // last LED message sent to each console LED: Pro Tools repeats them, the MIDI link is slow
    private var faderSent: [Int: UInt8] = [:]        // last position sent to each motorised fader: Pro Tools repeats it, the MIDI link is slow
    private var hostReaders = [HUI.HostReader](repeating: HUI.HostReader(), count: 3)
    private var configuredPlain: ChannelFunction, configuredShift: ChannelFunction

    public init(config: ProToolsConfig = .standard, map: ConsoleMap = .mode3()) {
        self.config = config; self.map = map
        plainLayer = config.plainLayer; shiftLayer = config.shiftLayer
        configuredPlain = config.plainLayer; configuredShift = config.shiftLayer
    }

    private func applyLayers() {
        if config.plainLayer != configuredPlain || config.shiftLayer != configuredShift {
            configuredPlain = config.plainLayer; configuredShift = config.shiftLayer
            plainLayer = configuredPlain; shiftLayer = configuredShift; layersSwapped = false
        }
        while hostReaders.count < config.devices { hostReaders.append(HUI.HostReader()) }
    }

    // MARK: start

    /// LEDs of the console at start (the Bome project's INIT): the mode buttons, and the jog LEDs.
    public func startup() -> [BridgeOutput] {
        var out: [BridgeOutput] = []
        for (key, a) in modeButtons() {
            guard let note = ConsoleMap.ledNote(key.control) else { continue }
            out += lamp(led(note, on: isActive(a)), force: true)
        }
        for n in [UInt8(0x43), 0x21] { out += lamp(led(n, on: !scrub), force: true) }
        return out
    }

    private func modeButtons() -> [(BindingKey, Action)] {
        config.bindings.compactMap { (k, a) -> (BindingKey, Action)? in
            switch a { case .setLayer, .swapLayers: return (parseKey(k), a); default: return nil }
        }.sorted { $0.0.description < $1.0.description }
    }

    private func parseKey(_ s: String) -> BindingKey {
        let p = s.split(separator: "/")
        return BindingKey(ConsoleControl(String(p[0])), Layer(rawValue: String(p.last ?? "plain")) ?? .plain)
    }

    private func isActive(_ a: Action) -> Bool {
        switch a {
        case .setLayer(let l, let f): return (isShifted(l) ? shiftLayer : plainLayer) == f
        case .swapLayers: return layersSwapped
        default: return false
        }
    }

    /// Which layer holds what a button chose. After the swap the layers have traded places: the choice of buttons 1 to 3 is then the plain layer's
    /// function and Shift+SEL selects.
    private func isShifted(_ l: Layer) -> Bool { (l == .shift) != layersSwapped }

    private func led(_ note: UInt8, on: Bool) -> [UInt8] { on ? [0x90, note, 0x7F] : [0x80, note, 0x00] }

    /// A message to a console LED, left out when that LED already shows it. `force` sends it anyway (start, layer change).
    private func lamp(_ bytes: [UInt8], force: Bool = false) -> [BridgeOutput] {
        let key = bytes[0] & 0xF0 == 0x80 ? [0x90 | (bytes[0] & 0x0F), bytes[1]] : Array(bytes.prefix(2))
        if !force, consoleLEDs[key] == bytes { return [] }
        consoleLEDs[key] = bytes
        return [.console(bytes: bytes)]
    }

    // MARK: console to HUI

    public func receiveFromConsole(_ m: [UInt8], now: TimeInterval) -> [BridgeOutput] {
        if m == [0x9F, 0x00, 0x7F] { return (0..<config.devices).map { .hui(device: $0, bytes: HUI.ping) } }     // a console tick (mode 6 only; mode 3 sends none) also answers the keep-alive
        guard let hit = map.identify(m) else { return [] }
        let c = hit.control
        if c == .shift {
            if hit.event == .down { shiftHeld = true } else if hit.event == .up { shiftHeld = false }
            return []                                                      // the console shows its shifted bank of lights by itself
        }
        switch hit.event {
        case .value(let v):
            if c.isFader, let n = c.index { return fader(n, v, now: now) }
            if c == .jogWheel { return jog(v) }
            return []
        case .down:
            if c.id.hasPrefix("sel."), isEcho(c, now: now) { return [] }
            let layer = hit.layer ?? (shiftHeld ? .shift : .plain)
            let a = effective(config.action(c, layer), control: c, layer: layer)
            var out: [BridgeOutput] = []
            if case .channel(.select) = a, config.overlapSelects != true {
                let hold = config.multiSelectHoldSeconds ?? 0.35
                for (other, (_, oa)) in held.sorted(by: { $0.key.id < $1.key.id }) where other != c && other.id.hasPrefix("sel.") && now - (heldSince[other] ?? now) < hold {
                    if case .channel(.select) = oa { out += perform(oa, control: other, down: false); held[other] = nil }     // let go of the previous one first: the new track replaces the selection
                }
            }
            held[c] = (layer, a); heldSince[c] = now
            return out + perform(a, control: c, down: true)
        case .up:
            guard let (_, a) = held.removeValue(forKey: c) else { return [] }
            return perform(a, control: c, down: false)
        }
    }

    /// The console often sends a SEL switch a second time in the same millisecond as the next press: the switch that was pressed before (or the same one
    /// again). Pro Tools reads two presses on a track as a double click and asks to rename it, so the repeat is dropped.
    private func isEcho(_ c: ConsoleControl, now: TimeInterval) -> Bool {
        if let last = lastSEL, now - last.time < 0.008, c == last.control || c == previousSEL, c != last.control || held[c] != nil { return true }
        if lastSEL?.control != c { previousSEL = lastSEL?.control }
        lastSEL = (c, now)
        return false
    }

    /// SEL switches follow the current layer functions rather than the bindings they start with.
    private func effective(_ a: Action, control c: ConsoleControl, layer: Layer) -> Action {
        if c.id.hasPrefix("sel."), case .channel = a { return .channel(layer == .shift ? shiftLayer : plainLayer) }
        return a
    }

    private func perform(_ a: Action, control c: ConsoleControl, down: Bool) -> [BridgeOutput] {
        switch a {
        case .none: return []
        case .hui(let z, let p): return [.hui(device: 0, bytes: HUI.switchMessage(zone: z, port: p, pressed: down))]
        case .huiPulse(let z, let p):
            guard down else { return [] }
            return [.hui(device: 0, bytes: HUI.switchMessage(zone: z, port: p, pressed: true) + HUI.switchMessage(zone: z, port: p, pressed: false))]
        case .channel(let f):
            guard let n = c.index, n >= 1 else { return [] }
            let device = (n - 1) / 8, zone = UInt8((n - 1) % 8)
            return [.hui(device: device, bytes: HUI.switchMessage(zone: zone, port: UInt8(f.rawValue), pressed: down))]
        case .setLayer(let l, let f):
            guard down else { return [] }
            if isShifted(l) { shiftLayer = f } else { plainLayer = f }
            return layerLEDs()
        case .swapLayers:
            guard down else { return [] }
            swap(&plainLayer, &shiftLayer); layersSwapped.toggle()
            return layerLEDs()
        case .jogToggle:
            guard down else { return [] }
            scrub.toggle()
            return [0x43, 0x21].flatMap { lamp(led($0, on: !scrub), force: true) }
        case .key(let k): return down ? [.key(k)] : []
        }
    }

    private func layerLEDs() -> [BridgeOutput] {
        var out = modeButtons().flatMap { (k, a) in ConsoleMap.ledNote(k.control).map { lamp(led($0, on: isActive(a)), force: true) } ?? [] }
        out += selLEDs(force: true)                                       // the SEL LEDs show the other function now
        return out
    }

    /// The console has two banks of SEL lights and shows the second one by itself while Shift is held: notes 0x01 to 0x18 are the plain bank (the plain
    /// layer's function), notes 0x23 to 0x3A the shifted bank (the shifted layer's function), the codes the SEL switches have with Shift.
    private func selLEDs(force: Bool = false) -> [BridgeOutput] {
        (1...(config.devices * 8)).flatMap { n -> [BridgeOutput] in
            let d = (n - 1) / 8, z = UInt8((n - 1) % 8)
            return lamp(led(UInt8(n), on: huiLEDs[huiKey(d, z, UInt8(plainLayer.rawValue))] ?? false), force: force)
                + lamp(led(UInt8(0x22 + n), on: huiLEDs[huiKey(d, z, UInt8(shiftLayer.rawValue))] ?? false), force: force)
        }
    }

    private func fader(_ n: Int, _ v: UInt8, now: TimeInterval) -> [BridgeOutput] {
        guard n >= 1, n <= config.devices * 8 else { return [] }
        let device = (n - 1) / 8, strip = (n - 1) % 8
        faderSent[n] = nil                                       // the hand moved it: the next position from Pro Tools must go through
        var bytes: [UInt8] = []
        if touching[n] == nil { bytes += HUI.switchMessage(zone: UInt8(strip), port: 0, pressed: true) }
        touching[n] = now + config.touchReleaseSeconds
        return [.hui(device: device, bytes: bytes + HUI.fader(strip: strip, value: v))]
    }

    private func jog(_ pp: UInt8) -> [BridgeOutput] {
        if scrub { return [.hui(device: 0, bytes: HUI.jog(console: pp))] }
        let port: UInt8 = pp >= 63 ? 1 : 2                      // counter-clockwise rewinds, clockwise advances
        return [.hui(device: 0, bytes: HUI.switchMessage(zone: 0x0E, port: port, pressed: true) + HUI.switchMessage(zone: 0x0E, port: port, pressed: false))]
    }

    /// Timers: releases the touch of the faders that have not moved for `touchReleaseSeconds`.
    public func tick(now: TimeInterval) -> [BridgeOutput] {
        var out: [BridgeOutput] = []
        for (n, end) in touching.sorted(by: { $0.key < $1.key }) where now >= end {
            touching[n] = nil
            out.append(.hui(device: (n - 1) / 8, bytes: HUI.switchMessage(zone: UInt8((n - 1) % 8), port: 0, pressed: false)))
        }
        return out
    }

    /// Time of the next timer, for the host to schedule `tick`.
    public var nextTickTime: TimeInterval? { touching.values.min() }

    private func huiKey(_ device: Int, _ zone: UInt8, _ port: UInt8) -> Int { device << 16 | Int(zone) << 8 | Int(port) }

    // MARK: HUI to console

    public func receiveFromHUI(device: Int, _ m: [UInt8]) -> [BridgeOutput] {
        guard device >= 0, device < hostReaders.count else { return [] }
        switch hostReaders[device].read(m) {
        case .ping: return [.hui(device: device, bytes: HUI.ping)]
        case .fader(let strip, let value):
            let n = device * 8 + strip + 1
            if touching[n] != nil { return [] }                 // the hand is on that fader: it leads
            if faderSent[n] == value { return [] }
            faderSent[n] = value
            return [.console(bytes: [0xB0, UInt8(n), value])]
        case .led(let zone, let port, let on):
            huiLEDs[huiKey(device, zone, port)] = on
            if zone < 8 {
                let n = device * 8 + Int(zone) + 1
                var out: [BridgeOutput] = []
                if port == UInt8(plainLayer.rawValue) { out += lamp(led(UInt8(n), on: on)) }
                if port == UInt8(shiftLayer.rawValue) { out += lamp(led(UInt8(0x22 + n), on: on)) }
                return out
            }
            return deviceLED(zone: zone, port: port, on: on)
        default: return []
        }
    }

    /// LEDs of the console that follow HUI lights: transport through controllers of channel 2, the zoom mode light on note 0x72 (the Bome project's).
    private func deviceLED(zone: UInt8, port: UInt8, on: Bool) -> [BridgeOutput] {
        switch (zone, port) {
        case (0x0E, 3): return lamp([0xB1, 0x77, on ? 0x7F : 0x00])
        case (0x0E, 4): return lamp([0xB1, 0x78, on ? 0x7F : 0x00])
        case (0x0E, 5): return lamp([0xB1, 0x79, on ? 0x7F : 0x00])
        case (0x0D, 2): return lamp(led(0x72, on: on))
        default: return []
        }
    }
}
