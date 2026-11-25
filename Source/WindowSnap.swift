import AppKit

enum SnapZone {
    case top, left, right

    static func at(_ point: CGPoint, in display: CGRect) -> SnapZone? {
        guard display.contains(point) else { return nil }
        // MenuBarEdge can hold the cursor six points below the physical top.
        if point.y - display.minY < 12 { return .top }
        if point.x - display.minX < 12 { return .left }
        if display.maxX - point.x <= 12 { return .right }
        return nil
    }

    func frame(in area: CGRect) -> CGRect {
        guard self != .top else { return area }
        let half = area.divided(atDistance: floor(area.width / 2), from: .minXEdge)
        return self == .left ? half.slice : half.remainder
    }
}

private extension FirstTitleClick {
    func currentFrame() -> CGRect? {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]],
              let row = rows.first, row[kCGWindowOwnerPID as String] as? pid_t == pid,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }
}

final class WindowSnap {
    private var start: FirstTitleClick?
    private var confirmed = false
    private var lastProbe: TimeInterval = 0
    private var placement: Task<Void, Never>?
    private let picker = SnapWindowPicker()
    private lazy var outline: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Область размещения окна"
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.74).cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 12
        panel.contentView = view
        return panel
    }()

    func cancel() {
        start = nil
        confirmed = false
        placement?.cancel()
        outline.orderOut(nil)
        picker.hide()
    }

    func mouseDown(at point: CGPoint) {
        start = nil
        confirmed = false
        placement?.cancel()
        if outline.isVisible { outline.orderOut(nil) }
        if let primary = NSScreen.screens.first,
           !accessibilityFrame(picker.panel.frame, primary: primary).contains(point) { picker.hide() }
    }

    func begin(_ click: FirstTitleClick) {
        guard click.pid != ProcessInfo.processInfo.processIdentifier,
              click.point.y - click.frame.minY < 60, click.frame.height > 60,
              !picker.panel.isVisible else { return }
        start = click
        lastProbe = 0
    }

    func track(_ point: CGPoint, ending: Bool, owner: Delegate) {
        guard let click = start else { return }
        defer {
            if ending {
                start = nil
                confirmed = false
                if outline.isVisible { outline.orderOut(nil) }
            }
        }
        guard hypot(point.x - click.point.x, point.y - click.point.y) >= 8,
              let primary = NSScreen.screens.first,
              let screen = NSScreen.screens.first(where: { accessibilityFrame($0.frame, primary: primary).contains(point) }),
              let zone = SnapZone.at(point, in: accessibilityFrame(screen.frame, primary: primary)) else {
            if outline.isVisible { outline.orderOut(nil) }
            return
        }
        if !confirmed {
            let now = ProcessInfo.processInfo.systemUptime
            guard ending || now - lastProbe > 0.04 else { return }
            lastProbe = now
            // The actual window must travel with the drag. Moving a tab, selecting text,
            // and resizing from the upper border also start in the title-bar band.
            guard let frame = click.currentFrame(),
                  abs(frame.width - click.frame.width) < 2, abs(frame.height - click.frame.height) < 2,
                  hypot(frame.minX - click.frame.minX, frame.minY - click.frame.minY) > 4 else { return }
            confirmed = true
        }
        let area = owner.usableFrame(on: screen)
        let target = zone.frame(in: area)
        if !ending {
            let hint = target.insetBy(dx: 3, dy: 3)
            if outline.frame != hint { outline.setFrame(hint, display: false) }
            if !outline.isVisible { outline.orderFrontRegardless() }
            return
        }
        // Let the target process receive mouse-up and finish native edge tiling.
        placement = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, let app = NSRunningApplication(processIdentifier: click.pid), app.isActive,
                  let cgFrame = click.currentFrame() else { return }
            let root = AXUIElementCreateApplication(click.pid)
            AXUIElementSetMessagingTimeout(root, 0.15)
            guard let window = element(root, kAXFocusedWindowAttribute),
                  let current = windowRect(window) else { return }
            if let number = attr(window, "AXWindowNumber") as? CGWindowID {
                guard number == click.number else { return }
            } else if !nearlyEqual(current, cgFrame) { return }
            let goal = accessibilityFrame(target, primary: primary)
            guard self.place(window, app: app, target: goal, original: click.frame, owner: owner) else { return }
            // Native tiling may complete after the first write.
            try? await Task.sleep(nanoseconds: 240_000_000)
            guard !Task.isCancelled, app.isActive, let actual = windowRect(window) else { return }
            if !nearlyEqual(actual, goal) {
                guard self.place(window, app: app, target: goal, original: click.frame, owner: owner) else { return }
            }
            guard zone != .top, let fitted = windowRect(window), nearlyEqual(fitted, goal) else { return }
            let other = (zone == .left ? SnapZone.right : .left).frame(in: area)
            self.picker.show(in: other, excluding: window, owner: owner) { otherWindow, otherApp in
                guard let before = windowRect(otherWindow), owner.bring(otherWindow, otherApp, reportFailure: false) else { return }
                _ = self.place(otherWindow, app: otherApp, target: accessibilityFrame(other, primary: primary),
                               original: before, owner: owner)
            }
        }
    }

    private func place(_ window: AXUIElement, app: NSRunningApplication, target: CGRect, original: CGRect, owner: Delegate) -> Bool {
        var writable = DarwinBoolean(false)
        guard attr(window, "AXFullScreen") as? Bool != true, !minimized(window),
              AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &writable) == .success,
              writable.boolValue, let current = windowRect(window) else { return false }
        if !nearlyEqual(current, target) {
            guard owner.writeFrame(target, to: window) else {
                _ = owner.writeFrame(current, to: window)
                return false
            }
            // macOS can clamp the initial position while the window still has its old width.
            if let actual = windowRect(window), actual.origin != target.origin {
                var point = CGPoint(x: min(target.minX, target.maxX - actual.width), y: target.minY)
                if let value = AXValueCreate(.cgPoint, &point) {
                    _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
                }
            }
        }
        let previous = owner.expanded.first { CFEqual(window, $0.1) &&
            (nearlyEqual($0.3, original) || nearlyEqual($0.3, target)) }
        owner.expanded.removeAll { CFEqual(window, $0.1) }
        owner.expanded.append((app.processIdentifier, window, previous?.2 ?? original, windowRect(window) ?? target))
        return true
    }
}
