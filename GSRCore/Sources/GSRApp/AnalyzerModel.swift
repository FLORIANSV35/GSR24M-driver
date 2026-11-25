import SwiftUI
import AppKit
import AVFoundation
import AudioToolbox
import GSRCore

/// Holds a plug-in's own view. It stays the same object when the tab is left and entered again, and when the plug-in is moved to a window and back.
final class PluginHostView: NSView {
    private(set) var plugin: NSView?
    var onResize: ((NSSize) -> Void)?

    func clear() { plugin?.removeFromSuperview(); plugin = nil }

    func host(_ v: NSView) {
        plugin?.removeFromSuperview()
        plugin = v
        v.translatesAutoresizingMaskIntoConstraints = true
        v.autoresizingMask = []
        v.setFrameOrigin(.zero)
        addSubview(v)
        v.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: v, queue: .main) { [weak self] _ in
            if let s = self?.plugin?.frame.size { self?.onResize?(s) }
        }
    }
    override var isFlipped: Bool { true }
}

struct PluginHost: NSViewRepresentable {
    let view: PluginHostView
    func makeNSView(context: Context) -> PluginHostView { view }
    func updateNSView(_ nsView: PluginHostView, context: Context) {}
}

@MainActor
final class AnalyzerItem: NSObject, ObservableObject, Identifiable, NSWindowDelegate {
    let slot: AnalyzerSlot
    let host = PluginHostView()
    @Published var size: CGSize
    @Published var detached = false
    @Published var load = 0.0
    @Published var error: String?
    private var window: NSWindow?
    let id: UUID

    init(slot: AnalyzerSlot, view: NSView) {
        self.slot = slot; id = slot.id
        let s = view.frame.size == .zero ? NSSize(width: 480, height: 240) : view.frame.size
        size = s
        super.init()
        view.setFrameSize(s)
        host.host(view)
        host.onResize = { [weak self] s in Task { @MainActor in self?.size = s } }
    }

    /// The plug-in's view is not moved from the tab to a window: a new view is made for the window and the old one is dropped, and the other way round when
    /// it comes back, as a DAW does. (Moving one view between windows made Apple's AUGraphicEQ view assert and take the application down.)
    func detach() async {
        guard !detached else { return }
        let v = await PluginView.make(for: slot.unit)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: v.frame.size == .zero ? size : v.frame.size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = slot.title
        w.isReleasedWhenClosed = false
        w.delegate = self
        host.clear()
        detached = true
        let content = NSView(frame: NSRect(origin: .zero, size: v.frame.size))
        v.setFrameOrigin(.zero)
        content.addSubview(v)
        w.contentView = content
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    func attach() async {
        guard detached else { return }
        let w = window
        window = nil
        w?.delegate = nil
        w?.contentView = NSView()
        w?.orderOut(nil)
        let v = await PluginView.make(for: slot.unit)
        host.host(v)
        size = v.frame.size == .zero ? size : v.frame.size
        detached = false
    }

    func windowWillClose(_ notification: Notification) { Task { @MainActor in await self.attach() } }

    func closeWindow() { window?.delegate = nil; window?.contentView = NSView(); window?.orderOut(nil); window = nil }
}

@MainActor
final class AnalyzerModel: ObservableObject {
    struct PluginInfo: Identifiable, Hashable {
        let key: String, title: String, maker: String
        let desc: AudioComponentDescription
        var id: String { key }
        static func == (a: PluginInfo, b: PluginInfo) -> Bool { a.key == b.key }
        func hash(into h: inout Hasher) { h.combine(key) }
    }

    static let maxSlots = 6
    private let defaults = UserDefaults.standard
    let engine = AnalyzerEngine()

    @Published var plugins: [PluginInfo] = []
    @Published var items: [AnalyzerItem] = []
    @Published var message = ""
    @Published var busy = false
    @Published var status = AnalyzerEngine.Status()
    @Published var source: RingTap.Source { didSet { defaults.set(source.rawValue, forKey: "analyzer.source"); route() } }
    @Published var left: Int { didSet { defaults.set(left, forKey: "analyzer.left"); route() } }
    @Published var right: Int { didSet { defaults.set(right, forKey: "analyzer.right"); route() } }

    private var restored = false
    private var timer: Timer?
    private var saveTimer: Timer?

    init() {
        source = RingTap.Source(rawValue: defaults.string(forKey: "analyzer.source") ?? "") ?? .consoleInputs
        left = defaults.object(forKey: "analyzer.left") as? Int ?? 0
        right = defaults.object(forKey: "analyzer.right") as? Int ?? 1
        engine.setRouting(source: source, left: left, right: right)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSlots() }
        }
    }

    private func route() { engine.setRouting(source: source, left: left, right: right) }

    // MARK: tab

    func appear() {
        refreshPlugins()
        engine.start()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.saveSlots() } }
        if !restored { restored = true; Task { await restore() } }
    }

    func disappear() {
        timer?.invalidate(); timer = nil
        saveSlots()
        if items.isEmpty { engine.stop() }
    }

    private func poll() {
        status = engine.snapshot()
        for i in items { i.load = i.slot.loadAverage; i.error = i.slot.error }
    }

    // MARK: plug-ins

    func refreshPlugins() {
        var all: [AVAudioUnitComponent] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let d = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            all += AVAudioUnitComponentManager.shared().components(matching: d)
        }
        plugins = all.map { PluginInfo(key: Self.key($0.audioComponentDescription), title: $0.name, maker: $0.manufacturerName, desc: $0.audioComponentDescription) }
            .sorted { ($0.maker, $0.title).0.localizedCaseInsensitiveCompare($1.maker) == .orderedAscending
                      || ($0.maker == $1.maker && $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending) }
    }

    static func key(_ d: AudioComponentDescription) -> String { "\(d.componentType)-\(d.componentSubType)-\(d.componentManufacturer)" }

    func add(_ info: PluginInfo, state: [String: Any]? = nil) async {
        guard items.count < Self.maxSlots else { message = "At most \(Self.maxSlots) plug-ins at the same time."; return }
        busy = true; defer { busy = false }
        message = "Loading \(info.title)…"
        do {
            let unit = try await AVAudioUnit.instantiate(with: info.desc, options: [])
            if let state { unit.auAudioUnit.fullState = state }
            let view = await PluginView.make(for: unit)
            let slot = AnalyzerSlot(key: info.key, title: info.title, unit: unit)
            let item = AnalyzerItem(slot: slot, view: view)
            engine.add(slot)
            items.append(item)
            message = ""
            saveSlots()
        } catch {
            message = "Could not load \(info.title): \(error.localizedDescription)"
        }
    }

    func remove(_ item: AnalyzerItem) {
        item.closeWindow()
        engine.remove(item.id)
        items.removeAll { $0.id == item.id }
        saveSlots()
        if items.isEmpty && timer == nil { engine.stop() }
    }

    // MARK: memory of what was mounted

    private func saveSlots() {
        let list: [[String: Any]] = items.map { i in
            var d: [String: Any] = ["key": i.slot.key]
            if let s = i.slot.unit.auAudioUnit.fullState, let data = try? PropertyListSerialization.data(fromPropertyList: s, format: .binary, options: 0) { d["state"] = data }
            return d
        }
        defaults.set(list, forKey: "analyzer.slots")
    }

    private func restore() async {
        guard let list = defaults.array(forKey: "analyzer.slots") as? [[String: Any]] else { return }
        for d in list {
            guard let key = d["key"] as? String, let info = plugins.first(where: { $0.key == key }) else { continue }
            var state: [String: Any]?
            if let data = d["state"] as? Data { state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] }
            await add(info, state: state)
        }
    }
}
