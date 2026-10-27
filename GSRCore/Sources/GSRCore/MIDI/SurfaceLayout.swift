import Foundation

extension ConsoleControl {
    /// Name shown to the user.
    public var title: String {
        let n = index.map(String.init) ?? ""
        switch id {
        case _ where id.hasPrefix("sel."): return "SEL \(n)"
        case _ where id.hasPrefix("st."): return "ST\(n)"
        case _ where id.hasPrefix("fader."): return "Fader \(n)"
        case _ where id.hasPrefix("button."): return "Button \(n)"
        case _ where id.hasPrefix("pot."): return "Rotary \(n)"
        case _ where id.hasPrefix("midifader."): return "MIDI fader \(n)"
        case "shift": return "Shift"
        case "arrow.up": return "Keypad up"
        case "arrow.down": return "Keypad down"
        case "arrow.left": return "Keypad left"
        case "arrow.right": return "Keypad right"
        case "arrow.centre": return "Keypad centre"
        case "transport.gts": return "GTS (go to start)"
        case "transport.stop": return "Stop"
        case "transport.play": return "Play"
        case "transport.gte": return "GTE (go to end)"
        case "transport.rec": return "Record"
        case "jog.switch": return "Jogwheel switch"
        case "jog.wheel": return "Jogwheel"
        default: return id
        }
    }

    /// Controls that have a binding the user can choose. The others have a fixed role (faders, jogwheel) or are not used in Pro Tools mode.
    public var isBindable: Bool {
        !(isFader || id == "jog.wheel" || id.hasPrefix("midifader.") || id.hasPrefix("pot.") || id == "shift")
    }
}

public struct SurfaceCell: Identifiable, Hashable {
    public enum Shape { case button, strip, pot, wheel }
    public let control: ConsoleControl
    public let label: String
    public let shape: Shape
    public let x: Double, y: Double, w: Double, h: Double
    public var id: ConsoleControl { control }
}

/// The MIDI section of the console as drawn in the user guide (p.31), in grid units, in two blocks: the channel strips and the control section.
public enum SurfaceLayout {
    public static let stripsSize = (width: 26.3, height: 4.1)
    public static let controlsSize = (width: 9.9, height: 7.5)

    public static let strips: [SurfaceCell] = {
        var c: [SurfaceCell] = []
        for n in 1...24 {
            let x = Double(n - 1)
            c.append(SurfaceCell(control: .sel(n), label: "\(n)", shape: .button, x: x + 0.05, y: 0, w: 0.9, h: 0.6))
            c.append(SurfaceCell(control: .fader(n), label: "", shape: .strip, x: x + 0.3, y: 0.9, w: 0.4, h: 3.1))
        }
        c.append(SurfaceCell(control: .st(1), label: "ST1", shape: .button, x: 24.4, y: 0, w: 0.9, h: 0.6))
        c.append(SurfaceCell(control: .st(2), label: "ST2", shape: .button, x: 25.4, y: 0, w: 0.9, h: 0.6))
        return c
    }()

    public static let controls: [SurfaceCell] = {
        var c: [SurfaceCell] = []
        // left: two MIDI faders and twelve rotary controls
        c.append(SurfaceCell(control: .midiFader(1), label: "", shape: .strip, x: 0.3, y: 0, w: 0.5, h: 3.0))
        c.append(SurfaceCell(control: .midiFader(2), label: "", shape: .strip, x: 1.7, y: 0, w: 0.5, h: 3.0))
        for n in 1...12 {
            let col = Double((n - 1) / 6), row = Double((n - 1) % 6)
            c.append(SurfaceCell(control: .pot(n), label: "\(n)", shape: .pot, x: 0.1 + col * 1.4, y: 3.3 + row * 0.7, w: 0.65, h: 0.65))
        }
        // right: transport row, shift, eight buttons, keypad, jogwheel
        let ox = 3.0
        for (i, (ctl, name)) in [(ConsoleControl.gts, "GTS"), (.stop, "STOP"), (.play, "PLAY"), (.gte, "GTE"), (.rec, "REC")].enumerated() {
            c.append(SurfaceCell(control: ctl, label: name, shape: .button, x: ox + Double(i) * 1.15, y: 0, w: 1.05, h: 0.75))
        }
        c.append(SurfaceCell(control: .shift, label: "SHIFT", shape: .button, x: ox, y: 1.0, w: 1.05, h: 0.6))
        for n in 1...8 {
            let col = Double((n - 1) % 2), row = Double((n - 1) / 2)
            c.append(SurfaceCell(control: .button(n), label: "\(n)", shape: .button, x: ox + 1.4 + col * 1.15, y: 1.0 + row * 0.75, w: 1.05, h: 0.65))
        }
        for (ctl, name, dx, dy) in [(ConsoleControl.arrowUp, "▲", 1.1, 4.1), (.arrowLeft, "◀", 0.15, 4.95), (.arrowCentre, "●", 1.1, 4.95), (.arrowRight, "▶", 2.05, 4.95), (.arrowDown, "▼", 1.1, 5.8)] {
            c.append(SurfaceCell(control: ctl, label: name, shape: .button, x: ox + dx, y: dy, w: 0.85, h: 0.75))
        }
        c.append(SurfaceCell(control: .jogWheel, label: "JOG", shape: .wheel, x: ox + 3.7, y: 3.6, w: 2.9, h: 2.9))
        c.append(SurfaceCell(control: .jogSwitch, label: "JOG SW", shape: .button, x: ox + 4.4, y: 6.7, w: 1.5, h: 0.6))
        return c
    }()

    public static var all: [SurfaceCell] { strips + controls }
}
