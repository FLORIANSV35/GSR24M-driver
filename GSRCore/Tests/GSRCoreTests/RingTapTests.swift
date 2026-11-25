import Testing
import Foundation
import CGSRRing
@testable import GSRCore

@Suite struct RingTapTests {
    /// A formatted ring in plain memory, as gsrd would hold it.
    final class Region {
        let ptr: UnsafeMutableRawPointer, bytes: Int
        init(ringFrames: UInt32 = 1024, rate: UInt32 = 48000) {
            bytes = gsrv_ring_bytes_for(ringFrames)
            ptr = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 4096)
            gsrv_format(ptr, ringFrames, rate)
        }
        deinit { ptr.deallocate() }
    }

    @Test func rejectsGarbage() {
        let p = UnsafeMutableRawPointer.allocate(byteCount: 8192, alignment: 4096); defer { p.deallocate() }
        memset(p, 0, 8192)
        #expect(RingTap(region: p, bytes: 8192) == nil)
    }

    @Test func readsTheCaptureRingAndMarksWhatIsNotThereYet() {
        let r = Region()
        for f in 0..<300 { gsrv_test_write(r.ptr, 0, 2, UInt64(f), Float(f)); gsrv_test_write(r.ptr, 0, 5, UInt64(f), -Float(f)) }
        gsrv_test_set_written(r.ptr, 300, 0)
        let tap = RingTap(region: r.ptr, bytes: r.bytes)!
        #expect(tap.sampleRate == 48000 && tap.isStreaming && tap.now == 300)
        var l = [Float](repeating: 9, count: 100), rr = [Float](repeating: 9, count: 100)
        let n = tap.read(.consoleInputs, left: 2, right: 5, from: 250, into: &l, &rr, frames: 100)
        #expect(n == 50)                                          // frames 250..299 exist
        #expect(l[0] == 250 && l[49] == 299 && rr[49] == -299)
        #expect(l[50] == 0 && l[99] == 0)                         // not captured yet: silence
    }

    @Test func playbackRingAndOverwrittenFramesAreSilence() {
        let r = Region(ringFrames: 1024)
        for f in 0..<3000 { gsrv_test_write(r.ptr, 1, 0, UInt64(f), Float(f % 1000) + 1); gsrv_test_write(r.ptr, 1, 1, UInt64(f), 7) }
        gsrv_test_set_written(r.ptr, 0, 3000)
        let tap = RingTap(region: r.ptr, bytes: r.bytes)!
        var l = [Float](repeating: 9, count: 64), rr = [Float](repeating: 9, count: 64)
        #expect(tap.read(.macOutputs, left: 0, right: 1, from: 2900, into: &l, &rr, frames: 64) == 64)
        #expect(l[0] == Float(2900 % 1000) + 1 && rr[63] == 7)
        #expect(tap.read(.macOutputs, left: 0, right: 1, from: 100, into: &l, &rr, frames: 64) == 0)    // more than one ring ago
        #expect(l.allSatisfy { $0 == 0 })
    }

    @Test func cursorFollowsCardTime() {
        var c = TapCursor()
        #expect(c.next(now: 10_000, generation: 1, block: 512, ringFrames: 32768) == .wait)          // start
        #expect(c.position == 10_000 - 1024)
        #expect(c.next(now: 10_100, generation: 1, block: 512, ringFrames: 32768) == .block(8976))   // two blocks behind
        #expect(c.next(now: 10_100, generation: 1, block: 512, ringFrames: 32768) == .block(9488))
        #expect(c.next(now: 10_100, generation: 1, block: 512, ringFrames: 32768) == .wait)
        // the app was stopped: far behind, it jumps
        if case .skipped(let n) = c.next(now: 60_000, generation: 1, block: 512, ringFrames: 32768) { #expect(n > 40_000) } else { Issue.record("no skip") }
        // the stream restarted: card time went back to 0 and the generation changed
        #expect(c.next(now: 300, generation: 2, block: 512, ringFrames: 32768) == .restarted)
        #expect(c.position == 0)
    }
}
