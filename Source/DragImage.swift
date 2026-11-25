import AppKit

// A noninteractive window keeps the grabbed pixels under the pointer, even outside the strip.
final class DragImage {
    private let panel: NSPanel
    private weak var source: NSView?
    private let grab: NSPoint

    init?(source: NSView, down: NSPoint, image supplied: NSImage? = nil, backgroundColor: NSColor? = nil) {
        guard let window = source.window else { return nil }
        let image: NSImage
        if let supplied { image = supplied }
        else {
            guard let bitmap = source.bitmapImageRepForCachingDisplay(in: source.bounds) else { return nil }
            source.cacheDisplay(in: source.bounds, to: bitmap)
            image = NSImage(size: source.bounds.size)
            image.addRepresentation(bitmap)
        }
        let rect = window.convertToScreen(source.convert(source.bounds, to: nil))
        grab = NSPoint(x: down.x - rect.minX, y: down.y - rect.minY)
        self.source = source
        panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Перетаскивание"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
        let picture = NSImageView(frame: NSRect(origin: .zero, size: rect.size))
        if let backgroundColor {
            picture.wantsLayer = true
            picture.layer?.backgroundColor = backgroundColor.cgColor
            picture.layer?.cornerRadius = source.layer?.cornerRadius ?? 0
            picture.layer?.cornerCurve = .continuous
            picture.layer?.masksToBounds = true
        }
        picture.image = image
        picture.imageScaling = .scaleAxesIndependently
        panel.contentView = picture
        source.alphaValue = 0
        panel.orderFrontRegardless()
    }
    func follow(_ point: NSPoint, minimumX: CGFloat = -.infinity) {
        panel.setFrameOrigin(NSPoint(x: max(minimumX, point.x - grab.x), y: point.y - grab.y))
    }
    func setDropHighlight(_ enabled: Bool) {
        guard let layer = panel.contentView?.layer else { return }
        layer.borderColor = NSColor.controlAccentColor.cgColor
        layer.borderWidth = enabled ? 2 : 0
    }
    func finish() {
        guard let source, let window = source.window, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            cancel()
            return
        }
        let slot = window.convertToScreen(source.convert(source.bounds, to: nil))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(slot, display: true)
        } completionHandler: { [self] in cancel() }
    }
    func cancel() {
        source?.alphaValue = 1
        source = nil
        panel.orderOut(nil)
    }
}
