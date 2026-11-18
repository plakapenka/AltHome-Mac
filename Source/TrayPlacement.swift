import AppKit

extension Tray {
    // NSMenu takes the top-left corner when no item is selected for positioning.
    func popUp(_ menu: NSMenu, above button: NSButton) {
        guard let window = button.window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds,to:nil))
        let visible = screen.visibleFrame
        let size = menu.size
        let x = max(visible.minX+4,min(anchor.midX-size.width/2,visible.maxX-size.width-4))
        let top = min(visible.maxY-4,window.frame.maxY+6+size.height)
        menu.popUp(positioning:nil,at:NSPoint(x:x,y:top),in:nil)
    }

    private func visibleControls(in panel: AXUIElement, frame: CGRect) -> CGRect? {
        // Recent Control Center windows cover most of a display with transparent padding.
        // Module groups and scroll areas already enclose their visible children.
        func bounds(_ parent: AXUIElement, depth: Int) -> CGRect {
            var union = CGRect.null
            for child in attr(parent,kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                guard let r = owner.windowRect(child), !r.isEmpty else { continue }
                if nearlyEqual(r,frame) && depth < 3 {
                    union = union.union(bounds(child,depth:depth+1))
                } else if !nearlyEqual(r,frame) {
                    let clipped = r.intersection(frame)
                    if !clipped.isNull { union = union.union(clipped) }
                }
            }
            return union
        }
        let controls = bounds(panel,depth:0)
        if !controls.isNull { return controls.insetBy(dx:-12,dy:-12) }
        return frame.height < 600 ? frame : nil
    }

    func anchorControlCenter(to button: NSButton) {
        placement?.cancel()
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.controlcenter").first else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,0.2)
        placement = Task { @MainActor [weak self, weak button] in
            var missing = 0
            while let self, let button, !Task.isCancelled, let bar = button.window,
                  let screen = bar.screen, let primary = NSScreen.screens.first, !app.isTerminated {
                let anchor = accessibilityFrame(bar.convertToScreen(button.convert(button.bounds,to:nil)),primary:primary)
                let available = accessibilityFrame(screen.visibleFrame,primary:primary)
                let bottom = accessibilityFrame(bar.frame,primary:primary).minY - 6
                let panels = attr(root,kAXWindowsAttribute) as? [AXUIElement] ?? []
                if let panel = panels.first,
                   let frame = self.owner.windowRect(panel),
                   let content = self.visibleControls(in:panel,frame:frame) {
                    missing = 0
                    let left = max(available.minX+4,min(anchor.midX-content.width/2,available.maxX-content.width-4))
                    let top = max(available.minY+4,bottom-content.height)
                    var origin = CGPoint(x:(frame.minX + left - content.minX).rounded(),
                                         y:(frame.minY + top - content.minY).rounded())
                    if abs(origin.x-frame.minX) > 1 || abs(origin.y-frame.minY) > 1 {
                        guard let value = AXValueCreate(.cgPoint,&origin),
                              AXUIElementSetAttributeValue(panel,kAXPositionAttribute as CFString,value) == .success else { return }
                    }
                } else {
                    missing += 1
                    if missing >= 8 { return }
                }
                try? await Task.sleep(nanoseconds:missing == 0 ? 300_000_000 : 65_000_000)
            }
        }
    }
}
