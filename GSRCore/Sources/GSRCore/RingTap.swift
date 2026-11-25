import Foundation
import CGSRRing

/// Reads the audio rings gsrd shares (the same memory the CoreAudio plug-in uses), read only: the capture ring holds what the console sends to the Mac
/// (the card's 32 inputs), the playback ring what the Mac sends to the console (the plug-in's output, as CoreAudio mixed it).
/// Both are on the card's frame counter ("card time"): playback frame S is heard at the console when the capture counter reaches S, so one cursor serves both.
public final class RingTap {
    public enum Source: String, Codable, CaseIterable { case consoleInputs = "Console inputs", macOutputs = "Mac outputs" }

    private let region: UnsafeRawPointer
    private let bytes: Int
    private let keep: Any?                         // what keeps the memory mapped (the XPC shared memory object, or nothing for a test region)

    public init?(region: UnsafeRawPointer, bytes: Int, keep: Any? = nil) {
        guard gsrv_ok(region, bytes) != 0 else { return nil }
        self.region = region; self.bytes = bytes; self.keep = keep
    }

    public var generation: UInt32 { gsrv_generation(region) }
    public var isStreaming: Bool { gsrv_state(region) == 2 }
    public var sampleRate: Double { Double(gsrv_rate(region)) }
    public var ringFrames: UInt64 { UInt64(gsrv_ring_frames(region)) }
    /// Card time "now": the number of frames captured since the stream started.
    public var now: UInt64 { gsrv_in_written(region) }

    /// Name of a channel as the daemon publishes it (the app's own names come from `ChannelNames`).
    public func channelName(_ source: Source, _ ch: Int) -> String {
        var buf = [CChar](repeating: 0, count: 40)
        gsrv_name(region, source == .macOutputs ? 1 : 0, UInt32(ch), &buf, buf.count)
        return String(cString: buf)
    }

    /// Fills `left` and `right` (same length) with the two channels from card frame `from`. Returns how many frames of the left channel were valid
    /// (a frame that was not captured or written yet, or that was overwritten, reads as silence).
    @discardableResult
    public func read(_ source: Source, left: Int, right: Int, from: UInt64, into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let out: Int32 = source == .macOutputs ? 1 : 0
        let a = gsrv_copy(region, out, UInt32(max(0, left)), from, UInt32(frames), l)
        _ = gsrv_copy(region, out, UInt32(max(0, right)), from, UInt32(frames), r)
        return Int(a)
    }
}

/// Where the analysis cursor is and what to do with it: it follows card time a little behind (so a block is complete when it is read), jumps when it falls
/// too far behind (the app was stopped for a while) and starts again when the stream restarted (card time went back to 0).
public struct TapCursor {
    public private(set) var position: UInt64 = 0
    public private(set) var started = false
    public private(set) var generation: UInt32 = 0
    public init() {}

    public enum Step: Equatable { case wait, block(UInt64), restarted, skipped(UInt64) }

    /// `now` is card time, `block` the block size in frames, `ringFrames` the size of the ring. Returns what to do.
    public mutating func next(now: UInt64, generation g: UInt32, block: Int, ringFrames: UInt64) -> Step {
        let b = UInt64(block)
        if !started || g != generation || position > now {
            let wasStarted = started
            generation = g; started = true
            position = now >= 2 * b ? now - 2 * b : 0       // start two blocks behind: the first block is complete
            return wasStarted ? .restarted : .wait
        }
        if now - position > ringFrames / 2 {                   // behind by more than half the ring: the oldest frames are about to be overwritten
            let skippedTo = now - 2 * b
            let n = skippedTo - position
            position = skippedTo
            return .skipped(n)
        }
        if now - position >= b { let p = position; position += b; return .block(p) }
        return .wait
    }
}
