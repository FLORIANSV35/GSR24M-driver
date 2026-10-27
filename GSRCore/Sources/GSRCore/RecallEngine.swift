import Foundation
import CoreAudio

/// Plays periodic pink noise into one return channel of the GS-R24M device and records the send of the same channel.
/// It uses the normal CoreAudio device (gsrd and the plug-in must be running, no other application on the device).
/// The noise has a fade in and a fade out and is never louder than -20 dBFS rms.
public final class RecallEngine {
    public enum EngineError: Error, Equatable { case noDevice, cannotStart(Int32) }

    private struct State {
        var noise: UnsafeMutablePointer<Float>
        var noiseLength: Int
        var ring: UnsafeMutablePointer<Float>
        var ringCapacity: Int
        var writeIndex: Int
        var channelOut: Int
        var channelIn: Int
        var amp: Float
        var frames: Int
        var stopFrame: Int      // -1 while playing
        var fade: Int
    }

    public static let deviceName = "GS-R24M FireWire"
    public private(set) var rate: Double = 48000
    public private(set) var running = false
    private var device: AudioDeviceID = 0
    private var procID: AudioDeviceIOProcID?
    private var state: UnsafeMutablePointer<State>
    private let queue = DispatchQueue(label: "gsr.recall.io", qos: .userInteractive)
    public let periodLength = EQMeasure.period

    public init() {
        let n = EQMeasure.period
        state = UnsafeMutablePointer<State>.allocate(capacity: 1)
        let ringCap = n * 6
        let ring = UnsafeMutablePointer<Float>.allocate(capacity: ringCap); ring.initialize(repeating: 0, count: ringCap)
        let noise = UnsafeMutablePointer<Float>.allocate(capacity: n); noise.initialize(repeating: 0, count: n)
        state.initialize(to: State(noise: noise, noiseLength: n, ring: ring, ringCapacity: ringCap, writeIndex: 0, channelOut: 1, channelIn: 1, amp: 0, frames: 0, stopFrame: -1, fade: 24000))
    }

    deinit {
        stopNow()
        state.pointee.noise.deallocate(); state.pointee.ring.deallocate(); state.deallocate()
    }

    public static func findDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var cf: Unmanaged<CFString>?
            var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &sz, &cf) == noErr, let s = cf?.takeRetainedValue() as String?, s == deviceName { return id }
        }
        return nil
    }

    public static var deviceAvailable: Bool { findDevice() != nil }

    /// Starts the noise on `channel` (1 to 24). `levelDB` is the rms level in dBFS, capped at -20.
    public func start(channel: Int, levelDB: Double = -36) throws {
        stopNow()
        guard let dev = Self.findDevice() else { throw EngineError.noDevice }
        device = dev
        var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var r = Float64(48000); var sz = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(dev, &rateAddr, 0, nil, &sz, &r)
        rate = r
        var bufAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bf = UInt32(512)
        AudioObjectSetPropertyData(dev, &bufAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bf)

        let n = periodLength
        let pink = EQMeasure.pinkPeriod(seed: UInt64(channel), rate: rate, length: n)
        for i in 0..<n { state.pointee.noise[i] = pink[i] }
        for i in 0..<state.pointee.ringCapacity { state.pointee.ring[i] = 0 }
        state.pointee.writeIndex = 0; state.pointee.frames = 0; state.pointee.stopFrame = -1
        state.pointee.channelOut = max(1, min(32, channel)); state.pointee.channelIn = state.pointee.channelOut
        state.pointee.amp = Float(pow(10.0, min(levelDB, -20) / 20))
        state.pointee.fade = Int(0.5 * rate)

        let st = state
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, queue) { _, inData, _, outData, outTime in
            let s = st
            let n = s.pointee.noiseLength, ch = 32
            // input: keep the send of the channel
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            var framesIn = 0
            if inList.count > 0, let p = inList[0].mData?.assumingMemoryBound(to: Float.self) {
                framesIn = Int(inList[0].mDataByteSize) / (ch * MemoryLayout<Float>.size)
                let c = s.pointee.channelIn - 1
                for i in 0..<framesIn {
                    s.pointee.ring[(s.pointee.writeIndex + i) % s.pointee.ringCapacity] = p[i * ch + c]
                }
                s.pointee.writeIndex += framesIn
            }
            // output: noise on the same channel
            let outList = UnsafeMutableAudioBufferListPointer(outData)
            if outList.count > 0, let o = outList[0].mData?.assumingMemoryBound(to: Float.self) {
                let frames = Int(outList[0].mDataByteSize) / (ch * MemoryLayout<Float>.size)
                memset(o, 0, Int(outList[0].mDataByteSize))
                let base = Int(outTime.pointee.mSampleTime)
                let c = s.pointee.channelOut - 1
                for i in 0..<frames {
                    let f = s.pointee.frames
                    var env: Float = 1
                    if f < s.pointee.fade { env = Float(f) / Float(s.pointee.fade) }
                    if s.pointee.stopFrame >= 0 { env = min(env, max(0, 1 - Float(f - s.pointee.stopFrame) / Float(s.pointee.fade))) }
                    s.pointee.frames += 1
                    if env <= 0 { continue }
                    let idx = ((base + i) % n + n) % n
                    o[i * ch + c] = s.pointee.amp * env * s.pointee.noise[idx]
                }
            }
        }
        guard status == noErr, let pid = procID else { throw EngineError.cannotStart(status) }
        let startStatus = AudioDeviceStart(dev, pid)
        guard startStatus == noErr else { AudioDeviceDestroyIOProcID(dev, pid); procID = nil; throw EngineError.cannotStart(startStatus) }
        running = true
    }

    /// Fades the noise out, then stops the device.
    public func stop(completion: (() -> Void)? = nil) {
        guard running else { completion?(); return }
        state.pointee.stopFrame = state.pointee.frames
        let wait = Double(state.pointee.fade) / rate + 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.stopNow(); completion?() }
    }

    func stopNow() {
        if let pid = procID { AudioDeviceStop(device, pid); AudioDeviceDestroyIOProcID(device, pid); procID = nil }
        running = false
        state.pointee.amp = 0
    }

    /// Frames recorded so far.
    public var recordedFrames: Int { state.pointee.writeIndex }

    /// The last `frames` samples of the channel's send, ending 4096 samples before the newest one (away from the writer).
    public func recent(frames: Int) -> [Float]? {
        let s = state.pointee
        let end = s.writeIndex - 4096
        guard frames <= s.ringCapacity - 8192, end - frames >= 0 else { return nil }
        return (0..<frames).map { s.ring[(end - frames + $0) % s.ringCapacity] }
    }
}
