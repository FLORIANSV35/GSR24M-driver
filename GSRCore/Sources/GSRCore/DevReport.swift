import Foundation

/// The report a user can send to help the development: what the Mac is, what is on the FireWire bus, what the card or the console answers when it is only read, the state of
/// the daemon and the MIDI agent. Everything here is READ ONLY and nothing leaves the Mac by itself: the report is a zip the user saves, looks at, and attaches to a message.
public enum DevReport {
    public struct Context: Equatable {
        public var zedR16 = false, twoConsoles = false, intelMac = false
        public var notes = ""
        public init(zedR16: Bool = false, twoConsoles: Bool = false, intelMac: Bool = false, notes: String = "") {
            self.zedR16 = zedR16; self.twoConsoles = twoConsoles; self.intelMac = intelMac; self.notes = notes
        }
        public var titles: [String] { [zedR16 ? "ZED-R16" : nil, twoConsoles ? "two chained consoles" : nil, intelMac ? "Intel Mac" : nil].compactMap { $0 } }
    }

    /// Runs a read-only tool and returns what it printed (standard output and error), or a one-line reason. Replaced in the tests.
    public typealias Runner = (_ tool: String, _ args: [String], _ timeout: TimeInterval) -> String

    /// What the app knows by itself and hands over (text, already formatted).
    public struct AppState {
        public var appVersion = "", daemon = "", agent = "", settings = "", midiPorts = ""
        public var ownedGUID: UInt64?                    // the card the daemon holds open: it is NOT read again directly
        public var daemonInstalled = false, daemonAnswers = false
        public var dicedump: String?                     // path of the read-only dump tool
        public init() {}
    }

    // MARK: pieces

    /// Takes the user's name, the home folder and the computer's name out of a text.
    public static func redact(_ text: String, home: String, user: String, computer: String = "") -> String {
        var t = text
        if !home.isEmpty, home != "/" { t = t.replacingOccurrences(of: home, with: "~") }
        for word in [user, computer] where word.count >= 3 { t = t.replacingOccurrences(of: word, with: "<redacted>") }
        return t
    }

    public static func archiveName(date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"; f.locale = Locale(identifier: "en_US_POSIX")
        return "GSR24M-report-" + f.string(from: date) + ".zip"
    }

    /// A page to open on GitHub with a short text to fill in (the user attaches the zip himself).
    public static func issueURL(_ c: Context, repository: String = "FLORIANSV35/GSR24M-driver") -> URL? {
        var q = URLComponents(string: "https://github.com/\(repository)/issues/new")
        let what = c.titles.isEmpty ? "report" : c.titles.joined(separator: ", ")
        let body = "I use: \(what)\n\nWhat I did and what happened:\n\n\n(Attach the GSR24M-report zip here. It holds my device identifiers: please look at it first.)"
        q?.queryItems = [URLQueryItem(name: "title", value: "Test report: " + what), URLQueryItem(name: "body", value: body)]
        return q?.url
    }

    /// The devices `dicedump -l` lists: GUID and whether it looks like an Allen & Heath or DICE unit.
    public static func listedDevices(_ list: String) -> [(guid: String, interesting: Bool)] {
        list.split(separator: "\n").compactMap { l in
            guard l.hasPrefix("GUID "), let g = l.split(separator: " ").dropFirst().first else { return nil }
            let low = l.lowercased()
            return (String(g), l.contains("allen_heath=1") || low.contains("zed") || low.contains("gs-r24") || low.contains("tcat") || low.contains("dice"))
        }
    }

    // MARK: the files

    /// The report's files, in order. `runner` runs the read-only system tools, `readFile` reads a log (nil if absent).
    public static func files(context c: Context, state s: AppState, runner: Runner, readFile: (String) -> String?, date: Date = Date()) -> [(name: String, text: String)] {
        var out: [(String, String)] = []
        let stamp = ISO8601DateFormatter().string(from: date)
        out.append(("context.txt", """
            GSR24M report, \(stamp)
            Application: \(s.appVersion)
            The user says he uses: \(c.titles.isEmpty ? "(nothing ticked)" : c.titles.joined(separator: ", "))
            Notes: \(c.notes.isEmpty ? "(none)" : c.notes)
            gsrd daemon installed: \(s.daemonInstalled), answering: \(s.daemonAnswers)
            """))
        var sys = ""
        for (title, tool, args) in [("sw_vers", "/usr/bin/sw_vers", []), ("machine", "/usr/bin/uname", ["-m"]), ("model", "/usr/sbin/sysctl", ["-n", "hw.model"]),
                                    ("processor", "/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]), ("Apple silicon (1 = yes)", "/usr/sbin/sysctl", ["-n", "hw.optional.arm64"]),
                                    ("running under Rosetta (1 = yes)", "/usr/sbin/sysctl", ["-n", "sysctl.proc_translated"]), ("memory", "/usr/sbin/sysctl", ["-n", "hw.memsize"])] as [(String, String, [String])] {
            sys += "## \(title)\n" + runner(tool, args, 5).trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        out.append(("system.txt", sys))
        out.append(("firewire-ioreg.txt", ["IOFireWireDevice", "IOFireWireUnit", "IOFireWireLocalNode"].map { cls in
            "## ioreg -c \(cls)\n" + runner("/usr/sbin/ioreg", ["-r", "-c", cls, "-l", "-w0"], 20)
        }.joined(separator: "\n")))
        out.append(("firewire-profiler.txt", runner("/usr/sbin/system_profiler", ["SPFireWireDataType", "SPThunderboltDataType"], 40)))
        out.append(("audio-profiler.txt", runner("/usr/sbin/system_profiler", ["SPAudioDataType"], 40)))
        // the read-only dump of every DICE unit that the daemon does not hold open
        if let tool = s.dicedump {
            let list = runner(tool, ["-l"], 20)
            out.append(("dicedump-list.txt", list.isEmpty ? "(no FireWire device listed)" : list))
            for d in listedDevices(list) where d.interesting {
                let g = UInt64(d.guid.dropFirst(2), radix: 16)
                if let owned = s.ownedGUID, owned == g { out.append(("dicedump-\(d.guid).txt", "Held open by the gsrd daemon: its own view is in daemon.txt, the card is not read a second time.")); continue }
                if s.daemonInstalled && !s.daemonAnswers { out.append(("dicedump-\(d.guid).txt", "The daemon is installed but does not answer: the unit was not read, so as not to disturb a card it may hold.")); continue }
                out.append(("dicedump-\(d.guid).txt", runner(tool, ["-g", d.guid], 30)))
            }
        }
        out.append(("daemon.txt", s.daemon.isEmpty ? "(daemon not reachable)" : s.daemon))
        out.append(("agent.txt", (s.agent.isEmpty ? "(MIDI agent not reachable)" : s.agent) + "\n\n## settings\n" + s.settings))
        out.append(("midi-ports.txt", s.midiPorts))
        for (name, path) in [("gsrd.log", "/var/log/gsrd.log"), ("midiagent.log", "/tmp/gsr24m-midiagent.log"), ("install.log", "/var/log/gsr24m-install.log")] {
            out.append(("logs/" + name, readFile(path).map { String($0.split(separator: "\n", omittingEmptySubsequences: false).suffix(300).joined(separator: "\n")) } ?? "(not present)"))
        }
        out.insert(("README.txt", """
            This folder was written by the Dev tab of the GSR24M application. Nothing in it was sent anywhere: you decide whether to share it.
            It only READS: system information, the list of FireWire devices, a read-only dump of the DICE units the daemon does not hold, the state of the daemon and of the MIDI
            agent, and the last lines of their logs. Your user name, your home folder and your computer's name were replaced by <redacted> or ~.
            It does hold the identifiers of your FireWire devices (GUID, serial numbers, nicknames). Look at the files before you send them.
            Files: \(out.map { $0.0 }.joined(separator: ", "))
            """), at: 0)
        return out
    }

    /// Redacts every file and writes the zip (with ditto, which every Mac has). Returns the zip's URL.
    public static func write(_ files: [(name: String, text: String)], to zip: URL, home: String = NSHomeDirectory(), user: String = NSUserName(), computer: String = Host.current().localizedName ?? "") throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("gsr24m-report-" + UUID().uuidString, isDirectory: true)
        let root = dir.appendingPathComponent(zip.deletingPathExtension().lastPathComponent, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for f in files {
            let url = root.appendingPathComponent(f.name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try redact(f.text, home: home, user: user, computer: computer).write(to: url, atomically: true, encoding: .utf8)
        }
        try? fm.removeItem(at: zip)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-c", "-k", "--keepParent", root.path, zip.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, fm.fileExists(atPath: zip.path) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The real runner: runs the tool, stops it after the timeout, returns what it printed.
    public static func run(_ tool: String, _ args: [String], _ timeout: TimeInterval) -> String {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return "(\(tool) is not available)" }
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        var data = Data(); let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; lock.lock(); data.append(d); lock.unlock() }
        do { try p.run() } catch { return "(could not run \(tool): \(error.localizedDescription))" }
        let end = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); lock.lock(); let s = String(decoding: data, as: UTF8.self); lock.unlock(); return s + "\n(stopped after \(Int(timeout)) s)" }
        Thread.sleep(forTimeInterval: 0.1); pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
