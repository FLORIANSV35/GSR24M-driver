import SwiftUI

/// Look modelled on the original Allen & Heath Firewire panel: grey panels, dark title bars,
/// light value boxes, rounded tabs.
enum Theme {
    static let window = Color(white: 0.17)
    static let panel = Color(white: 0.34)
    static let panelEdge = Color(white: 0.45)
    static let bar = Color(white: 0.20)
    static let tab = Color(white: 0.50)
    static let tabSelected = Color(white: 0.66)
    static let box = Color(white: 0.90)
    static let boxText = Color(white: 0.12)
    static let card = Color(white: 0.96)
}

struct Bar: View {
    let title: String
    var body: some View {
        Text(title).font(.headline).foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(Theme.bar, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct Panel<C: View>: View {
    @ViewBuilder var content: C
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.panelEdge, lineWidth: 1))
    }
}

struct TabRow<T: Hashable>: View {
    let items: [T]
    let title: (T) -> String
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { t in
                Button { selection = t } label: {
                    Text(title(t)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(selection == t ? Theme.tabSelected : Theme.tab, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

struct ValueBox: View {
    let text: String
    var width: CGFloat = 120
    var body: some View {
        Text(text).foregroundStyle(Theme.boxText).lineLimit(1)
            .frame(width: width).padding(.vertical, 4)
            .background(Theme.box, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.35), lineWidth: 1))
    }
}

struct FieldLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).foregroundStyle(.white).frame(width: 170, alignment: .trailing)
    }
}
