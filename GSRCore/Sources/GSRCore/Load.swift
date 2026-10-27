import Foundation

/// The load of the audio chain as the Bus tab shows it: how full the FireWire bus and the MIDI links are, and where it turns critical.
public enum Load {
    /// Isochronous capacity of an S400 bus: 49.152 MB/s, of which 80 % may be reserved for isochronous streams.
    public static let isochCapacity = 49_152_000.0 * 0.8
    /// A MIDI link: 31.25 kbaud, ten bits a byte.
    public static let midiWire = 3125.0

    public enum Level: Int, Comparable { case ok, warning, critical
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public static func level(_ value: Double, warning: Double, critical: Double) -> Level {
        value >= critical ? .critical : value >= warning ? .warning : .ok
    }

    /// Bytes a second the card's streams use on the bus, both directions: the audio and MIDI quadlets of every stream, plus the 8 bytes of
    /// isochronous header of the 8000 packets a second.
    public static func busBytesPerSecond(_ i: DaemonInfo) -> Double? {
        guard let rate = i.rate, rate > 0 else { return nil }
        let streams = (i.tx ?? []) + (i.rx ?? [])
        guard !streams.isEmpty else { return nil }
        return streams.reduce(0.0) { $0 + Double(rate) * Double($1.pcm + ($1.midi > 0 ? 1 : 0)) * 4 + 8000 * 8 }
    }

    /// Share of the isochronous capacity in use (100 is the limit of the bus).
    public static func busPercent(_ i: DaemonInfo) -> Double? { busBytesPerSecond(i).map { $0 / isochCapacity * 100 } }

    /// Events a second between two readings of a counter. A counter that went down (the daemon restarted) counts from zero.
    public static func rate(_ previous: UInt64, _ current: UInt64, seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return Double(current >= previous ? current - previous : current) / seconds
    }
}
