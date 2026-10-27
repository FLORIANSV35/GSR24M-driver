import SwiftUI
import GSRCore

/// What the Bus tab watches: rates computed from the daemon's counters, the CPU of the daemon, and the state of the console link. A fault keeps its
/// red light for a while after it happened, so that it is seen even when nobody was looking at the screen.
final class LoadMonitor: ObservableObject {
    struct Reading {
        var inLate = 0.0, outLate = 0.0            // frames a second
        var errors = 0.0                           // CIP errors and DBC jumps a second
        var midiOut = [0.0, 0.0, 0.0], midiIn = [0.0, 0.0, 0.0]      // bytes a second, by card port
        var midiDrops = 0.0                        // bytes a second thrown away by the daemon
    }
    enum Fault: String, CaseIterable { case daemon = "Daemon", streaming = "Audio stream", clock = "Clock lock", packets = "Packet errors", lateIn = "Late input",
        lateOut = "Late output", busReset = "Bus reset", midiDrops = "MIDI overflow", consoleQueue = "Console MIDI queue" }

    @Published private(set) var reading = Reading()
    @Published private(set) var busPercent: Double?
    @Published private(set) var cpu: Double?
    @Published private(set) var agent: AgentStatus?
    @Published private(set) var faults: [Fault: Date] = [:]         // when each fault was last seen
    @Published private(set) var now = Date()
    /// What happened and when, newest first (the last 30 events).
    @Published private(set) var journal: [(time: Date, text: String)] = []

    static let holdSeconds = 30.0
    private var previous: (info: DaemonInfo, time: Date)?
    private var previousAgent: AgentStatus?
    private var sampling = false
    private let client = AgentClient()

    func active(_ f: Fault) -> Bool { faults[f].map { now.timeIntervalSince($0) < Self.holdSeconds } ?? false }
    /// True while the fault is happening right now (the light is lit solid, not fading).
    func current(_ f: Fault) -> Bool { faults[f].map { now.timeIntervalSince($0) < 2.5 } ?? false }

    private func raise(_ f: Fault, _ at: Date, _ detail: String? = nil) {
        if let d = detail, !current(f) {                                  // one line per episode, not one per second
            journal.insert((at, d), at: 0)
            if journal.count > 30 { journal.removeLast() }
        }
        faults[f] = at
    }

    func update(_ info: DaemonInfo?) {
        let at = Date(); now = at
        guard let i = info else { raise(.daemon, at, "The gsrd daemon does not answer"); previous = nil; busPercent = nil; return }
        busPercent = Load.busPercent(i)
        if !i.isStreaming { raise(.streaming, at, "Audio streaming stopped") }
        if i.haveCard, i.locked == false { raise(.clock, at, "The card is not locked to its clock") }
        if let p = previous {
            let dt = at.timeIntervalSince(p.time)
            var r = Reading()
            r.inLate = Load.rate(p.info.inLate, i.inLate, seconds: dt)
            r.outLate = Load.rate(p.info.outLate, i.outLate, seconds: dt)
            r.errors = Load.rate(p.info.cipErrors + p.info.dbcJumps, i.cipErrors + i.dbcJumps, seconds: dt)
            if let m = i.midi, let pm = p.info.midi {
                for k in 0..<3 where k < m.out.count && k < pm.out.count { r.midiOut[k] = Load.rate(pm.out[k], m.out[k], seconds: dt) }
                for k in 0..<3 where k < m.inBytes.count && k < pm.inBytes.count { r.midiIn[k] = Load.rate(pm.inBytes[k], m.inBytes[k], seconds: dt) }
                r.midiDrops = Load.rate(pm.inDrops + pm.outDrops, m.inDrops + m.outDrops, seconds: dt)
            }
            reading = r
            if r.errors > 0 { raise(.packets, at, "Packet errors (\(Int(r.errors * dt)) in \(Int(dt)) s)") }
            if r.inLate > 0 { raise(.lateIn, at, "Late input: \(Int(r.inLate * dt)) frames, longest send gap \(String(format: "%.1f", i.maxGapMs)) ms") }
            if r.outLate > 0 { raise(.lateOut, at, "Late output: \(Int(r.outLate * dt)) frames, \(i.ioClients) audio application(s), longest send gap \(String(format: "%.1f", i.maxGapMs)) ms") }
            if r.midiDrops > 0 { raise(.midiDrops, at, "MIDI bytes dropped by the daemon") }
            if i.busResets > p.info.busResets { raise(.busReset, at, "FireWire bus reset") }
        }
        previous = (i, at)
        sampleSlow()
    }

    /// The CPU of the daemon and the state of the MIDI agent change slowly: asked in the background.
    private func sampleSlow() {
        guard !sampling else { return }
        sampling = true
        let c = client
        DispatchQueue.global(qos: .utility).async {
            let cpu = LoadMonitor.daemonCPU()
            let st = c.status()
            DispatchQueue.main.async {
                self.sampling = false
                self.cpu = cpu
                if let st {
                    if let p = self.previousAgent, st.dropped > p.dropped { self.raise(.consoleQueue, Date(), "Console MIDI: \(st.dropped - p.dropped) message(s) dropped by the rate limit") }
                    self.previousAgent = st
                }
                self.agent = st
            }
        }
    }

    nonisolated static func daemonCPU() -> Double? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-A", "-o", "%cpu=,comm="]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasSuffix("/gsrd") || t.hasSuffix(" gsrd"), let first = t.split(separator: " ").first, let v = Double(first) else { continue }
            return v
        }
        return nil
    }
}

// MARK: views

/// A bar with its zones: green, orange where it gets close, red where it is critical, and a marker for the value.
struct GaugeBar: View {
    let title: String
    let value: Double
    let maximum: Double
    let warning: Double
    let critical: Double
    let text: String

    private var level: Load.Level { Load.level(value, warning: warning, critical: critical) }
    private var colour: Color { level == .critical ? .red : level == .warning ? .orange : .green }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(colour).frame(width: 9, height: 9).shadow(color: level == .critical ? .red : .clear, radius: 4)
                Text(title).font(.callout).foregroundStyle(.white)
                Spacer()
                Text(text).font(.callout.monospacedDigit().bold()).foregroundStyle(level == .critical ? Color.red : .white)
            }
            GeometryReader { g in
                let w = g.size.width
                let x = { (v: Double) in CGFloat(min(max(v / maximum, 0), 1)) * w }
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {                                           // the zones
                        Rectangle().fill(Color.green.opacity(0.28)).frame(width: x(warning))
                        Rectangle().fill(Color.orange.opacity(0.35)).frame(width: x(critical) - x(warning))
                        Rectangle().fill(Color.red.opacity(0.55)).frame(width: w - x(critical))
                    }
                    Rectangle().fill(colour).frame(width: max(2, x(value)), height: 6).frame(maxHeight: .infinity, alignment: .center)   // the level
                    Rectangle().fill(Color.white).frame(width: 2).offset(x: x(value) - 1)                                                  // the marker
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 12)
        }
    }
}

/// A light that is red while a fault is happening, stays dim red for a while after, and is green when all is well.
struct FaultLamp: View {
    let title: String
    let happening: Bool
    let recent: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(happening ? Color.red : recent ? Color.red.opacity(0.45) : Color.green.opacity(0.8))
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.white.opacity(happening ? 0.9 : 0.25), lineWidth: 1))
                .shadow(color: happening ? .red : .clear, radius: 7)
            Text(title).font(.callout).foregroundStyle(happening ? Color.red : .white)
        }
    }
}

struct LoadPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var load: LoadMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Load").font(.headline).foregroundStyle(.white)
            if let i = model.live {
                faults
                Divider()
                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        GaugeBar(title: "FireWire bus (isochronous)", value: load.busPercent ?? 0, maximum: 100, warning: 60, critical: 85,
                                 text: load.busPercent.map { String(format: "%.0f %%", $0) } ?? "—")
                        GaugeBar(title: "Longest send gap", value: i.maxGapMs, maximum: 20, warning: 6, critical: 10, text: String(format: "%.1f ms", i.maxGapMs))
                    }
                    GridRow {
                        GaugeBar(title: "Daemon CPU", value: load.cpu ?? 0, maximum: 100, warning: 50, critical: 80, text: load.cpu.map { String(format: "%.0f %%", $0) } ?? "—")
                        GaugeBar(title: "Late frames a second", value: load.reading.inLate + load.reading.outLate, maximum: 200, warning: 1, critical: 50,
                                 text: String(format: "%.0f in · %.0f out", load.reading.inLate, load.reading.outLate))
                    }
                    GridRow {
                        GaugeBar(title: "Console MIDI out (card port 1)", value: pct(load.reading.midiOut[0]), maximum: 100, warning: 50, critical: 80,
                                 text: String(format: "%.0f %%", pct(load.reading.midiOut[0])))
                        GaugeBar(title: "Console MIDI in (card port 1)", value: pct(load.reading.midiIn[0]), maximum: 100, warning: 50, critical: 80,
                                 text: String(format: "%.0f %%", pct(load.reading.midiIn[0])))
                    }
                    if let a = load.agent {
                        GridRow {
                            GaugeBar(title: "Console MIDI queue", value: Double(a.queued), maximum: 200, warning: 40, critical: 120, text: "\(a.queued) waiting (peak \(a.peakQueued))")
                            Text("Rate limit: \(a.coalesced) messages replaced, \(a.dropped) dropped.").font(.callout).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
                if !load.journal.isEmpty {
                    Text("Journal").font(.callout.bold()).foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(load.journal.prefix(12).enumerated()), id: \.offset) { _, e in
                            Text("\(e.time.formatted(date: .omitted, time: .standard))  \(e.text)").font(.caption.monospaced()).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                Text("Red zone: the audio or the MIDI is at risk. The red lights stay on for \(Int(LoadMonitor.holdSeconds)) s after a fault.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            } else {
                FaultLamp(title: "The gsrd daemon does not answer", happening: true, recent: true)
            }
        }
        .padding(10)
        .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 8))
    }

    private func pct(_ bytesPerSecond: Double) -> Double { bytesPerSecond / Load.midiWire * 100 }

    private var faults: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(LoadMonitor.Fault.allCases, id: \.self) { f in
                FaultLamp(title: f.rawValue, happening: load.current(f), recent: load.active(f))
            }
        }
    }
}
