import Foundation
import SwiftUI
import GSRCore

/// EQ recall, channel by channel: measures the live EQ curve of the selected channel and compares it with a stored capture.
@MainActor
final class RecallModel: ObservableObject {
    enum Mode: Equatable { case idle, live, capturingOne, capturingAll }

    @Published var captures: [EQCapture] = EQCapture.loadAll()
    @Published var targetName: String?
    @Published var channel = 1
    @Published private(set) var mode = Mode.idle
    @Published private(set) var live: EQCurve?
    @Published private(set) var accuracy: EQAccuracy?
    @Published private(set) var scores: [Int: Double] = [:]          // last accuracy per channel in this session
    @Published private(set) var working = EQCapture(name: "", rate: 48000)   // capture being made
    @Published var newName = ""
    @Published var message = ""
    @Published var progress: Double?
    @Published var askChecklist = false
    @Published private(set) var references = EQReferences.load()     // flat curves (EQ IN up), one per channel
    @Published private(set) var settings: EQSettings?                // knob positions estimated from the live curve
    @Published private(set) var targetSettings: EQSettings?          // same for the stored capture
    @Published private(set) var pendingReference = false
    @Published private(set) var activeKnob: EQGuide.Knob?            // the knob being turned, recognised from the movement of the live curve
    @Published private(set) var activeRemaining: Double?             // how far it still has to go to reach the target (positive: clockwise)
    @Published private(set) var advisor = RecallAdvisor()            // which knob to turn, which way, how far (first pass, then refinement)

    private let engine = RecallEngine()
    private var timer: Timer?
    private var pending: Mode = .idle
    var pendingMode: Mode { pending }
    private var allQueue: [Int] = []
    private var silentChannels: [Int] = []                          // channels whose send came back empty in the last capture
    private var analysing = false
    private let tolerance = 0.2
    private var capturingReference = false
    private var targetFits: [String: EQSettings] = [:]
    private var lastFit: (curve: EQCurve, settings: EQSettings)?       // the fit is redone only when the curve has moved
    private var tracker = KnobTracker()                                // recognises the knob being turned from the stream of live curves

    var target: EQCapture? { captures.first { $0.name == targetName } }
    var targetCurve: EQCurve? { target?.channels[String(channel)] }
    var reference: EQCurve? { references.channels[String(channel)] }
    var running: Bool { mode != .idle }
    var deviceAvailable: Bool { RecallEngine.deviceAvailable }

    // MARK: user actions

    /// Every start goes through the checklist.
    func request(_ m: Mode, reference: Bool = false) { pending = m; pendingReference = reference; askChecklist = true }

    func confirmChecklist() {
        askChecklist = false
        switch pending {
        case .live: startLive()
        case .capturingOne: startCapture(channels: [channel], reference: pendingReference)
        case .capturingAll: startCapture(channels: Array(1...24), reference: pendingReference)
        case .idle: break
        }
    }

    func stop() {
        stopFaderWatch()
        timer?.invalidate(); timer = nil
        allQueue = []; progress = nil; capturingReference = false
        engine.stop { [weak self] in self?.mode = .idle }
        mode = .idle
    }

    func select(_ c: Int) {
        guard c != channel else { return }
        if mode == .live { stop() }
        channel = c; live = nil; accuracy = nil; settings = nil; targetSettings = nil; lastFit = nil; resetKnobTracking()
    }

    // MARK: live view

    private func startLive() {
        do { try engine.start(channel: channel) } catch { message = "Cannot start the measurement: \(error)"; return }
        mode = .live; live = nil; accuracy = nil; settings = nil; lastFit = nil; resetKnobTracking(); message = "Measuring channel \(channel)…"
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshLive() } }
    }

    private func resetKnobTracking() { activeKnob = nil; activeRemaining = nil; advisor.reset(); tracker.reset() }


    private func refreshLive() {
        guard mode == .live, !analysing, let rec = engine.recent(frames: EQMeasure.period) else { return }
        let level = (rec.reduce(0) { $0 + Double($1 * $1) } / Double(rec.count)).squareRoot()
        if level < 1e-6 {
            live = nil; accuracy = nil
            message = "No signal comes back from the console. If macOS asked for microphone access, allow it (System Settings, Privacy and Security, Microphone); otherwise check A and B on channel \(channel)."
            return
        }
        analysing = true
        let ref = EQMeasure.pinkPeriod(seed: UInt64(channel), rate: engine.rate), rate = engine.rate
        let tgt = targetCurve, ch = channel, tol = tolerance, flat = reference
        let key = "\(targetName ?? "")#\(ch)", cached = targetFits[key], last = lastFit, previous = live
        let manualTarget = target?.manual[String(ch)]
        var knobTracker = tracker
        let now = Date().timeIntervalSinceReferenceDate
        DispatchQueue.global(qos: .userInitiated).async {
            var c = EQMeasure.curve(recorded: rec, reference: ref, rate: rate, maxPeriods: 1)
            if var cc = c, let p = previous, p.freq == cc.freq { cc.db = zip(p.db, cc.db).map { 0.4 * $0 + 0.6 * $1 }; c = cc }   // light smoothing
            let a = (c != nil && tgt != nil) ? EQMeasure.accuracy(target: tgt!, live: c!, tolerance: tol) : nil
            var s: EQSettings?, ts = cached
            let lr = (c != nil && flat != nil) ? c!.relative(to: flat!) : nil
            if let c, let lr {
                if let last, last.curve.freq == c.freq, zip(last.curve.db, c.db).allSatisfy({ abs($0 - $1) < 0.1 }) { s = last.settings }
                else { s = EQFit.fit(freq: lr.freq, db: lr.db) }
            }
            let tr = (tgt != nil && flat != nil) ? tgt!.relative(to: flat!) : nil
            if ts == nil, let tr { ts = EQFit.fit(freq: tr.freq, db: tr.db) }
            // which knob is being turned, and how far it still has to go
            var turned: EQGuide.Knob?
            if let lr, let s { turned = knobTracker.update(time: now, curve: lr, around: s) }
            var remaining: Double?
            if let knob = turned, let lr, let s, let tr { remaining = EQGuide.remaining(live: lr, target: tr, knob: knob, around: s) }
            var guidance: EQGuide.Guidance?
            if let lr, let s, let tr { guidance = EQGuide.guidance(live: lr, target: tr, around: s) }
            DispatchQueue.main.async {
                self.analysing = false
                guard self.mode == .live, self.channel == ch else { return }
                if let c { self.live = c }
                self.accuracy = a
                if let a { self.scores[ch] = a.percent }
                self.settings = s
                if let c, let s { self.lastFit = (c, s) }
                if let ts { self.targetFits[key] = ts }
                let used = (ts != nil && manualTarget != nil) ? manualTarget!.settings(fallback: ts!) : ts            // typed values win over the fit
                self.targetSettings = tgt == nil ? nil : used
                self.message = tgt == nil ? "No stored curve for channel \(ch): choose a capture or make one." : ""
                self.tracker = knobTracker
                self.activeKnob = turned
                self.activeRemaining = turned == nil ? nil : remaining
                var deltas: [Double]?
                if tgt != nil, let s, let used { deltas = EQGuide.fitDeltas(live: s, target: used) }
                self.advisor.update(now: Date().timeIntervalSinceReferenceDate, accuracy: tgt == nil ? nil : a?.percent, deltas: deltas, gap: tgt == nil ? nil : guidance,
                                    active: turned, activeRemaining: turned == nil ? nil : remaining)
            }
        }
    }

    // MARK: fader levels during a capture, and the recall of all of them

    // MARK: console rotaries

    /// A rotary of the console (1 to 12, absolute 0 to 127 in mode 3: controller 0x3F + n), with the state of Shift at that moment.
    struct PotMove: Equatable { let id: Int; let pot: Int; let value: Int; let shift: Bool }
    @Published private(set) var potMove: PotMove?
    private let potClient = AgentClient()
    private var potsListening = false, shiftHeld = false, potCount = 0

    /// Listens to the rotaries (own connection to the agent, so that the fader capture can come and go).
    func startPots() {
        guard !potsListening else { return }
        potsListening = true
        let c = potClient
        DispatchQueue.global(qos: .userInitiated).async {
            c.startMonitor(onTraffic: { [weak self] dir, bytes in
                guard dir == "console in" else { return }
                Task { @MainActor in
                    guard let self, self.potsListening else { return }
                    for m in midiMessages(bytes) where m.count == 3 {
                        switch m[0] & 0xF0 {
                        case 0x90 where m[1] == 0x6C: self.shiftHeld = m[2] > 0
                        case 0x80 where m[1] == 0x6C: self.shiftHeld = false
                        case 0xB0 where (0x40...0x4B).contains(m[1]):
                            self.potCount += 1
                            self.potMove = PotMove(id: self.potCount, pot: Int(m[1]) - 0x3F, value: Int(m[2]), shift: self.shiftHeld)
                        default: break
                        }
                    }
                }
            }, onEvent: { _ in })
        }
    }

    func stopPots() {
        guard potsListening else { return }
        potsListening = false
        let c = potClient
        DispatchQueue.global(qos: .utility).async { c.stopMonitor() }
    }

    private var faderWatching = false
    private var fadersSeen: [Int: Int] = [:]          // channel to the last position the console sent while capturing

    /// While channels are captured, every fader that is moved or touched (WRITE on) gives its position.
    private func startFaderWatch() {
        guard !faderWatching, faderCapture == nil else { return }
        faderWatching = true; fadersSeen = [:]
        let c = midiClient
        DispatchQueue.global(qos: .userInitiated).async {
            c.startMonitor(onTraffic: { [weak self] _, bytes in
                Task { @MainActor in
                    guard let self, self.faderWatching else { return }
                    for m in midiMessages(bytes) where m.count == 3 && m[0] & 0xF0 == 0xB0 && (1...24).contains(Int(m[1])) { self.fadersSeen[Int(m[1])] = Int(m[2]) }
                }
            }, onEvent: { _ in })
        }
    }

    private func stopFaderWatch() {
        guard faderWatching else { return }
        faderWatching = false
        let c = midiClient
        DispatchQueue.global(qos: .utility).async { c.stopMonitor() }
    }

    /// Keeps the positions seen with the channels that were captured; returns how many.
    private func applyFadersSeen() -> Int {
        stopFaderWatch()
        var n = 0
        for (ch, v) in fadersSeen where working.channels[String(ch)] != nil {
            var s = working.strips[String(ch)] ?? StripSheet()
            s.faderMIDI = v; s.fader = (StripSheet.faderDB(midi: v) * 2).rounded() / 2
            working.strips[String(ch)] = s; n += 1
        }
        fadersSeen = [:]
        return n
    }

    /// The channels that have a fader position noted, in the capture being made or else in the target.
    var fadersNoted: [(channel: Int, midi: Int)] {
        let strips = working.strips.values.contains { $0.faderMIDI != nil } ? working.strips : (target?.strips ?? [:])
        return strips.compactMap { k, s in Int(k).flatMap { ch in s.faderMIDI.map { (ch, $0) } } }.sorted { $0.channel < $1.channel }
    }

    /// Sends every noted fader position to its motorised fader (READ on, on the console).
    func recallAllFaders() {
        let list = fadersNoted
        guard !list.isEmpty else { message = "No fader level noted: capture the channels while touching their faders."; return }
        let c = midiClient
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = list.filter { c.setFader(channel: $0.channel, value: $0.midi) }.count
            DispatchQueue.main.async { self.message = ok == list.count ? "\(ok) fader(s) sent to their noted position (READ on, on the console)." : "Only \(ok) of \(list.count) fader(s) were sent: is the MIDI agent running?" }
        }
    }

    // MARK: fader level by MIDI

    /// The channel whose fader level is being waited for from the console's MIDI.
    @Published private(set) var faderCapture: Int?
    private let midiClient = AgentClient()
    private var faderPending: Int?
    private var faderSettle: Timer?
    private var faderTimeout: Timer?

    /// Reads the position of the fader of the channel from the MIDI of the console (the controller of the channel number, 0 to 127, sent when the fader is
    /// moved or touched with WRITE on) through the MIDI agent. The last position, once the fader has been still for a moment, is kept.
    func captureFaderLevel(channel ch: Int) {
        guard canNote(channel: ch), faderCapture == nil else { return }
        faderCapture = ch; faderPending = nil
        message = "Move or touch the fader of channel \(ch) on the console (WRITE on)…"
        let c = midiClient
        DispatchQueue.global(qos: .userInitiated).async {
            c.startMonitor(onTraffic: { [weak self] _, bytes in Task { @MainActor in self?.faderMIDI(bytes, channel: ch) } }, onEvent: { _ in })
        }
        faderTimeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.faderCapture == ch else { return }
                self.stopFaderCapture()
                self.message = "No movement of the fader of channel \(ch) seen: is the MIDI agent running, and WRITE on?"
            }
        }
    }

    /// Sends the stored position of the fader to the motorised fader of the channel (READ on, on the console).
    func recallFader(channel ch: Int) {
        guard let v = strip(channel: ch).faderMIDI else { message = "No fader level noted for channel \(ch): capture it first."; return }
        let c = midiClient
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = c.setFader(channel: ch, value: v)
            DispatchQueue.main.async { self.message = ok ? "Fader of channel \(ch) sent to MIDI \(v) (READ on, on the console)." : "The MIDI agent did not answer: the fader was not moved." }
        }
    }

    private func faderMIDI(_ bytes: [UInt8], channel ch: Int) {
        guard faderCapture == ch else { return }
        for m in midiMessages(bytes) where m.count == 3 && m[0] & 0xF0 == 0xB0 && Int(m[1]) == ch { faderPending = Int(m[2]) }
        guard faderPending != nil else { return }
        faderSettle?.invalidate()
        faderSettle = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.faderCapture == ch, let v = self.faderPending else { return }
                self.stopFaderCapture()
                var s = self.strip(channel: ch)
                s.faderMIDI = v
                s.fader = (StripSheet.faderDB(midi: v) * 2).rounded() / 2
                self.setStrip(s, channel: ch)
                self.message = "Fader of channel \(ch) captured: MIDI \(v)."
            }
        }
    }

    private func stopFaderCapture() {
        faderSettle?.invalidate(); faderTimeout?.invalidate()
        faderCapture = nil; faderPending = nil
        let c = midiClient
        DispatchQueue.global(qos: .utility).async { c.stopMonitor() }
    }

    // MARK: knob values typed by hand

    /// Estimates of the knob positions offered before anything is typed: the fit of the captured curve, by "curve#channel#checksum".
    @Published private(set) var estimates: [String: EQSettings] = [:]

    /// The curve whose knobs are being typed: the one just captured, else the one of the target.
    private func editedCurve(_ ch: Int) -> (key: String, curve: EQCurve)? {
        let k = String(ch)
        if let c = working.channels[k] { return ("w#\(ch)#\(Int(c.db.reduce(0, +) * 100))", c) }
        if let c = target?.channels[k] { return ("\(targetName ?? "")#\(ch)#\(Int(c.db.reduce(0, +) * 100))", c) }
        return nil
    }

    var editsWorkingCapture: Bool { working.channels[String(channel)] != nil }

    func manual(channel ch: Int) -> ManualEQ { (editsWorkingCapture ? working.manual[String(ch)] : target?.manual[String(ch)]) ?? ManualEQ() }
    func strip(channel ch: Int) -> StripSheet { (editsWorkingCapture ? working.strips[String(ch)] : target?.strips[String(ch)]) ?? StripSheet() }
    func setManual(_ m: ManualEQ, channel ch: Int) { edit(ch) { $0.manual[String(ch)] = m.isEmpty ? nil : m } }
    func setStrip(_ s: StripSheet, channel ch: Int) { edit(ch) { $0.strips[String(ch)] = s.isEmpty ? nil : s } }

    /// Development only (`--render-strip`): a capture of channel 1 with a few settings typed, to draw the strip.
    func loadPreview() {
        working.channels["1"] = EQCurve(freq: EQMeasure.grid, db: EQMeasure.grid.map { _ in 0 })
        var m = ManualEQ(); m.hf = 4; m.hmfGain = -3; m.hmfFreq = 3000; m.hmfQ = 2; m.lmfGain = 6; m.lmfFreq = 180; m.lf = -2
        var s = StripSheet(); s.gain = 34; s.line = false; s.phantom = true; s.hpf = true; s.aux[0] = 0; s.aux[2] = -12; s.pan = -30; s.routeLR = true; s.mute = false; s.fader = -6; s.eqIn = true
        working.manual["1"] = m; working.strips["1"] = s
    }

    /// True when the channel has a capture (just made, or the target's) to keep the settings with.
    func canNote(channel ch: Int) -> Bool { working.channels[String(ch)] != nil || target?.channels[String(ch)] != nil }

    private var saveTask: Task<Void, Never>?

    /// Changes the capture the settings of the channel belong to: the one being made, else the target. The target is changed in memory at once (the
    /// knobs are dragged) and written to its file a moment after the last change.
    private func edit(_ ch: Int, _ change: (inout EQCapture) -> Void) {
        let k = String(ch)
        if working.channels[k] != nil { change(&working); return }
        guard let i = captures.firstIndex(where: { $0.name == targetName }), captures[i].channels[k] != nil else { return }
        var c = captures[i]; change(&c); captures[i] = c
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, let i = self.captures.firstIndex(where: { $0.name == c.name }) else { return }
            if !self.captures[i].save() { self.message = "Could not save the settings." }
        }
    }

    /// The estimate of the knobs for the channel being edited, nil until the fit is done (it needs the flat reference of the channel).
    func estimate(channel ch: Int) -> EQSettings? { editedCurve(ch).flatMap { estimates[$0.key] } }

    func requestEstimate(channel ch: Int) {
        guard let (key, curve) = editedCurve(ch), estimates[key] == nil, let flat = references.channels[String(ch)], let rel = curve.relative(to: flat) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let fit = EQFit.fit(freq: rel.freq, db: rel.db)
            DispatchQueue.main.async { self.estimates[key] = fit }
        }
    }

    /// How far (dB rms) the typed values, completed by the estimate, are from the captured curve: a way to catch a typing error.
    func manualResidual(channel ch: Int) -> Double? {
        let m = manual(channel: ch)
        guard !m.isEmpty, let est = estimate(channel: ch), let (_, curve) = editedCurve(ch), let flat = references.channels[String(ch)], let rel = curve.relative(to: flat) else { return nil }
        let s = m.settings(fallback: est)
        let sum = zip(rel.freq, rel.db).reduce(0.0) { $0 + pow(EQFit.response(s, at: $1.0) - $1.1, 2) }
        return (sum / Double(rel.freq.count)).squareRoot()
    }

    // MARK: capture

    private func startCapture(channels: [Int], reference: Bool) {
        capturingReference = reference
        if !reference { working = EQCapture(name: working.name, rate: 48000, channels: working.channels, manual: working.manual, strips: working.strips) }
        allQueue = channels
        mode = channels.count > 1 ? .capturingAll : .capturingOne
        progress = 0
        if !reference { startFaderWatch() }
        runNextCapture(total: channels.count)
    }

    /// All the channels at once: one noise per channel (different seeds), every send recorded together, then one analysis per channel.
    private func runNextCapture(total: Int) {
        let list = allQueue
        guard let first = list.first else { finishCapture(); return }
        channel = first; live = nil; accuracy = nil
        do { try engine.start(channels: list) } catch { message = "Cannot start the measurement: \(error)"; stop(); return }
        working.rate = engine.rate
        message = (capturingReference ? "Reference of " : "Capturing ") + (list.count == 1 ? "channel \(first)…" : "\(list.count) channels…")
        let needed = EQMeasure.period * 3                              // 2 whole noise periods after the fade in: about 4 s at 48 kHz
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, self.mode != .idle else { t.invalidate(); return }
                self.progress = min(1, Double(self.engine.recordedFrames) / Double(needed + 8192)) * 0.9
                guard self.engine.recordedFrames >= needed + 8192 else { return }
                t.invalidate()
                let rate = self.engine.rate
                let recs = list.compactMap { ch in self.engine.recent(frames: EQMeasure.period * 2, channel: ch).map { (ch, $0) } }
                self.message = "Analysing…"
                DispatchQueue.global(qos: .userInitiated).async {
                    // a send that comes back below -80 dBFS (the noise is played at -36) has no A+B pressed: nothing was measured
                    let silent = recs.filter { _, rec in (rec.reduce(0) { $0 + Double($1 * $1) } / Double(rec.count)).squareRoot() < 1e-4 }.map { $0.0 }
                    let curves: [(Int, EQCurve)] = recs.filter { !silent.contains($0.0) }.compactMap { ch, rec in
                        EQMeasure.curve(recorded: rec, reference: EQMeasure.pinkPeriod(seed: UInt64(ch), rate: rate), rate: rate, maxPeriods: 2).map { (ch, $0) }
                    }
                    DispatchQueue.main.async {
                        guard self.mode != .idle else { return }
                        for (ch, c) in curves {
                            if self.capturingReference { self.references.channels[String(ch)] = c; self.references.rate = rate }
                            else { self.working.channels[String(ch)] = c }
                            self.live = c
                        }
                        self.allQueue = []
                        self.silentChannels = silent
                        self.engine.stop { Task { @MainActor in self.finishCapture() } }
                    }
                }
            }
        }
    }

    private func finishCapture() {
        timer?.invalidate(); timer = nil
        mode = .idle; progress = nil
        let noted = applyFadersSeen()
        let silent = silentChannels; silentChannels = []
        let warning = silent.isEmpty ? "" : " No signal on channel\(silent.count > 1 ? "s" : "") \(Self.ranges(silent)): press A and B on \(silent.count > 1 ? "them" : "it")."
        if capturingReference {
            capturingReference = false; targetFits = [:]
            message = (references.save() ? "Reference saved for \(references.channels.count) channel(s)." : "Could not save the reference.") + warning
        } else {
            message = "Capture of \(working.channels.count) channel(s) ready: give it a name and save it." + (noted > 0 ? " Fader level noted for \(noted) channel(s)." : " No fader moved or touched: touch a fader (WRITE on) to note its level.") + warning
        }
    }

    /// 2, 3, 4, 7 -> "2-4, 7"
    static func ranges(_ list: [Int]) -> String {
        var out: [String] = [], i = 0
        let l = list.sorted()
        while i < l.count {
            var j = i
            while j + 1 < l.count && l[j + 1] == l[j] + 1 { j += 1 }
            out.append(j > i ? "\(l[i])-\(l[j])" : "\(l[i])")
            i = j + 1
        }
        return out.joined(separator: ", ")
    }

    func saveWorking() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !working.channels.isEmpty else { return }
        var c = working; c.name = name; c.date = Date()
        if c.save() {
            captures = EQCapture.loadAll(); targetName = name
            message = "Saved “\(name)”."
            working = EQCapture(name: "", rate: c.rate)
        } else { message = "Could not save the capture." }
    }

    var workingCount: Int { working.channels.count }
}
