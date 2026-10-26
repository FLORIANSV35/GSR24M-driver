import Foundation

/// A version number "major.minor.patch" (a leading "v" and any "-suffix" are ignored).
public struct SemVer: Comparable, Equatable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int
    public init(_ major: Int, _ minor: Int, _ patch: Int) { self.major = major; self.minor = minor; self.patch = patch }
    public init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        if let dash = t.firstIndex(of: "-") { t = String(t[..<dash]) }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.init(parts[0]!, parts.count > 1 ? parts[1]! : 0, parts.count > 2 ? parts[2]! : 0)
    }
    public static func < (a: SemVer, b: SemVer) -> Bool { (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
    public var description: String { "\(major).\(minor).\(patch)" }
}

/// What the app needs from the "latest release" answer of the GitHub API.
public struct ReleaseInfo: Equatable {
    public var version: SemVer
    public var tag: String
    public var pageURL: URL
    public var notes: String
    public var installerURL: URL?
    public var checksumURL: URL?

    /// Repository that publishes the releases.
    public static let repository = "FLORIANSV35/GSR24M-driver"
    public static var latestEndpoint: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }

    /// Parses the JSON of `GET /repos/{owner}/{repo}/releases/latest`. Drafts and pre-releases are refused.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["draft"] as? Bool) != true, (o["prerelease"] as? Bool) != true,
              let tag = o["tag_name"] as? String, let v = SemVer(tag),
              let page = (o["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = (o["assets"] as? [[String: Any]]) ?? []
        func asset(_ suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
        }
        return ReleaseInfo(version: v, tag: tag, pageURL: page, notes: (o["body"] as? String) ?? "",
                           installerURL: asset(".pkg"), checksumURL: asset(".pkg.sha256"))
    }

    public func isNewer(than current: String) -> Bool {
        guard let c = SemVer(current) else { return false }
        return version > c
    }

    /// The checksum file holds "<64 hex digits>  <file name>"; returns the digits, lower case.
    public static func checksum(from text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first else { return nil }
        let s = first.lowercased()
        return s.count == 64 && s.allSatisfy({ $0.isHexDigit }) ? s : nil
    }
}
