import AppKit
import SwiftUI

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

final class StartPanel: NSPanel {
    private let outside = OutsideClickMonitor()
    private let card: NSHostingView<StartMenu>
    private weak var anchor: NSButton?
    private var transition = 0
    private(set) var isClosing = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(menu: StartMenu, above anchor: NSButton, in shelf: NSWindow, screen: NSScreen) {
        self.anchor = anchor
        card = NSHostingView(rootView:menu)
        let bounds = screen.visibleFrame
        let x = min(max(bounds.minX+8,shelf.frame.minX+8), bounds.maxX-menu.size.width-8)
        let rect = NSRect(origin:NSPoint(x:x,y:shelf.frame.maxY+6),size:menu.size)
        super.init(contentRect:rect,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        isReleasedWhenClosed = false
        animationBehavior = .none
        title = "Пуск"
        appearance = shelf.effectiveAppearance
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        level = shelf.level
        collectionBehavior = [.moveToActiveSpace,.fullScreenAuxiliary]
        // The stationary viewport clips the moving card exactly above the shelf.
        let viewport = NSView(frame:NSRect(origin:.zero,size:menu.size))
        viewport.wantsLayer = true
        viewport.layer?.masksToBounds = true
        contentView = viewport
        card.frame = viewport.bounds
        card.wantsLayer = true
        card.layer?.cornerRadius = 13
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        viewport.addSubview(card)
    }

    func showMenu() {
        guard let anchor, let shelf = anchor.window else { return }
        let wasVisible = isVisible
        isClosing = false
        ignoresMouseEvents = false
        if !wasVisible {
            card.setFrameOrigin(NSPoint(x:0,y:-card.frame.height))
            card.alphaValue = 0
            if parent == nil { shelf.addChildWindow(self, ordered:.above) }
        }
        makeKeyAndOrderFront(nil)
        card.layoutSubtreeIfNeeded()
        card.rootView.focusSearch.send()
        if let editor = firstResponder as? NSTextView, editor.isFieldEditor { editor.selectAll(nil) }
        outside.start(window:self,anchor:anchor) { [weak self] in self?.dismiss() }
        animate(open:true)
    }

    func dismiss() {
        guard isVisible, !isClosing else { return }
        isClosing = true
        outside.stop()
        ignoresMouseEvents = true
        animate(open:false)
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    private func animate(open: Bool) {
        transition += 1
        let token = transition
        let destination = NSPoint(x:0,y:open ? 0 : -card.frame.height)
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
