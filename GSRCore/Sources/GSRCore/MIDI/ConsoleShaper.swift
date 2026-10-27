import Foundation

/// Keeps what is sent to the console within what its MIDI input can take. A MIDI link carries 3125 bytes a second (31.25 kbaud); at the start Pro Tools
/// sends the state of every light and every fader, and passing all of it at once saturated the link and crashed the console. Messages go out at once
/// while there is budget (the console stays as quick as before), the rest waits, and a message that is replaced before it was sent (a fader moving, a light
/// that changes twice) is replaced in the queue instead of being sent twice. Pure logic: the caller gives the time and sends what comes back.
public final class ConsoleShaper {
    public var bytesPerSecond: Double                 // average rate allowed; the wire carries 3125
    public var burstBytes: Double                     // what may go out at once after a pause
    public let maxQueued: Int

    private struct Item { var key: String?; var bytes: [UInt8] }
    private var queue: [Item] = []
    private var tokens: Double
    private var last: TimeInterval?

    public private(set) var sentBytes = 0
    public private(set) var coalesced = 0             // messages replaced in the queue by a newer one
    public private(set) var dropped = 0               // messages thrown away because the queue was full
    public private(set) var peakQueued = 0

    public init(bytesPerSecond: Double = 2200, burstBytes: Double = 36, maxQueued: Int = 512) {
        self.bytesPerSecond = bytesPerSecond; self.burstBytes = burstBytes; self.maxQueued = maxQueued; tokens = burstBytes
    }

    public var queued: Int { queue.count }
    public var nextTime: TimeInterval? { queue.isEmpty ? nil : (last ?? 0) + max(0, -tokens + 1) / bytesPerSecond }

    /// Faders, controllers and the lights (notes) replace an older message for the same thing; the rest has no key.
    public static func key(for m: [UInt8]) -> String? {
        guard m.count == 3, m[0] >= 0x80, m[0] < 0xC0 else { return nil }
        let ch = m[0] & 0x0F
        return m[0] & 0xF0 == 0xB0 ? "c\(ch)-\(m[1])" : "n\(ch)-\(m[1])"       // note on and note off of one note replace each other
    }

    /// Adds a message; returns the messages that can be sent now (in order).
    public func push(_ m: [UInt8], now: TimeInterval) -> [[UInt8]] {
        guard !m.isEmpty else { return [] }
        let key = Self.key(for: m)
        if let k = key, let i = queue.firstIndex(where: { $0.key == k }) {
            queue[i].bytes = m; coalesced += 1
        } else {
            if queue.count >= maxQueued { queue.removeFirst(); dropped += 1 }
            queue.append(Item(key: key, bytes: m))
        }
        peakQueued = max(peakQueued, queue.count)
        return drain(now: now)
    }

    /// Messages the budget now allows.
    public func drain(now: TimeInterval) -> [[UInt8]] {
        if let l = last { tokens = min(burstBytes, tokens + max(0, now - l) * bytesPerSecond) }
        last = now
        var out: [[UInt8]] = []
        while tokens > 0, !queue.isEmpty {
            let item = queue.removeFirst()
            tokens -= Double(item.bytes.count)                // may go below zero: the debt is paid by the next refill, so the average holds
            sentBytes += item.bytes.count
            out.append(item.bytes)
        }
        return out
    }

    public func reset() { queue.removeAll(); tokens = burstBytes; last = nil }
}
