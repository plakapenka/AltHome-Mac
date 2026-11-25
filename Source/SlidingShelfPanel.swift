import AppKit

final class OutsideClickMonitor {
    private var monitors: [Any] = []

    func start(window: NSWindow, anchor: NSButton, dismiss: @escaping () -> Void) {
        stop()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching:clicks, handler:{ _ in dismiss() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching:clicks, handler:{ [weak window, weak anchor] event in
            var target = event.window
            while let current = target {
                if current === window { return event }
                target = current.parent
            }
            // A second click on the anchor is handled by the button itself.
            if event.type == .leftMouseDown, let anchor, event.window === anchor.window,
               anchor.bounds.contains(anchor.convert(event.locationInWindow, from:nil)) { return event }
            dismiss()
            return event
        }) { monitors.append(local) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    deinit { stop() }
}

final class SlidingShelfPanel: NSPanel {
    let edge: ShelfEdge
    private let outside = OutsideClickMonitor()
    private let card: NSView
    private let onShow: ((NSWindow) -> Void)?
    private(set) weak var anchor: NSButton?
    var onPresentationChange: ((Bool) -> Void)?
    private var transition = 0
    private(set) var isClosing = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(title: String, card: NSView, beside anchor: NSButton, in shelf: Bar, screen: NSScreen,
         cornerRadius: CGFloat = 13, onShow: ((NSWindow) -> Void)? = nil) {
        edge = shelf.edge
        self.anchor = anchor
        self.card = card
        self.onShow = onShow
        let size = card.fittingSize
        let bounds = screen.visibleFrame
        let button = shelf.convertToScreen(anchor.convert(anchor.bounds,to:nil))
        let x = min(max(bounds.minX+8,button.midX-size.width/2),bounds.maxX-size.width-8)
        let rect = NSRect(origin:NSPoint(x:x,y:edge.popupY(beside: shelf.frame, height: size.height)),size:size)
        super.init(contentRect:rect,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        isReleasedWhenClosed = false
        animationBehavior = .none
        self.title = title
        appearance = shelf.effectiveAppearance
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        level = shelf.level
        collectionBehavior = [.moveToActiveSpace,.fullScreenAuxiliary, .canJoinAllApplications]
        // The stationary viewport clips the moving card at the shelf edge.
        let viewport = NSView(frame:NSRect(origin:.zero,size:size))
        viewport.wantsLayer = true
        viewport.layer?.masksToBounds = true
        contentView = viewport
        card.frame = viewport.bounds
        card.wantsLayer = true
        card.layer?.cornerRadius = cornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        viewport.addSubview(card)
    }

    // Wireless tabs, devices and network forms can change height while the panel is open.
    func fitContent(to size: NSSize) {
        let height = ceil(size.height)
        guard height > 0, height != frame.height else { return }
        var resized = frame
        if edge == .top { resized.origin.y = frame.maxY - height }
        resized.size.height = height
        setFrame(resized,display:true)
        card.setFrameSize(resized.size)
    }

    func fitDock(to size: NSSize) {
        guard let anchor, let shelf = anchor.window, let screen = shelf.screen, size.width > 0 else { return }
        let button = shelf.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let bounds = screen.visibleFrame
        let x = min(max(bounds.minX + 8, button.midX - size.width / 2), bounds.maxX - size.width - 8)
        let target = NSRect(x: x, y: edge.popupY(beside: shelf.frame, height: size.height), width: size.width, height: size.height)
        if frame != target {
            setFrame(target, display: true)
            card.setFrameSize(size)
        }
    }

    private var hiddenY: CGFloat { edge == .top ? card.frame.height : -card.frame.height }

    func showPanel(takingKey: Bool = true, dismissOnOutsideClick: Bool = true) {
        guard let anchor, let shelf = anchor.window else { return }
        let wasVisible = isVisible
        isClosing = false
        ignoresMouseEvents = false
        if !wasVisible {
            card.setFrameOrigin(NSPoint(x:0,y:hiddenY))
            card.alphaValue = 0
            if parent == nil { shelf.addChildWindow(self, ordered:.above) }
        }
        if takingKey { makeKeyAndOrderFront(nil) } else { orderFrontRegardless() }
        card.layoutSubtreeIfNeeded()
        onPresentationChange?(true)
        onShow?(self)
        if dismissOnOutsideClick {
            outside.start(window:self,anchor:anchor) { [weak self] in self?.dismiss() }
        }
        animate(open:true)
    }

    func dismiss() {
        guard isVisible, !isClosing else { return }
        isClosing = true
        onPresentationChange?(false)
        outside.stop()
        ignoresMouseEvents = true
        animate(open:false)
    }

    func dismissImmediately() {
        onPresentationChange?(false)
        transition += 1
        outside.stop()
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    private func animate(open: Bool) {
        transition += 1
        let token = transition
        let destination = NSPoint(x:0,y:open ? 0 : hiddenY)
        let finish = { [weak self] in
            guard let self, token == self.transition else { return }
            if open {
                self.invalidateShadow()
            } else {
                self.parent?.removeChildWindow(self)
                self.orderOut(nil)
            }
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            card.setFrameOrigin(destination)
            card.alphaValue = open ? 1 : 0
            finish()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = open ? 0.23 : 0.18
            context.timingFunction = CAMediaTimingFunction(name:open ? .easeOut : .easeIn)
            card.animator().setFrameOrigin(destination)
            card.animator().alphaValue = open ? 1 : 0
        } completionHandler: { finish() }
    }
}
