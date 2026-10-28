import Foundation

/// Restarts the pieces of the driver from the application: the MIDI agent (a LaunchAgent of the user), the daemon gsrd (a LaunchDaemon, root) and
/// the audio plug-in (it lives in coreaudiod, root). The last two ask for the administrator password.
enum Services {
    enum Piece: String, CaseIterable {
        case agent = "MIDI agent", daemon = "gsrd daemon", plugin = "Audio driver"
        var detail: String {
            switch self {
            case .agent: return "the MIDI link of the console"
            case .daemon: return "the FireWire link to the card (audio and MIDI stop for a few seconds)"
            case .plugin: return "the GS-R24M device in macOS (restarts CoreAudio: all audio stops for a moment)"
            }
        }
        fileprivate var command: String {
            switch self {
            case .agent: return "launchctl kickstart -k gui/\(getuid())/com.gsr24m.midiagent"
            case .daemon: return "launchctl kickstart -k system/com.gsr24m.gsrd"
            case .plugin: return "killall coreaudiod"
            }
        }
        fileprivate var asksPassword: Bool { self != .agent }
    }

    /// Runs on a background queue; `done(nil)` when it worked, else the reason.
    static func restart(_ piece: Piece, done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(), err = Pipe()
            if piece.asksPassword {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", "do shell script \"\(piece.command)\" with administrator privileges"]
            } else {
                p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", piece.command]
            }
            p.standardError = err; p.standardOutput = Pipe()
            var result: String?
            do {
                try p.run(); p.waitUntilExit()
                if p.terminationStatus != 0 {
                    let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    result = text.contains("User canceled") ? "Cancelled." : (text.isEmpty ? "Failed (code \(p.terminationStatus))." : text)
                }
            } catch { result = "Could not run: \(error)" }
            DispatchQueue.main.async { done(result) }
        }
    }
}
