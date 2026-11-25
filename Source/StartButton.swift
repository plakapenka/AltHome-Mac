import AppKit

final class StartButton: ShelfButton {
    let glyph = NSImageView()
    private var trackingPress = false

    override init(frame: NSRect) {
        super.init(frame:frame)
        isBordered = false
        title = ""
        setAccessibilityLabel("Пуск")
        toolTip = "Пуск"
        setGlyphSize(26)
        glyph.contentTintColor = .white
        glyph.imageScaling = .scaleNone
        glyph.frame = bounds
        glyph.autoresizingMask = [.width,.height]
        glyph.wantsLayer = true
        glyph.setAccessibilityElement(false)
        addSubview(glyph)
    }

    private var glyphSize: CGFloat = 0
    func setGlyphSize(_ pointSize: CGFloat) {
        guard glyphSize != pointSize else { return }
        glyphSize = pointSize
        let font = NSFont.systemFont(ofSize:pointSize,weight:.medium)
        if let symbol = NSImage(systemSymbolName:"apple.logo",accessibilityDescription:nil) {
            glyph.image = symbol.withSymbolConfiguration(.init(pointSize:font.pointSize,weight:.medium)) ?? symbol
        } else {
            let mark = NSAttributedString(string:"",attributes:[.font:font,.foregroundColor:NSColor.white])
            glyph.image = NSImage(size:mark.size(),flipped:false) { _ in mark.draw(at:.zero); return true }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func mouseDown(with event: NSEvent) {
        trackingPress = true
        defer { trackingPress = false }
        animateGlyph()
        super.mouseDown(with:event)
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if !trackingPress { animateGlyph() }
        return super.sendAction(action,to:target)
    }

    private func animateGlyph() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = glyph.layer else { return }
        // AppKit owns the layer's anchor point. Keep the logo centered as it scales.
        let centerX = glyph.bounds.width * (0.5 - layer.anchorPoint.x)
        let centerY = glyph.bounds.height * (0.5 - layer.anchorPoint.y)
        let current = layer.presentation()?.transform.m11 ?? 1
        let pulse = CAKeyframeAnimation(keyPath:"transform")
        pulse.values = [current,0.84,1].map { scale in
            var transform = CATransform3DMakeScale(scale,scale,1)
            transform.m41 = centerX * (1-scale)
            transform.m42 = centerY * (1-scale)
            return NSValue(caTransform3D:transform)
        }
        pulse.keyTimes = [0,0.32,1]
        pulse.timingFunctions = [.init(name:.easeOut),.init(name:.easeInEaseOut)]
        pulse.duration = 0.22
        layer.add(pulse,forKey:"startPress")
    }
}
