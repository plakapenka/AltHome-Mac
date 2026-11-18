import AppKit

final class DockNameTag: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let maskShape = CAShapeLayer()
    private var lastAnchor: NSRect?
    private var lastTip: CGFloat = -1

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Подпись Dock"
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        let material = NSVisualEffectView()
        material.material = .popover
        material.state = .active
        material.blendingMode = .behindWindow
        material.wantsLayer = true
        material.layer?.mask = maskShape
        contentView = material
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        material.addSubview(label)
    }

    func show(_ name: String, above anchor: NSRect, in dock: NSWindow) {
        if lastAnchor == anchor, parent === dock, label.stringValue == name, isVisible { return }
        guard let screen = dock.screen else { hide(); return }
        lastAnchor = anchor
        if label.stringValue != name { label.stringValue = name }
        let visible = screen.visibleFrame
        let width = min(ceil(label.intrinsicContentSize.width) + 22, 380, visible.width - 12)
        let x = min(max(round(anchor.midX - width / 2), visible.minX + 6), visible.maxX - width - 6)
        let rect = NSRect(x: x, y: round(anchor.maxY) + 3, width: width, height: 32)
        let tip = min(max(round(anchor.midX - x), 10), width - 10)
        if frame.size != rect.size || tip != lastTip {
            lastTip = tip
            let path = CGMutablePath()
            path.addRoundedRect(in: CGRect(x: 0, y: 5, width: width, height: 27), cornerWidth: 8, cornerHeight: 8)
            path.move(to: CGPoint(x: tip - 5, y: 6))
            path.addLine(to: CGPoint(x: tip, y: 0))
            path.addLine(to: CGPoint(x: tip + 5, y: 6))
            path.closeSubpath()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            maskShape.frame = NSRect(origin: .zero, size: rect.size)
            maskShape.path = path
            CATransaction.commit()
            let h = ceil(label.intrinsicContentSize.height)
            label.frame = NSRect(x: 9, y: 5 + floor((27 - h) / 2), width: width - 18, height: h)
            invalidateShadow()
        }
        if frame != rect { setFrame(rect, display: true) }
        if parent !== dock {
            appearance = dock.effectiveAppearance
            level = dock.level
            dock.addChildWindow(self, ordered: .above)
        }
        if !isVisible { orderFrontRegardless() }
    }

    func hide() {
        guard parent != nil || isVisible else { return }
        lastAnchor = nil
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}
