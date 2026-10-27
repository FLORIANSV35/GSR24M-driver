import Foundation
import AppKit
import CryptoKit
import GSRCore

/// Looks for a newer release of this project on GitHub, downloads its installer and opens it.
/// The installer (a normal macOS .pkg) replaces the app, the daemon and the audio plug-in and asks for the administrator password itself.
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(version: String)
        case downloading, opened, restarting
        case failed(String)
    }
    @Published private(set) var state = State.idle
    private var release: ReleaseInfo?
    private var watcher: Task<Void, Never>?
    /// Where the installer puts the application.
    static let installedApp = URL(fileURLWithPath: "/Applications/GSR24M.app")

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    private let lastCheckKey = "lastUpdateCheck"

    /// Once a day at launch; `manual` checks at once and reports "up to date".
    func check(manual: Bool = false) {
        if !manual, let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        guard state != .checking, state != .downloading else { return }
        state = .checking
        Task {
            var req = URLRequest(url: ReleaseInfo.latestEndpoint, timeoutInterval: 15)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("GSR24M-app/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                UserDefaults.standard.set(Date(), forKey: lastCheckKey)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 { state = manual ? .upToDate : .idle; return }          // no release published yet
                guard code == 200, let r = ReleaseInfo.parse(data) else { state = manual ? .failed("unreadable answer from GitHub") : .idle; return }
                if r.isNewer(than: Self.currentVersion) { release = r; state = .available(version: r.version.description) }
                else { state = manual ? .upToDate : .idle }
            } catch {
                state = manual ? .failed("no answer from GitHub") : .idle
            }
        }
    }

    /// Downloads the installer, checks its SHA-256 against the checksum file of the release, then opens it.
    func install() {
        guard let r = release, let pkg = r.installerURL else { state = .failed("no installer in this version"); return }
        state = .downloading
        Task {
            do {
                let (tmp, _) = try await URLSession.shared.download(from: pkg)
                if let sumURL = r.checksumURL {
                    let (sd, _) = try await URLSession.shared.data(from: sumURL)
                    guard let want = ReleaseInfo.checksum(from: String(decoding: sd, as: UTF8.self)) else { state = .failed("unreadable checksum"); return }
                    let got = SHA256.hash(data: try Data(contentsOf: tmp)).map { String(format: "%02x", $0) }.joined()
                    guard got == want else { state = .failed("corrupted download (checksum differs)"); return }
                }
                let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(pkg.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                NSWorkspace.shared.open(dest)
                state = .opened
                watchInstall()
            } catch {
                state = .failed("download failed")
            }
        }
    }

    /// The installer replaces the application on disk while this copy keeps running. When the installed version is newer than the running one, the
    /// application is started again from the installed copy and this one quits. Looks every 2 s, up to 20 minutes (the user may take a while to
    /// type the password).
    private func watchInstall() {
        watcher?.cancel()
        watcher = Task {
            for _ in 0..<600 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                guard let v = Self.installedVersion(), let installed = SemVer(v), let running = SemVer(Self.currentVersion), installed > running else { continue }
                state = .restarting
                try? await Task.sleep(nanoseconds: 2_500_000_000)             // the installer is still finishing (daemon, plug-in)
                Self.relaunch()
                return
            }
        }
    }

    static func installedVersion() -> String? {
        let plist = installedApp.appendingPathComponent("Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: plist) else { return nil }
        return d["CFBundleShortVersionString"] as? String
    }

    /// Starts the installed application in a moment, then quits this one.
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(installedApp.path)\" --args --after-update"]
        try? p.run()
        NSApplication.shared.terminate(nil)
    }

    var releasePage: URL? { release?.pageURL }
}
