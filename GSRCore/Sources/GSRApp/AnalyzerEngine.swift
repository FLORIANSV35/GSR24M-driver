import Foundation
import AVFoundation
import AudioToolbox
import GSRCore

/// One hosted plug-in. The engine feeds it two channels and throws its output away: this is a host for analysers, there is no output.
final class AnalyzerSlot {
    let id = UUID()
    let key: String                    // manufacturer / type / subtype, to find the plug-in again
    let title: String
    let unit: AVAudioUnit
    fileprivate var renderBlock: AURenderBlock?
    fileprivate var configuredRate: Double = 0
    fileprivate let out: UnsafeMutableAudioBufferListPointer
    /// Written by the feed thread, read by the interface (plain values, a torn read is harmless).
    fileprivate(set) var loadAverage: Double = 0, loadPeak: Double = 0, overloads = 0, failures = 0, rendered = 0
    fileprivate(set) var outPeak: Float = 0          // peak of what the plug-in last rendered (thrown away, kept for the self test)
    fileprivate(set) var error: String?

    init(key: String, title: String, unit: AVAudioUnit) {
        self.key = key; self.title = title; self.unit = unit
        out = AudioBufferList.allocate(maximumBuffers: 2)
        for i in 0..<2 {
            let bytes = Int(AnalyzerEngine.maxFrames) * MemoryLayout<Float>.size
            let mem = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
            memset(mem, 0, bytes)
            out[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: mem)
        }
    }
    deinit {
        for b in out { b.mData?.deallocate() }
        out.unsafeMutablePointer.deallocate()
    }

    /// 2 in / 2 out at the card's rate, as SimplePlug does. AUv2 plug-ins come with their input bus disabled: without enabling it they render silence.
    fileprivate func prepare(rate: Double) {
        let au = unit.auAudioUnit
        if renderBlock != nil { au.deallocateRenderResources() }
        renderBlock = nil; configuredRate = 0
        do {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { throw AnalyzerError("invalid audio format") }
            if au.inputBusses.count > 0 { au.inputBusses[0].isEnabled = true; try au.inputBusses[0].setFormat(format) }
            if au.outputBusses.count > 0 { try au.outputBusses[0].setFormat(format) }
            au.maximumFramesToRender = AnalyzerEngine.maxFrames
            try au.allocateRenderResources()
            renderBlock = au.renderBlock
            configuredRate = rate
            error = nil
        } catch {
            self.error = "This plug-in does not accept 2 in / 2 out at \(Int(rate)) Hz (\(error.localizedDescription))"
        }
    }
    fileprivate func release() {
        if renderBlock != nil { unit.auAudioUnit.deallocateRenderResources() }
        renderBlock = nil
    }
}

struct AnalyzerError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Feeds the plug-ins from the card's rings. A thread of its own walks card time in blocks of `block` frames, a little behind "now", reads the two chosen
/// channels (the console's inputs, or what the Mac sends to the console) and renders every plug-in on them. Nothing goes back to the card or to CoreAudio.
final class AnalyzerEngine {
    static let maxFrames: UInt32 = 8192
    static let block = 512

    struct Status { var connected = false, streaming = false; var rate = 0.0; var peakL: Float = 0, peakR: Float = 0; var names: [[String]] = [[], []] }

    /// The rate the card ran at the last time; used to initialise a plug-in before the ring is there.
    static var assumedRate: Double {
        get { let r = UserDefaults.standard.double(forKey: "analyzer.rate"); return r >= 8000 ? r : 48000 }
        set { UserDefaults.standard.set(newValue, forKey: "analyzer.rate") }
    }

    private let lock = NSLock()
    private var slots: [AnalyzerSlot] = []
    private var source = RingTap.Source.consoleInputs
    private var left = 0, right = 1
    private var tap: RingTap?
    private var cursor = TapCursor()
    private var thread: Thread?
    private var running = false
    private var lastNow: UInt64 = 0
    private var lastAdvance = Date()
    private var lastFetch = Date.distantPast
    private var lastNames = Date.distantPast
    private var status = Status()

    private let inList: UnsafeMutableAudioBufferListPointer
    private var pull: AURenderPullInputBlock?
    private static let secondsPerTick: Double = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return Double(t.numer) / Double(t.denom) * 1e-9 }()

    init() {
        inList = AudioBufferList.allocate(maximumBuffers: 2)
        for i in 0..<2 {
            let bytes = Int(Self.maxFrames) * MemoryLayout<Float>.size
            let mem = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
            memset(mem, 0, bytes)
            inList[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: mem)
        }
        let src = inList
        pull = { _, _, frames, bus, abl in
            guard bus == 0 else { return kAudioUnitErr_NoConnection }
            let dst = UnsafeMutableAudioBufferListPointer(abl)
            let bytes = Int(frames) * MemoryLayout<Float>.size
            for i in 0..<min(dst.count, src.count) {
                if let d = dst[i].mData, let s = src[i].mData { memcpy(d, s, bytes) } else { dst[i].mData = src[i].mData }
                dst[i].mDataByteSize = UInt32(bytes)
            }
            return noErr
        }
    }
    deinit {
        stop()
        for b in inList { b.mData?.deallocate() }
        inList.unsafeMutablePointer.deallocate()
    }

    // MARK: control (main thread)

    func setRouting(source: RingTap.Source, left: Int, right: Int) {
        lock.lock(); defer { lock.unlock() }
        self.source = source; self.left = max(0, min(31, left)); self.right = max(0, min(31, right))
    }

    func add(_ slot: AnalyzerSlot) {
        lock.lock(); defer { lock.unlock() }
        slots.append(slot)
        // Initialised at once, before its view first draws: some views (Apple's AUGraphicEQ) assert when they read a parameter of an uninitialised unit.
        // The rate is the card's when the ring is there, otherwise the last one seen; if it turns out to be another one the unit is prepared again.
        slot.prepare(rate: (tap?.sampleRate ?? 0) > 0 ? tap!.sampleRate : Self.assumedRate)
    }

    func remove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if let i = slots.firstIndex(where: { $0.id == id }) { slots[i].release(); slots.remove(at: i) }
    }

    func snapshot() -> Status { lock.lock(); defer { lock.unlock() }; return status }

    func start() {
        guard !running else { return }
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.name = "gsr.analyzer"; t.qualityOfService = .userInteractive
        thread = t; t.start()
    }

    func stop() {
        running = false
        thread?.cancel(); thread = nil
        lock.lock(); for s in slots { s.release() }; lock.unlock()
    }

    // MARK: feed thread

    private func loop() {
        while running && !(Thread.current.isCancelled) {
            usleep(3000)
            lock.lock()
            step()
            lock.unlock()
        }
    }

    private func step() {
        // the ring: ask gsrd for it when there is none, or when card time stopped moving (gsrd restarted: the old memory is dead)
        if let t = tap {
            let n = t.now
            if n != lastNow { lastNow = n; lastAdvance = Date() }
            else if Date().timeIntervalSince(lastAdvance) > 1.5 && t.isStreaming == false || Date().timeIntervalSince(lastAdvance) > 4 { tap = nil }
        }
        if tap == nil {
            status.connected = false; status.streaming = false
            guard Date().timeIntervalSince(lastFetch) > 1 else { return }
            lastFetch = Date()
            lock.unlock(); let fresh = RingClient.fetch(); lock.lock()
            guard let f = fresh else { return }
            tap = f; lastNow = f.now; lastAdvance = Date(); cursor = TapCursor()
            for s in slots { s.configuredRate = 0 }
        }
        guard let tap else { return }
        let rate = tap.sampleRate
        status.connected = true; status.streaming = tap.isStreaming; status.rate = rate
        if rate > 0 && rate != Self.assumedRate { Self.assumedRate = rate }
        if Date().timeIntervalSince(lastNames) > 1 {
            lastNames = Date()
            status.names = [(0..<32).map { tap.channelName(.consoleInputs, $0) }, (0..<32).map { tap.channelName(.macOutputs, $0) }]
        }
        guard rate > 0, tap.isStreaming else { return }
        for s in slots where s.configuredRate != rate { s.prepare(rate: rate) }

        var done = 0
        while done < 8 {
            let st = cursor.next(now: tap.now, generation: tap.generation, block: Self.block, ringFrames: tap.ringFrames)
            switch st {
            case .wait: return
            case .restarted: for s in slots { s.unit.auAudioUnit.reset() }
            case .skipped: break
            case .block(let pos): render(tap: tap, at: pos, rate: rate); done += 1
            }
            if case .wait = st { return }
        }
    }

    private func render(tap: RingTap, at pos: UInt64, rate: Double) {
        let frames = UInt32(Self.block)
        guard let l = inList[0].mData?.assumingMemoryBound(to: Float.self), let r = inList[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        _ = tap.read(source, left: left, right: right, from: pos, into: l, r, frames: Int(frames))
        var pl: Float = 0, pr: Float = 0
        for i in 0..<Int(frames) { pl = max(pl, abs(l[i])); pr = max(pr, abs(r[i])) }
        status.peakL = max(pl, status.peakL * 0.92); status.peakR = max(pr, status.peakR * 0.92)
        let bytes = frames * UInt32(MemoryLayout<Float>.size)
        for i in 0..<2 { inList[i].mDataByteSize = bytes }

        for s in slots {
            guard let block = s.renderBlock, let pull else { continue }
            for i in 0..<2 { s.out[i].mDataByteSize = bytes; if s.out[i].mData == nil { continue } }
            var flags = AudioUnitRenderActionFlags()
            var ts = AudioTimeStamp()
            ts.mSampleTime = Float64(pos); ts.mHostTime = mach_absolute_time(); ts.mRateScalar = 1
            ts.mFlags = [.sampleTimeValid, .hostTimeValid, .rateScalarValid]
            let t0 = mach_absolute_time()
            let err = block(&flags, &ts, frames, 0, s.out.unsafeMutablePointer, pull)
            let load = Double(mach_absolute_time() &- t0) * Self.secondsPerTick / (Double(frames) / rate)
            s.loadAverage = s.loadAverage * 0.95 + load * 0.05
            if load > s.loadPeak { s.loadPeak = load } else { s.loadPeak *= 0.999 }
            if load > 1 { s.overloads += 1 }
            if err != noErr { s.failures += 1 } else if let o = s.out[0].mData?.assumingMemoryBound(to: Float.self) { var p: Float = 0; for i in 0..<Int(frames) { p = max(p, abs(o[i])) }; s.outPeak = p }
            s.rendered += 1
        }
    }
}
