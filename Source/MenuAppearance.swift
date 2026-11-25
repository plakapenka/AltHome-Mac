import SwiftUI

final class ShelfBackdrop: NSVisualEffectView {
    static let tint = NSColor.black.withAlphaComponent(0.58)

    override init(frame: NSRect) {
        super.init(frame: frame)
        blendingMode = .behindWindow
        material = .hudWindow
        state = .active
    }

    required init?(coder: NSCoder) { fatalError() }
}

enum MenuAppearance {
    static let sky = Color(red: 0.48, green: 0.84, blue: 1)

    static func wash(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color.opacity(0.15), color.opacity(0.02)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func selection(_ visible: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(visible ? 0.09 : 0))
    }
}

struct MenuRowStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        Row(label: configuration.label, highlighted: selected || configuration.isPressed)
    }

    private struct Row: View {
        let label: ButtonStyleConfiguration.Label
        let highlighted: Bool
        @State private var hovered = false

        var body: some View {
            label.padding(.horizontal, 8).frame(minHeight: 32)
                .background(MenuAppearance.selection(highlighted || hovered))
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}
