import SwiftUI
import GSRCore

/// Scale printed around a knob: value against angle (degrees from 12 o'clock, clockwise), by increasing value.
struct DialScale {
    let ticks: [(value: Double, angle: Double)]
    var log = false

    func angle(_ v: Double) -> Double {
        let c = min(ticks.last!.value, max(ticks[0].value, v))
        var i = 0
        while i < ticks.count - 2 && c > ticks[i + 1].value { i += 1 }
        let (a, b) = (ticks[i], ticks[i + 1])
        let t = log ? Foundation.log(c / a.value) / Foundation.log(b.value / a.value) : (c - a.value) / (b.value - a.value)
        return a.angle + t * (b.angle - a.angle)
    }

    func value(angle: Double) -> Double {
        let g = min(ticks.last!.angle, max(ticks[0].angle, angle))
        var i = 0
        while i < ticks.count - 2 && g > ticks[i + 1].angle { i += 1 }
        let (a, b) = (ticks[i], ticks[i + 1])
        let t = (g - a.angle) / (b.angle - a.angle)
        return log ? a.value * exp(t * Foundation.log(b.value / a.value)) : a.value + t * (b.value - a.value)
    }

    // The scales printed on the console (user guide p.11 to 14).
    static let gain = DialScale(ticks: [(-15, -135), (0, 0), (15, 135)])
    static let q = DialScale(ticks: [(0.8, -135), (6, 135)], log: true)
    static let hmfFreq = DialScale(ticks: [(400, -135), (700, -90), (1000, -45), (2000, 0), (4000, 45), (6000, 90), (18000, 135)], log: true)
    static let lmfFreq = DialScale(ticks: [(18, -135), (30, -90), (60, -45), (120, 0), (300, 45), (600, 90), (1000, 135)], log: true)
    static let micGain = DialScale(ticks: [(6, -135), (60, 135)])
    static let lineGain = DialScale(ticks: [(-14, -135), (40, 135)])
    /// Aux sends: off at the left stop, unity at the arrow, +6 at the right stop (the curve between is approximate; the number is what counts).
    static let aux = DialScale(ticks: [(-100, -135), (-60, -120), (-20, -60), (0, 60), (6, 135)])
    static let pan = DialScale(ticks: [(-100, -135), (100, 135)])
}

/// A knob drawn like the console's, turned with the mouse: drag in a circle round it, double-click to clear. An unset knob shows the estimate of the
/// app as a small marker; the number under it is what was set.
struct DialKnob: View {
    let label: String
    let scale: DialScale
    @Binding var value: Double?
    var estimate: Double? = nil
    var colour: Color = Color(white: 0.2)
    let format: (Double) -> String
    var snap: (Double) -> Double = { $0 }
    var size: CGFloat = 50
    // recall guidance around the knob (EQ knobs only): three arrows on each side, a green circle when it is in place
    var guided = false
    var amount: Double? = nil            // how far it still has to go (positive: clockwise), nil when there is nothing to say
    var tolerance = 0.0
    var active = false                   // the knob being turned
    var suggested = false                // the knob worth touching next

    @State private var drag: (pointer: Double, angle: Double)?

    private func pointerAngle(_ p: CGPoint) -> Double { atan2(p.x - size / 2, size / 2 - p.y) * 180 / .pi }

    private func point(_ deg: Double, _ r: Double, _ c: CGPoint) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: c.x + r * sin(a), y: c.y - r * cos(a))
    }

    private var level: Int? { amount.map { EQGuide.arrows($0, tolerance: tolerance) } }

    private func arrows(_ side: Int) -> some View {            // side: -1 left, +1 right; the first arrow is the one next to the knob
        let lit = (level ?? 0) > 0 && (amount ?? 0) * Double(side) > 0 ? (level ?? 0) : 0
        return HStack(spacing: -2) {
            ForEach(side < 0 ? [2, 1, 0] : [0, 1, 2], id: \.self) { i in
                Image(systemName: side < 0 ? "chevron.left" : "chevron.right").font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(i < lit ? Color.green : Color.white.opacity(0.14))
            }
        }.frame(width: 26)
    }

    var body: some View {
        HStack(spacing: 0) {                                                     // the arrows of the recall: three on each side of the knob
            if guided { arrows(-1).padding(.bottom, 24) }
            dial
            if guided { arrows(1).padding(.bottom, 24) }
        }
    }

    private var dial: some View {
        VStack(spacing: 1) {
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2), r = min(sz.width, sz.height) / 2 - 7
                let halo = CGRect(x: c.x - r - 4, y: c.y - r - 4, width: 2 * r + 8, height: 2 * r + 8)
                if active { ctx.stroke(Path(ellipseIn: halo), with: .color(.white), lineWidth: 2) }
                if suggested { ctx.stroke(Path(ellipseIn: halo), with: .color(.cyan), style: StrokeStyle(lineWidth: 2, dash: [3, 3])) }
                if level == 0 { ctx.stroke(Path(ellipseIn: halo.insetBy(dx: 1, dy: 1)), with: .color(.green), lineWidth: 4) }
                for t in scale.ticks {
                    var m = Path(); m.move(to: point(t.angle, r + 2, c)); m.addLine(to: point(t.angle, r + 5, c))
                    ctx.stroke(m, with: .color(.white.opacity(0.7)), lineWidth: 1.2)
                }
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(colour))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(value == nil ? Color(white: 0.4) : .orange), lineWidth: value == nil ? 1.5 : 2.5)
                if let v = value {
                    var line = Path(); line.move(to: point(scale.angle(v), r * 0.2, c)); line.addLine(to: point(scale.angle(v), r - 2, c))
                    ctx.stroke(line, with: .color(.orange), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                } else if let e = estimate {
                    let p = point(scale.angle(e), r + 7, c)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.cyan))
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let a = pointerAngle(g.location)
                    if drag == nil { drag = (a, scale.angle(value ?? estimate ?? scale.value(angle: 0))) }
                    var delta = a - drag!.pointer
                    if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }        // across the bottom of the knob
                    value = snap(scale.value(angle: min(135, max(-135, drag!.angle + delta))))
                }
                .onEnded { _ in drag = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = nil })
            Text(value.map(format) ?? (estimate.map { "≈ " + format($0) } ?? "—"))
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(value == nil ? Color.cyan.opacity(0.8) : .orange)
            Text(label).font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(width: size + 10)
        .help("Drag round the knob to turn it, double-click to clear")
    }
}

/// A push switch: click goes from "not noted" to on, to off, and back.
struct StateButton: View {
    let title: String
    @Binding var state: Bool?
    var width: CGFloat = 62

    var body: some View {
        Button { state = state == nil ? true : (state == true ? false : nil) } label: {
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 2).fill(state == true ? Color.green : (state == false ? Color(white: 0.12) : Color.clear))
                    .frame(width: 14, height: 5).overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.45), lineWidth: 1))
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            }
            .frame(width: width, height: 34)
            .background(Color(white: state == nil ? 0.22 : 0.3), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(state == nil ? Color.white.opacity(0.18) : Color.white.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Click: on, off, not noted")
    }
}

/// The channel fader, dragged up and down. Printed scale: +10 at the top, 0 near a quarter down, off at the bottom.
struct FaderView: View {
    @Binding var value: Double?
    private static let marks = StripSheet.faderMarks
    private let height: CGFloat = 170

    private func position(_ v: Double) -> Double { StripSheet.faderPosition(db: v) }
    private func level(_ p: Double) -> Double { StripSheet.faderLevel(position: p) }

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.05)).frame(width: 8, height: height)
                ForEach(Self.marks.indices, id: \.self) { i in
                    Text(Self.marks[i].db <= StripSheet.off ? "∞" : (Self.marks[i].db == 0 ? "0" : String(format: "%+.0f", Self.marks[i].db)))
                        .font(.system(size: 8)).foregroundStyle(.white.opacity(0.55)).offset(x: -20, y: CGFloat(Self.marks[i].pos) * (height - 20) + 4)
                }
                RoundedRectangle(cornerRadius: 3).fill(value == nil ? Color(white: 0.5) : Color.orange).frame(width: 30, height: 20)
                    .overlay(Rectangle().fill(Color.black.opacity(0.6)).frame(height: 2))
                    .offset(y: CGFloat(position(value ?? 0)) * (height - 20))
            }
            .frame(width: 60, height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let p = Double((g.location.y - 10) / (height - 20))
                value = (level(p) * 2).rounded() / 2
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = nil })
            Text(value.map { $0 <= StripSheet.off ? "off" : String(format: "%+.1f dB", $0) } ?? "—").font(.system(size: 10).monospacedDigit()).foregroundStyle(value == nil ? .white.opacity(0.5) : .orange)
            Text("FADER").font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
        }
        .help("Drag up and down, double-click to clear")
    }
}
