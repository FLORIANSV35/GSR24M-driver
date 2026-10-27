import SwiftUI
import AppKit
import GSRCore

struct MIDIView: View {
    @EnvironmentObject var model: MIDIModel
    @State private var exploring = false
    var scrollStrips = true                    // false only for the preview image, which cannot draw scroll views

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.settings.mode == .protools {
                HStack(alignment: .top, spacing: 10) {
                    SelBanks()
                    if scrollStrips {
                        ScrollView(.horizontal, showsIndicators: false) { SurfaceBlock(cells: SurfaceLayout.strips, size: SurfaceLayout.stripsSize, unit: 31) }
                    } else {
                        SurfaceBlock(cells: SurfaceLayout.strips, size: SurfaceLayout.stripsSize, unit: 31)
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    SurfaceBlock(cells: SurfaceLayout.controls, size: SurfaceLayout.controlsSize, unit: 36)
                    Inspector()
                }
            } else {
                legacy
            }
            Monitor()
        }
        .onAppear { model.start() }
        .sheet(isPresented: $exploring) { HUIExplorer() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Picker("", selection: $model.settings.mode) {
                ForEach(MIDIMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
            chip("MIDI agent", model.status != nil)
            chip("Card MIDI", model.status?.card ?? false)
            if model.settings.mode == .protools, model.status != nil, model.status?.accessibility == false {
                Button("Allow keyboard shortcuts") { model.askAccessibility() }
            }
            Spacer()
            if model.settings.mode == .protools {
                Button("Explore HUI…") { exploring = true }
                Button("Defaults") { model.restoreDefaults() }
            }
        }
    }

    private func chip(_ title: String, _ ok: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 9, height: 9)
            Text(title).font(.callout).foregroundStyle(.white)
        }
    }

    private var legacy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GS-R24M MIDI 1, 2 and 3").font(.headline).foregroundStyle(.white)
            Text("The three MIDI ports of the card, unchanged.").font(.callout).foregroundStyle(.white.opacity(0.85))
        }.padding(.vertical, 6)
    }
}

// MARK: surface

struct SurfaceBlock: View {
    @EnvironmentObject var model: MIDIModel
    let cells: [SurfaceCell]
    let size: (width: Double, height: Double)
    let unit: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.16))
            ForEach(cells) { cell in
                CellView(cell: cell, unit: unit)
                    .frame(width: cell.w * unit, height: cell.h * unit)
                    .position(x: (cell.x + cell.w / 2) * unit + 8, y: (cell.y + cell.h / 2) * unit + 8)
            }
        }
        .frame(width: size.width * unit + 16, height: size.height * unit + 16)
    }
}

struct CellView: View {
    @EnvironmentObject var model: MIDIModel
    let cell: SurfaceCell
    let unit: Double

    private var selected: Bool { model.selected == cell.control }
    private var bindable: Bool { cell.control.isBindable }

    var body: some View {
        ZStack {
            shape
            if !cell.label.isEmpty { Text(cell.label).font(.system(size: max(8, unit * 0.3), weight: .semibold)).foregroundStyle(cell.shape == .pot ? Color.white : Color(white: 0.1)) }
        }
        .overlay(alignment: .topTrailing) {
            if bindable && model.isBound(cell.control) { Circle().fill(Color.green).frame(width: 7, height: 7).offset(x: 3, y: -3) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selected = cell.control; if !bindable { model.layer = .plain } }
        .help(cell.control.title)
    }

    @ViewBuilder private var shape: some View {
        let ring = selected ? Color.orange : Color.black.opacity(0.45)
        switch cell.shape {
        case .button:
            RoundedRectangle(cornerRadius: 4).fill(Color(white: selected ? 0.95 : 0.78))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(ring, lineWidth: selected ? 3 : 1))
        case .strip:
            RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.06))
                .overlay(alignment: .bottom) { RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.7)).frame(height: 14).padding(.bottom, 28) }
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(ring, lineWidth: selected ? 3 : 1))
        case .pot:
            Circle().fill(Color(white: 0.25)).overlay(Circle().stroke(ring, lineWidth: selected ? 3 : 1))
        case .wheel:
            Circle().fill(RadialGradient(colors: [Color(white: 0.3), Color(white: 0.08)], center: .center, startRadius: 4, endRadius: unit * 1.6))
                .overlay(Circle().stroke(ring, lineWidth: selected ? 3 : 1))
        }
    }
}

struct SelBanks: View {
    @EnvironmentObject var model: MIDIModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SEL BANKS").font(.callout.bold()).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("bank 1").font(.caption).foregroundStyle(.white.opacity(0.75))
                picker($model.settings.protools.plainLayer)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("bank 2 - shift").font(.caption).foregroundStyle(.white.opacity(0.75))
                picker($model.settings.protools.shiftLayer)
            }
        }
        .padding(10)
        .frame(width: 170, alignment: .topLeading)
        .background(Color(white: 0.28), in: RoundedRectangle(cornerRadius: 8))
    }

    private func picker(_ b: Binding<ChannelFunction>) -> some View {
        Picker("", selection: b) { ForEach(ChannelFunction.allCases.filter { $0 != .touch }, id: \.self) { Text($0.title).tag($0) } }.labelsHidden()
    }
}

// MARK: inspector

struct Inspector: View {
    @EnvironmentObject var model: MIDIModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let c = model.selected {
                Text(c.title).font(.title3.bold()).foregroundStyle(.white)
                codes(c)
                if c.isBindable { binding(c) } else { fixed(c) }
            } else {
                Text("Click a control").font(.title3.bold()).foregroundStyle(.white)
            }
            Divider()
            learn
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(Color(white: 0.28), in: RoundedRectangle(cornerRadius: 8))
    }

    private func codes(_ c: ConsoleControl) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.codes(of: c).enumerated()), id: \.offset) { _, e in
                Text("\(e.0)\(e.1 == .shift ? "  (Shift)" : "")").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func functionPicker(_ b: Binding<ChannelFunction>) -> some View {
        Picker("", selection: b) { ForEach(ChannelFunction.allCases.filter { $0 != .touch }, id: \.self) { Text($0.title).tag($0) } }.labelsHidden()
    }

    @ViewBuilder private func binding(_ c: ConsoleControl) -> some View {
        let sel = c.id.hasPrefix("sel.")
        VStack(alignment: .leading, spacing: 6) {
            if !sel {
                Picker("", selection: $model.layer) { Text("Plain").tag(Layer.plain); Text("With Shift").tag(Layer.shift) }
                    .pickerStyle(.segmented).labelsHidden()
            }
            ActionEditor(action: Binding(get: { model.action(c, sel ? .plain : model.layer) }, set: { model.setAction($0, c, sel ? .plain : model.layer) }),
                         kinds: Action.kinds(for: c), followsLayers: sel)
        }
    }

    private func fixed(_ c: ConsoleControl) -> some View {
        Text(c.isFader ? "Moves the matching HUI fader." : c.id == "jog.wheel" ? "Steps or scrub, see the SHIFT + ST1 binding." : "Not used in Pro Tools mode.")
            .font(.callout).foregroundStyle(.white.opacity(0.8))
    }

    private var learn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(model.learning ? "Cancel" : "Learn") { model.learning ? model.cancelLearning() : model.startLearning() }
                if model.unknownCode != nil, model.selected != nil { Button("Assign to \(model.selected!.title)") { model.assignUnknown() } }
            }
            if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.white.opacity(0.9)) }
        }
    }
}

struct ActionEditor: View {
    @EnvironmentObject var model: MIDIModel
    @State private var newName = ""
    @Binding var action: Action
    let kinds: [ActionKind]
    var followsLayers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Binding(get: { action.kind }, set: { if $0 != action.kind { action = Action.starting($0) } })) {
                ForEach(kinds) { Text(followsLayers && $0 == .channel ? "Follows the banks" : $0.title).tag($0) }
            }.labelsHidden()
            switch action {
            case .hui(let z, let p): hui(zone: z, port: p, pulse: false)
            case .huiPulse(let z, let p): hui(zone: z, port: p, pulse: true)
            case .channel(let f): if !followsLayers { Picker("Function", selection: Binding(get: { f }, set: { action = .channel($0) })) { ForEach(ChannelFunction.allCases, id: \.self) { Text($0.title).tag($0) } } }
            case .setLayer(let l, let f): setLayer(l, f)
            case .key(let k): key(k)
            default: EmptyView()
            }
        }.foregroundStyle(.white)
    }

    private func hui(zone: UInt8, port: UInt8, pulse: Bool) -> some View {
        let current = HUISwitch(zone: zone, port: port)
        let entries = model.catalog
        let known = entries.first { $0.target == current }
        let title = known?.title ?? "Custom"
        let make: (UInt8, UInt8, Bool) -> Action = { z, p, pl in pl ? .huiPulse(zone: z, port: p) : .hui(zone: z, port: p) }
        let groups = entries.reduce(into: [(String, [HUICatalog.Entry])]()) { acc, e in
            if let i = acc.firstIndex(where: { $0.0 == e.group }) { acc[i].1.append(e) } else { acc.append((e.group, [e])) }
        }
        return VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: Binding(get: { title }, set: { t in
                if let e = entries.first(where: { $0.title == t }) { action = make(e.target.zone, e.target.port, pulse) }
                else { action = make(zone, port, pulse) }
            })) {
                ForEach(groups, id: \.0) { g in
                    Section(g.0) { ForEach(g.1, id: \.title) { Text($0.verified ? $0.title : $0.title + " (to verify)").tag($0.title) } }
                }
                Text("Custom").tag("Custom")
            }.labelsHidden()
            if title == "Custom" {
                Stepper("Zone 0x\(String(format: "%02X", zone))", value: Binding(get: { Int(zone) }, set: { action = make(UInt8($0), port, pulse) }), in: 0...0x1F)
                Stepper("Port \(port)", value: Binding(get: { Int(port) }, set: { action = make(zone, UInt8($0), pulse) }), in: 0...7)
                HStack {
                    TextField("name", text: $newName).frame(width: 120)
                    Button("Save") { model.saveUserSwitch(name: newName, current); newName = "" }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else if known?.verified == false {
                Text("Not tried yet: use Test and watch Pro Tools.").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Test in Pro Tools") { model.testHUI(current) }
                Toggle("Press and release at once", isOn: Binding(get: { pulse }, set: { action = make(zone, port, $0) }))
            }
        }
    }

    private func setLayer(_ l: Layer, _ f: ChannelFunction) -> some View {
        HStack {
            Picker("", selection: Binding(get: { l }, set: { action = .setLayer($0, f) })) { Text("BANK 1").tag(Layer.plain); Text("BANK 2").tag(Layer.shift) }.labelsHidden().frame(width: 90)
            Picker("", selection: Binding(get: { f }, set: { action = .setLayer(l, $0) })) { ForEach(ChannelFunction.allCases.filter { $0 != .touch }, id: \.self) { Text($0.title).tag($0) } }.labelsHidden()
        }
    }

    private func key(_ k: KeyShortcut) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu(ProToolsKeys.title(of: k).map { "Pro Tools: " + $0 } ?? "Pro Tools shortcuts…") {
                ForEach(Array(Set(ProToolsKeys.presets.map(\.group))).sorted(), id: \.self) { g in
                    Section(g) { ForEach(ProToolsKeys.presets.filter { $0.group == g }, id: \.title) { p in Button(p.title) { action = .key(p.shortcut) } } }
                }
            }
            HStack {
                TextField("key", text: Binding(get: { k.key }, set: { var n = k; n.key = $0.lowercased(); action = .key(n) })).frame(width: 90)
                if KeyInjector.keyCode(k.key) == nil { Text("unknown key").font(.caption).foregroundStyle(.orange) }
            }
            HStack {
                Toggle("⇧", isOn: Binding(get: { k.shift }, set: { var n = k; n.shift = $0; action = .key(n) }))
                Toggle("⌃", isOn: Binding(get: { k.control }, set: { var n = k; n.control = $0; action = .key(n) }))
                Toggle("⌥", isOn: Binding(get: { k.option }, set: { var n = k; n.option = $0; action = .key(n) }))
                Toggle("⌘", isOn: Binding(get: { k.command }, set: { var n = k; n.command = $0; action = .key(n) }))
            }.toggleStyle(.button)
        }
    }
}

// MARK: monitor

struct Monitor: View {
    @EnvironmentObject var model: MIDIModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.traffic.suffix(6)) { line in
                HStack(spacing: 8) {
                    Text(line.direction).frame(width: 90, alignment: .leading)
                    Text(line.text)
                }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.75))
            }
            if model.traffic.isEmpty { Text(model.status == nil ? "MIDI agent not running" : "No MIDI yet").font(.caption).foregroundStyle(.white.opacity(0.6)) }
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
        .padding(8).background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: preview image (development: `GSRApp --render-midi file.png`)

@MainActor
enum MIDIPreview {
    static func render(to path: String) {
        let model = MIDIModel()
        model.settings.mode = .protools
        model.selected = .arrowCentre
        let view = MIDIView(scrollStrips: false).environmentObject(model).padding(12).frame(width: 900).background(Theme.panel).preferredColorScheme(.dark)
        let r = ImageRenderer(content: view); r.scale = 2
        if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: HUI explorer

/// Every zone and port of the HUI: a click presses and releases that switch in Pro Tools, to find out what it does. What is found can be named
/// and then appears in the choice menus.
struct HUIExplorer: View {
    @EnvironmentObject var model: MIDIModel
    @Environment(\.dismiss) private var dismiss
    @State private var picked: HUISwitch?
    @State private var name = ""

    private func status(_ s: HUISwitch) -> Color {
        if model.settings.userSwitches.contains(where: { $0.target == s }) { return .blue }
        guard let e = HUICatalog.entries.first(where: { $0.target == s }) else { return Color(white: 0.45) }
        return e.verified ? .green : .yellow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("HUI explorer").font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Pro Tools must be open with the HUI peripherals set to GS-R24M HUI 1 to 3. Click a switch to press it, watch what happens, then name it.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                legend(.green, "known"); legend(.yellow, "to verify"); legend(.blue, "named by you"); legend(Color(white: 0.45), "unknown")
            }.font(.caption)
            ScrollView {
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    GridRow {
                        Text("zone").font(.caption).frame(width: 44, alignment: .leading)
                        ForEach(0..<8, id: \.self) { Text("\($0)").font(.caption).frame(width: 30) }
                    }
                    ForEach(0..<0x20, id: \.self) { z in
                        GridRow {
                            Text(String(format: "0x%02X", z)).font(.system(size: 11, design: .monospaced)).frame(width: 44, alignment: .leading)
                            ForEach(0..<8, id: \.self) { p in
                                let s = HUISwitch(zone: UInt8(z), port: UInt8(p))
                                Button { picked = s; name = HUICatalog.title(of: s, user: model.settings.userSwitches) ?? ""; model.testHUI(s) } label: {
                                    RoundedRectangle(cornerRadius: 3).fill(status(s)).frame(width: 30, height: 20)
                                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(picked == s ? Color.orange : Color.clear, lineWidth: 2))
                                }.buttonStyle(.plain)
                                .help(HUICatalog.title(of: s, user: model.settings.userSwitches) ?? "unknown")
                            }
                        }
                    }
                }
            }
            if let s = picked {
                HStack {
                    Text(String(format: "Zone 0x%02X, port %d", s.zone, s.port)).font(.callout.bold())
                    TextField("name it", text: $name).frame(width: 220)
                    Button("Save") { model.saveUserSwitch(name: name, s) }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    if model.settings.userSwitches.contains(where: { $0.target == s }) { Button("Forget") { model.removeUserSwitch(s) } }
                }
            }
            if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(16).frame(width: 520, height: 640)
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 12, height: 10); Text(t) }
    }
}
