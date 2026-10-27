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
    @Published private(set) var suggestedKnob: EQGuide.Knob?         // the knob worth touching next, when none is being turned
    @Published private(set) var suggestedAmount: Double?             // which way: positive means clockwise

    private let engine = RecallEngine()
    private var timer: Timer?
    private var pending: Mode = .idle
    private var allQueue: [Int] = []
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

    private func resetKnobTracking() { activeKnob = nil; activeRemaining = nil; suggestedKnob = nil; suggestedAmount = nil; tracker.reset() }

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
                self.targetSettings = tgt == nil ? nil : ts
                self.message = tgt == nil ? "No stored curve for channel \(ch): choose a capture or make one." : ""
                self.tracker = knobTracker
                self.activeKnob = turned
                self.activeRemaining = turned == nil ? nil : remaining
                self.updateSuggestion(guidance, turning: turned != nil)
            }
        }
    }

    /// The suggested knob stays until another one is clearly more useful, so the advice does not jump about while the curve settles.
    private func updateSuggestion(_ g: EQGuide.Guidance?, turning: Bool) {
        guard !turning, let g else { suggestedKnob = nil; suggestedAmount = nil; return }
        let top = g.contributions.max() ?? 0
        if let cur = suggestedKnob, g.contributions[cur.rawValue] >= max(EQGuide.worthTouching, 0.6 * top) {
            suggestedAmount = g.amounts[cur.rawValue]
        } else {
            suggestedKnob = g.best
            suggestedAmount = g.best.map { g.amounts[$0.rawValue] }
        }
    }

    // MARK: capture

    private func startCapture(channels: [Int], reference: Bool) {
        capturingReference = reference
        if !reference { working = EQCapture(name: working.name, rate: 48000, channels: working.channels) }
        allQueue = channels
        mode = channels.count > 1 ? .capturingAll : .capturingOne
        progress = 0
        runNextCapture(total: channels.count)
    }

    private func runNextCapture(total: Int) {
        guard let ch = allQueue.first else { finishCapture(); return }
        channel = ch; live = nil; accuracy = nil
        do { try engine.start(channel: ch) } catch { message = "Cannot start the measurement: \(error)"; stop(); return }
        working.rate = engine.rate
        message = (capturingReference ? "Reference of channel " : "Capturing channel ") + "\(ch)…"
        let needed = EQMeasure.period * 5                              // five noise periods: about 7 s at 48 kHz
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, self.mode != .idle else { t.invalidate(); return }
                let done = total - self.allQueue.count
                self.progress = (Double(done) + min(1, Double(self.engine.recordedFrames) / Double(needed))) / Double(total)
                guard self.engine.recordedFrames >= needed + 8192, let rec = self.engine.recent(frames: EQMeasure.period * 3) else { return }
                t.invalidate()
                let ref = EQMeasure.pinkPeriod(seed: UInt64(ch), rate: self.engine.rate), rate = self.engine.rate
                if let c = EQMeasure.curve(recorded: rec, reference: ref, rate: rate, maxPeriods: 3) {
                    if self.capturingReference { self.references.channels[String(ch)] = c; self.references.rate = rate }
                    else { self.working.channels[String(ch)] = c }
                    self.live = c
                }
                self.allQueue.removeFirst()
                self.engine.stop { Task { @MainActor in self.runNextCapture(total: total) } }
            }
        }
    }

    private func finishCapture() {
        timer?.invalidate(); timer = nil
        mode = .idle; progress = nil
        if capturingReference {
            capturingReference = false; targetFits = [:]
            message = references.save() ? "Reference saved for \(references.channels.count) channel(s)." : "Could not save the reference."
        } else {
            message = "Capture of \(working.channels.count) channel(s) ready: give it a name and save it."
        }
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
