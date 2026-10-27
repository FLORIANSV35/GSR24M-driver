import Foundation

/// What the "Learn" button finds when the user presses a control on the console.
public enum LearnOutcome: Equatable {
    case known(ConsoleControl, Layer?)
    case unknown(ConsoleMap.Pattern)
    case ignored                                       // a release, a clock byte, anything that is not a press or a movement
}

extension ConsoleMap {
    public func learn(_ message: [UInt8]) -> LearnOutcome {
        guard let (p, e) = Self.pattern(of: message) else { return .ignored }
        if e == .up { return .ignored }
        if let hit = table[p] { return .known(hit.control, hit.layer) }
        return .unknown(p)
    }

    /// Human readable description of a pattern, e.g. "note 0x23 on channel 1".
    public static func describe(_ p: Pattern) -> String {
        switch p {
        case .note(let ch, let n): return String(format: "note 0x%02X, channel %d", n, Int(ch) + 1)
        case .controller(let ch, let n): return String(format: "controller 0x%02X, channel %d", n, Int(ch) + 1)
        case .mmc(let c): return String(format: "MMC command 0x%02X", c)
        }
    }

    /// The patterns that stand for a control, with their layer.
    public func codes(of c: ConsoleControl) -> [(Pattern, Layer?)] {
        table.filter { $0.value.control == c }.map { ($0.key, $0.value.layer) }
            .sorted { Self.describe($0.0) < Self.describe($1.0) }
    }
}

public enum ActionKind: String, CaseIterable, Identifiable {
    case none, hui, channel, setLayer, swapLayers, jogToggle, key
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "Nothing"
        case .hui: return "HUI switch"
        case .channel: return "Channel function"
        case .setLayer: return "Choose what SEL BANK 2 does"
        case .swapLayers: return "SEL REV (swap SEL BANK 1 and 2)"
        case .jogToggle: return "Jogwheel: steps or scrub"
        case .key: return "Keyboard shortcut"
        }
    }
}

extension Action {
    public var kind: ActionKind {
        switch self {
        case .none: return .none
        case .hui, .huiPulse: return .hui
        case .channel: return .channel
        case .setLayer: return .setLayer
        case .swapLayers: return .swapLayers
        case .jogToggle: return .jogToggle
        case .key: return .key
        }
    }

    /// A sensible starting action when the user picks a kind in the editor.
    public static func starting(_ k: ActionKind) -> Action {
        switch k {
        case .none: return .none
        case .hui: return .hui(zone: 0x0E, port: 4)
        case .channel: return .channel(.select)
        case .setLayer: return .setLayer(.shift, .solo)
        case .swapLayers: return .swapLayers
        case .jogToggle: return .jogToggle
        case .key: return .key(KeyShortcut(key: "f"))
        }
    }

    /// Kinds that make sense for a control.
    public static func kinds(for c: ConsoleControl) -> [ActionKind] {
        if c.id.hasPrefix("sel.") { return [.none, .channel, .hui, .key] }
        return [.none, .hui, .setLayer, .swapLayers, .jogToggle, .key]
    }

    /// One line for the surface and the inspector.
    public var summary: String {
        switch self {
        case .none: return "nothing"
        case .hui(let z, let p), .huiPulse(let z, let p): return HUICatalog.title(of: HUISwitch(zone: z, port: p)) ?? String(format: "HUI zone 0x%02X port %d", z, p)
        case .channel(let f): return f.title
        case .setLayer(let l, let f): return "SEL BANK \(l == .shift ? 2 : 1) = \(f.title)"
        case .swapLayers: return "SEL REV"
        case .jogToggle: return "jog steps / scrub"
        case .key(let k): return (ProToolsKeys.title(of: k).map { $0 + ": " } ?? "") + "key " + (k.command ? "⌘" : "") + (k.control ? "⌃" : "") + (k.option ? "⌥" : "") + (k.shift ? "⇧" : "") + k.key.uppercased()
        }
    }
}
