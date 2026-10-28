import Foundation

/// EQ curve of one console channel: level in dB for each frequency of `EQMeasure.grid`.
public struct EQCurve: Codable, Equatable {
    public var freq: [Double]
    public var db: [Double]
    public init(freq: [Double], db: [Double]) { self.freq = freq; self.db = db }
}

/// How close a live curve is to a stored target.
public struct EQAccuracy: Equatable {
    public struct Band: Equatable { public var name: String; public var maxDeviation: Double }
    /// Half the average score of the points and half the score of the worst point (a point inside the tolerance scores 1, falling to 0 at ten
    /// times the tolerance): 100 only when every point is within the tolerance, and a narrow error in one band still shows.
    public var percent: Double
    public var maxDeviation: Double   // dB, signed value of the largest deviation (live minus target)
    public var rmsDeviation: Double
    public var bands: [Band]          // signed largest deviation in each band
}

/// Measurement of an EQ with periodic pink noise: the noise has the period of one DFT frame, so the
/// transfer magnitude comes out without leakage whatever the delay of the path, and complex averaging
/// over periods lowers the noise. The test signal is played into the return of a channel (A+B pressed:
/// return before the insert, send after the EQ) and the send of the same channel is recorded.
public enum EQMeasure {
    public static let period = 65536
    public static let bands: [(name: String, lo: Double, hi: Double)] = [("LF", 20, 150), ("LMF", 150, 1500), ("HMF", 1500, 8000), ("HF", 8000, 20000)]

    /// 20 Hz to 20 kHz in twelfths of an octave.
    public static let grid: [Double] = (0...120).map { 20.0 * pow(2.0, Double($0) / 12.0) }.filter { $0 <= 20000 }

    // MARK: FFT (radix 2)

    static func fft(_ re: inout [Double], _ im: inout [Double], inverse: Bool = false) {
        let n = re.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let ang = 2 * Double.pi / Double(len) * (inverse ? 1 : -1)
            let wr = cos(ang), wi = sin(ang)
            var i = 0
            while i < n {
                var cr = 1.0, ci = 0.0
                for k in 0..<len / 2 {
                    let a = i + k, b = i + k + len / 2
                    let xr = re[b] * cr - im[b] * ci, xi = re[b] * ci + im[b] * cr
                    re[b] = re[a] - xr; im[b] = im[a] - xi; re[a] += xr; im[a] += xi
                    let t = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = t
                }
                i += len
            }
            len <<= 1
        }
    }

    // MARK: test signal

    /// One period of pink noise (rms 1): random phases, amplitude 1/sqrt(f) between 10 Hz and 0.45 fs. Same seed, same noise.
    public static func pinkPeriod(seed: UInt64, rate: Double, length: Int = period) -> [Float] {
        var re = [Double](repeating: 0, count: length), im = re
        var s = 0x9E3779B97F4A7C15 &* (seed &+ 1) &+ 12345
        func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
        for k in 1..<(length / 2) {
            let f = rate * Double(k) / Double(length)
            if f < 10 || f > 0.45 * rate { continue }
            let ph = 2 * Double.pi * Double(next() >> 11) / 9007199254740992.0
            let a = pow(f, -0.5)
            re[k] = a * cos(ph); im[k] = a * sin(ph); re[length - k] = re[k]; im[length - k] = -im[k]
        }
        fft(&re, &im, inverse: true)
        let rms = (re.reduce(0) { $0 + $1 * $1 } / Double(length)).squareRoot()
        return re.map { Float($0 / rms) }
    }

    // MARK: curve

    /// `recorded` is a continuous recording of the channel's send; `reference` one period of the noise that was played.
    /// Uses the last `maxPeriods` whole periods (at least 1 is needed). Returns nil if the recording is too short.
    public static func curve(recorded: [Float], reference: [Float], rate: Double, maxPeriods: Int = 3) -> EQCurve? {
        let L = reference.count
        let k = min(maxPeriods, recorded.count / L)
        guard k >= 1 else { return nil }
        let start = recorded.count - k * L
        var xr = reference.map(Double.init), xi = [Double](repeating: 0, count: L)
        fft(&xr, &xi)
        let xmax = (0...L / 2).map { (xr[$0] * xr[$0] + xi[$0] * xi[$0]).squareRoot() }.max() ?? 1
        var hr = [Double](repeating: 0, count: L / 2 + 1), hi = hr           // complex average of Y / X over the periods
        for p in 0..<k {
            var yr = (0..<L).map { Double(recorded[start + p * L + $0]) }, yi = [Double](repeating: 0, count: L)
            fft(&yr, &yi)
            for b in 0...L / 2 {
                let den = xr[b] * xr[b] + xi[b] * xi[b]
                if den.squareRoot() < xmax * 1e-4 { continue }
                hr[b] += (yr[b] * xr[b] + yi[b] * xi[b]) / den / Double(k)
                hi[b] += (yi[b] * xr[b] - yr[b] * xi[b]) / den / Double(k)
            }
        }
        var f: [Double] = [], db: [Double] = []
        for fc in grid {
            let lo = fc / pow(2, 1.0 / 24), hiF = fc * pow(2, 1.0 / 24)
            var sum = 0.0, n = 0
            for b in 1...L / 2 {
                let fb = rate * Double(b) / Double(L)
                if fb < lo { continue }
                if fb >= hiF { break }
                if (xr[b] * xr[b] + xi[b] * xi[b]).squareRoot() < xmax * 1e-4 { continue }
                sum += hr[b] * hr[b] + hi[b] * hi[b]; n += 1
            }
            if n > 0 { f.append(fc); db.append(10 * log10(sum / Double(n) + 1e-24)) }
        }
        return EQCurve(freq: f, db: db)
    }

    /// Average of several curves of the same grid (dB averaged in power).
    public static func average(_ curves: [EQCurve]) -> EQCurve? {
        guard let first = curves.first, curves.allSatisfy({ $0.freq == first.freq }) else { return nil }
        let db = first.db.indices.map { i in 10 * log10(curves.reduce(0.0) { $0 + pow(10, $1.db[i] / 10) } / Double(curves.count)) }
        return EQCurve(freq: first.freq, db: db)
    }

    // MARK: accuracy

    public static func accuracy(target: EQCurve, live: EQCurve, tolerance: Double = 0.2) -> EQAccuracy? {
        guard target.freq == live.freq, !target.db.isEmpty else { return nil }
        let d = zip(live.db, target.db).map { $0 - $1 }
        // every twelfth of an octave counts the same; a point inside the tolerance scores 1, then it falls linearly to 0 at ten times the tolerance
        let scores = d.map { dev -> Double in
            let a = abs(dev)
            return a <= tolerance ? 1 : max(0, 1 - (a - tolerance) / (9 * tolerance))
        }
        let maxDev = d.max { abs($0) < abs($1) } ?? 0
        let rms = (d.reduce(0) { $0 + $1 * $1 } / Double(d.count)).squareRoot()
        let bandInfo = bands.map { b -> EQAccuracy.Band in
            let idx = target.freq.indices.filter { target.freq[$0] >= b.lo && target.freq[$0] < b.hi }
            let m = idx.map { d[$0] }.max { abs($0) < abs($1) } ?? 0
            return EQAccuracy.Band(name: b.name, maxDeviation: m)
        }
        let mean = scores.reduce(0, +) / Double(scores.count), worst = scores.min() ?? 0
        return EQAccuracy(percent: 100 * (0.5 * mean + 0.5 * worst), maxDeviation: maxDev, rmsDeviation: rms, bands: bandInfo)
    }
}

/// Stored captures of the EQ of the channels, JSON in Application Support.
public struct EQCapture: Codable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var date: Date
    public var rate: Double
    public var channels: [String: EQCurve]       // key: channel number 1...24
    public var manual: [String: ManualEQ] = [:]  // EQ knob positions typed in by hand, same keys
    public var strips: [String: StripSheet] = [:] // the other settings of the channel typed in by hand, same keys

    public init(name: String, date: Date = Date(), rate: Double, channels: [String: EQCurve] = [:], manual: [String: ManualEQ] = [:], strips: [String: StripSheet] = [:]) {
        self.name = name; self.date = date; self.rate = rate; self.channels = channels; self.manual = manual; self.strips = strips
    }

    private enum CodingKeys: String, CodingKey { case name, date, rate, channels, manual, strips }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name); date = try c.decode(Date.self, forKey: .date)
        rate = try c.decode(Double.self, forKey: .rate); channels = try c.decode([String: EQCurve].self, forKey: .channels)
        manual = try c.decodeIfPresent([String: ManualEQ].self, forKey: .manual) ?? [:]       // captures made before the values could be typed
        strips = try c.decodeIfPresent([String: StripSheet].self, forKey: .strips) ?? [:]
    }

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GSR24M", isDirectory: true).appendingPathComponent("recalls", isDirectory: true)
    }

    public static func fileName(_ name: String) -> String {
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return String(safe) + ".json"
    }

    @discardableResult
    public func save(in dir: URL = EQCapture.directory) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]; enc.dateEncodingStrategy = .iso8601
            try enc.encode(self).write(to: dir.appendingPathComponent(Self.fileName(name)), options: .atomic)
            return true
        } catch { return false }
    }

    public static func loadAll(from dir: URL = EQCapture.directory) -> [EQCapture] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(EQCapture.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }
}

public extension EQCurve {
    /// This curve minus the flat reference (same grid), in dB: the EQ alone, without the path of the card.
    func relative(to reference: EQCurve) -> EQCurve? {
        guard freq == reference.freq else { return nil }
        return EQCurve(freq: freq, db: zip(db, reference.db).map { $0 - $1 })
    }
}

/// Flat reference of each channel (EQ IN up, the EQ bypassed), measured once: it holds the path of the card and the console without EQ.
public struct EQReferences: Codable, Equatable {
    public var rate: Double
    public var channels: [String: EQCurve]
    public init(rate: Double = 48000, channels: [String: EQCurve] = [:]) { self.rate = rate; self.channels = channels }

    public static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GSR24M", isDirectory: true).appendingPathComponent("eq-reference.json")
    }

    @discardableResult
    public func save(to url: URL = EQReferences.file) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    public static func load(from url: URL = EQReferences.file) -> EQReferences {
        (try? JSONDecoder().decode(EQReferences.self, from: Data(contentsOf: url))) ?? EQReferences()
    }
}
