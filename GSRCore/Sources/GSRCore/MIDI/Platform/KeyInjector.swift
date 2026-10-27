import ApplicationServices
import CoreGraphics
import Foundation

/// Keyboard shortcuts on the computer for the controls bound to `Action.key`. macOS only lets a program post key events if it has been
/// allowed in System Settings, Privacy and Security, Accessibility.
public enum KeyInjector {
    /// Virtual key codes of an ANSI keyboard.
    public static let codes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
            ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        for (i, c) in [(1, 122), (2, 120), (3, 99), (4, 118), (5, 96), (6, 97), (7, 98), (8, 100), (9, 101), (10, 109), (11, 103), (12, 111)] { m["f\(i)"] = CGKeyCode(c) }
        return m
    }()

    public static func keyCode(_ name: String) -> CGKeyCode? { codes[name.lowercased()] }

    public static func flags(of k: KeyShortcut) -> CGEventFlags {
        var f: CGEventFlags = []
        if k.shift { f.insert(.maskShift) }
        if k.control { f.insert(.maskControl) }
        if k.option { f.insert(.maskAlternate) }
        if k.command { f.insert(.maskCommand) }
        return f
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show the permission request (once), returns the current state.
    @discardableResult
    public static func askForPermission() -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Returns false when the key is unknown or the permission is missing.
    @discardableResult
    public static func press(_ k: KeyShortcut) -> Bool {
        guard let code = keyCode(k.key), isTrusted else { return false }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return false }
            e.flags = flags(of: k)
            e.post(tap: .cghidEventTap)
        }
        return true
    }
}
