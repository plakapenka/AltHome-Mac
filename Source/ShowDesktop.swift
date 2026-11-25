import AppKit

final class DesktopButton: ShelfButton {
    override func tint() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let cap = NSRect(x: bounds.maxX - 5, y: bounds.minY, width: 5, height: bounds.height)
        if showsHover {
            NSColor.white.withAlphaComponent(0.12).setFill()
            cap.fill()
        }
        let pixel = 1 / (window?.backingScaleFactor ?? 1)
        NSColor.white.withAlphaComponent(showsHover ? 0.64 : 0.45).setFill()
        NSRect(x: cap.minX, y: cap.minY, width: pixel, height: cap.height).fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// Keep only changes made by the desktop button so previously minimized windows
// and applications hidden by the user stay that way on restore.
final class ShowDesktop {
    private struct Change {
        let app: NSRunningApplication
        var windows: [AXUIElement] = []
        var hidden = false
    }

    private let queue = DispatchQueue(label:"local.taskshelf.show-desktop", qos:.userInitiated)
    private var changes: [Change] = []
    private var previousApp: NSRunningApplication?
    private var previousFocus: AXUIElement?

    func toggle(apps: [NSRunningApplication], frontmost: NSRunningApplication?, completion: @escaping (Bool) -> Void) {
        queue.async {
            self.changes = self.changes.compactMap { change in
                guard !change.app.isTerminated else { return nil }
                var remaining = change
                remaining.windows = change.windows.filter(minimized)
                remaining.hidden = change.hidden && change.app.isHidden
                return remaining.hidden || !remaining.windows.isEmpty ? remaining : nil
            }
            if self.changes.isEmpty {
                self.showDesktop(apps:apps, frontmost:frontmost)
            } else {
                self.restore()
            }
            let showingDesktop = !self.changes.isEmpty
            DispatchQueue.main.async { completion(showingDesktop) }
        }
    }

    private func showDesktop(apps: [NSRunningApplication], frontmost: NSRunningApplication?) {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] ?? []
        let visible = rows.filter { row in
            guard let layer = row[kCGWindowLayer as String] as? Int,
                  (0...NSWindow.Level.floating.rawValue).contains(layer),
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation:bounds) else { return false }
            return rect.width > 1 && rect.height > 1 && (row[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }
        let byPID = Dictionary(grouping:visible) { $0[kCGWindowOwnerPID as String] as? pid_t }
        let trusted = AXIsProcessTrusted()
        previousApp = frontmost
        previousFocus = nil
        var visited = Set<pid_t>()
        for row in visible {
            guard let pid = row[kCGWindowOwnerPID as String] as? pid_t, visited.insert(pid).inserted,
                  let app = apps.first(where:{ $0.processIdentifier == pid }), !app.isTerminated, !app.isHidden else { continue }
            var change = Change(app:app)
            let records = byPID[pid] ?? []
            var unmatched = Set(records.indices)
            if trusted {
                let (focused, windows) = queryWindows(app)
                if pid == frontmost?.processIdentifier { previousFocus = focused }
                for window in windows ?? [] where !minimized(window) {
                    let number = attr(window,"AXWindowNumber") as? CGWindowID
                    let rect = windowRect(window)
                    guard let index = unmatched.sorted().first(where:{ i in
                        if let number { return records[i][kCGWindowNumber as String] as? CGWindowID == number }
                        guard let rect, let bounds = records[i][kCGWindowBounds as String] as? NSDictionary,
                              let actual = CGRect(dictionaryRepresentation:bounds) else { return false }
                        return nearlyEqual(rect,actual)
                    }) else { continue }
                    if setMini(window,true) {
                        change.windows.append(window)
                        unmatched.remove(index)
                    }
                }
            }
            if !unmatched.isEmpty { change.hidden = app.hide() }
            if change.hidden || !change.windows.isEmpty { changes.append(change) }
        }
    }

    private func restore() {
        var pending: [Change] = []
        for var change in changes.reversed() where !change.app.isTerminated {
            if change.hidden { change.hidden = change.app.isHidden && !change.app.unhide() }
            change.windows = change.windows.reversed().filter { minimized($0) && !setMini($0,false) }
            if change.hidden || !change.windows.isEmpty { pending.append(change) }
        }
        changes = pending.reversed()
        if let app = previousApp, !app.isTerminated, !app.isHidden {
            app.activate(options:[])
            if let previousFocus, !minimized(previousFocus) {
                _ = AXUIElementPerformAction(previousFocus,kAXRaiseAction as CFString)
            }
        }
    }
}
