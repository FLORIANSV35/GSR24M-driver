import Foundation
import Testing
@testable import GSRCore

@Suite struct DevReportTests {
    private func fake(_ list: String, calls: ThreadSafeBox) -> DevReport.Runner {
        { tool, args, _ in
            calls.add(tool.split(separator: "/").last.map(String.init)! + " " + args.joined(separator: " "))
            if tool == "/fake/dicedump" { return args.first == "-l" ? list : "DUMP of \(args.last ?? "")\nhome is /Users/jane/Documents" }
            return "output of \(args.joined(separator: " "))"
        }
    }
    private let list = """
        GUID 0x0004C4AAAA000001  vendor 'Allen & Heath'  product 'GS-R24'  Vendor_ID 0x0004C4  allen_heath=1
        GUID 0x0004C4AAAA000002  vendor 'Allen & Heath'  product 'ZED-R16'  Vendor_ID 0x0004C4  allen_heath=1
        GUID 0x000A27BBBB000003  vendor 'Apple'  product 'iSight'  Vendor_ID 0x000A27  allen_heath=0
        """

    @Test func redactionRemovesTheUserTheHomeAndTheComputer() {
        let t = DevReport.redact("/Users/jane/Library/x and jane and Janes-MacBook and ab", home: "/Users/jane", user: "jane", computer: "Janes-MacBook")
        #expect(t == "~/Library/x and <redacted> and <redacted> and ab")
        #expect(DevReport.redact("keep it", home: "/", user: "ab", computer: "") == "keep it")
    }

    @Test func archiveNameHasTheDate() {
        let n = DevReport.archiveName(date: Date(timeIntervalSince1970: 0))
        #expect(n.hasPrefix("GSR24M-report-19700101-") && n.hasSuffix(".zip"))
    }

    @Test func issuePageCarriesWhatTheUserTicked() throws {
        let u = try #require(DevReport.issueURL(DevReport.Context(zedR16: true, intelMac: true)))
        let s = u.absoluteString
        #expect(s.hasPrefix("https://github.com/FLORIANSV35/GSR24M-driver/issues/new?"))
        #expect(s.contains("ZED-R16") && s.contains("Intel%20Mac"))
        #expect(DevReport.Context().titles.isEmpty)
    }

    @Test func listedDevicesAreRecognised() {
        let d = DevReport.listedDevices(list)
        #expect(d.count == 3 && d[0].interesting && d[1].interesting && !d[2].interesting)
    }

    @Test func onlyUnitsTheDaemonDoesNotHoldAreReadAndNothingIsWrittenBack() {
        let calls = ThreadSafeBox()
        var s = DevReport.AppState(); s.appVersion = "0.4.1_DEV"; s.dicedump = "/fake/dicedump"; s.daemonInstalled = true; s.daemonAnswers = true
        s.ownedGUID = 0x0004C4AAAA000001; s.daemon = "daemon text"; s.agent = "agent text"; s.settings = "{}"; s.midiPorts = "ports"
        let files = DevReport.files(context: .init(zedR16: true, notes: "ZED on the second port"), state: s, runner: fake(list, calls: calls), readFile: { $0 == "/tmp/gsr24m-midiagent.log" ? "a\nb" : nil })
        let names = files.map { $0.name }
        #expect(names.first == "README.txt")
        for n in ["context.txt", "system.txt", "firewire-ioreg.txt", "firewire-profiler.txt", "audio-profiler.txt", "dicedump-list.txt", "daemon.txt", "agent.txt", "midi-ports.txt", "logs/gsrd.log", "logs/midiagent.log", "logs/install.log"] { #expect(names.contains(n), "\(n)") }
        let text = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.text) })
        #expect(text["dicedump-0x0004C4AAAA000001.txt"]?.contains("Held open by the gsrd daemon") == true)
        #expect(text["dicedump-0x0004C4AAAA000002.txt"]?.hasPrefix("DUMP of 0x0004C4AAAA000002") == true, "the ZED, not held by the daemon, is dumped")
        #expect(text["dicedump-0x000A27BBBB000003.txt"] == nil, "a camera is not dumped")
        #expect(text["context.txt"]?.contains("ZED-R16") == true && text["context.txt"]?.contains("ZED on the second port") == true)
        #expect(text["logs/midiagent.log"] == "a\nb" && text["logs/gsrd.log"] == "(not present)")
        let c = calls.items
        #expect(c.contains("dicedump -g 0x0004C4AAAA000002") && !c.contains("dicedump -g 0x0004C4AAAA000001"))
        // only read-only tools: nothing else was run
        let tools = Set(c.map { String($0.split(separator: " ").first!) })
        #expect(tools.isSubset(of: ["sw_vers", "uname", "sysctl", "ioreg", "system_profiler", "dicedump"]), "\(tools)")
    }

    @Test func aDaemonThatDoesNotAnswerMeansNoDirectRead() {
        let calls = ThreadSafeBox()
        var s = DevReport.AppState(); s.dicedump = "/fake/dicedump"; s.daemonInstalled = true; s.daemonAnswers = false
        let files = DevReport.files(context: .init(), state: s, runner: fake(list, calls: calls), readFile: { _ in nil })
        #expect(!calls.items.contains { $0.hasPrefix("dicedump -g") })
        #expect(files.first { $0.name.hasPrefix("dicedump-0x0004C4AAAA000002") }?.text.contains("does not answer") == true)
    }

    @Test func theZipHoldsTheRedactedFiles() throws {
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("GSR24M-report-test-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zip) }
        try DevReport.write([("README.txt", "hello /Users/jane/x"), ("logs/a.log", "line jane")], to: zip, home: "/Users/jane", user: "jane", computer: "")
        #expect((try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int ?? 0) ?? 0 > 100)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("unzip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-x", "-k", zip.path, out.path]; try p.run(); p.waitUntilExit()
        let root = out.appendingPathComponent(zip.deletingPathExtension().lastPathComponent)
        #expect(try String(contentsOf: root.appendingPathComponent("README.txt")) == "hello ~/x")
        #expect(try String(contentsOf: root.appendingPathComponent("logs/a.log")) == "line <redacted>")
    }

    @Test func theRealRunnerStopsALongToolAndSaysWhenAToolIsMissing() {
        #expect(DevReport.run("/bin/echo", ["hi"], 5).trimmingCharacters(in: .whitespacesAndNewlines) == "hi")
        #expect(DevReport.run("/nonexistent/tool", [], 1).contains("not available"))
        let t0 = Date(); let r = DevReport.run("/bin/sleep", ["5"], 0.3)
        #expect(r.contains("stopped after") && Date().timeIntervalSince(t0) < 3)
    }
}

final class ThreadSafeBox: @unchecked Sendable {
    private let lock = NSLock(); private var a: [String] = []
    func add(_ s: String) { lock.lock(); a.append(s); lock.unlock() }
    var items: [String] { lock.lock(); defer { lock.unlock() }; return a }
}
