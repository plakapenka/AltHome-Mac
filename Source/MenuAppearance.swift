import SwiftUI

final class ShelfBackdrop: NSVisualEffectView {
    // WinUI's dark base acrylic uses #202020 at 50% over its backdrop.
    private final class Tint: NSView {
        private static let pigment: NSColor = {
            let side = 64
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: side * 3, bitsPerPixel: 24), let pixels = bitmap.bitmapData else {
                return NSColor(srgbRed: 32/255, green: 32/255, blue: 32/255, alpha: 1)
            }
            // A small stationary tile gives the tint a fine grain without sampling the screen.
            for i in 0..<(side * side) {
                let shade = UInt8.random(in: 28...36)
                for channel in 0..<3 { pixels[i * 3 + channel] = shade }
            }
            let image = NSImage(size: bitmap.size)
            image.addRepresentation(bitmap)
            return NSColor(patternImage: image)
        }()

        override func draw(_ dirtyRect: NSRect) {
            Self.pigment.setFill()
            bounds.intersection(dirtyRect).fill()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        blendingMode = .behindWindow
        material = .hudWindow
        state = .active
        let tint = Tint(frame: bounds)
        tint.alphaValue = 0.5
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)
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
