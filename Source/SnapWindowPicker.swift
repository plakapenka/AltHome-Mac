import AppKit
import ScreenCaptureKit

private final class SnapChoice: NSButton {
    var choose: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc func selectWindow() { choose?() }
}

final class SnapWindowPicker {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var images: Task<Void, Never>?
    private var escape: Any?
    private var outside: Any?

    init() {
        panel.title = "Выбор второго окна"
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle]
    }

    func hide() {
        images?.cancel()
        images = nil
        if let escape { NSEvent.removeMonitor(escape) }
        if let outside { NSEvent.removeMonitor(outside) }
        escape = nil
        outside = nil
        if panel.isVisible { panel.orderOut(nil) }
        panel.contentView = nil
    }

    func show(in area: CGRect, excluding first: AXUIElement, owner: Delegate,
              choose: @escaping (AXUIElement, NSRunningApplication) -> Void) {
        hide()
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] else { return }
        let grouped = Dictionary(grouping: rows.filter { $0[kCGWindowLayer as String] as? Int == 0 }) {
            $0[kCGWindowOwnerPID as String] as? pid_t
        }
        let width = min(area.width - 24, 380)
        guard width > 140, area.height > 120 else { return }
        var items: [(Int, SnapChoice, PreviewTarget)] = []
        for (pid, entries) in owner.snapshots {
            guard let visible = grouped[pid], let app = NSRunningApplication(processIdentifier: pid), !app.isHidden else { continue }
            for entry in entries where entry.window != first && !entry.fullScreen {
                let window = entry.window
                var writable = DarwinBoolean(false)
                guard let frame = windowRect(window), !minimized(window),
                      AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &writable) == .success, writable.boolValue else { continue }
                let number = attr(window, "AXWindowNumber") as? CGWindowID
                guard let record = visible.first(where: { row in
                    if let number { return row[kCGWindowNumber as String] as? CGWindowID == number }
                    guard let bounds = row[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
                    return nearlyEqual(frame, rect)
                }), let id = record[kCGWindowNumber as String] as? CGWindowID,
                      let index = rows.firstIndex(where: { $0[kCGWindowNumber as String] as? CGWindowID == id }) else { continue }
                let button = SnapChoice()
                button.title = entry.title.isEmpty ? app.localizedName ?? "Окно" : entry.title
                button.toolTip = button.title
                button.alignment = .left
                button.bezelStyle = .regularSquare
                button.imagePosition = .imageLeft
                button.image = app.icon
                button.imageScaling = .scaleProportionallyDown
                button.lineBreakMode = .byTruncatingTail
                button.target = button
                button.action = #selector(SnapChoice.selectWindow)
                button.choose = { [weak self] in
                    self?.hide()
                    guard !app.isTerminated else { return }
                    choose(window, app)
                }
                items.append((index, button, PreviewTarget(pid: pid, window: window, title: entry.title, frame: frame)))
            }
        }
        guard !items.isEmpty else { return }
        items.sort { $0.0 < $1.0 }
        let rowHeight: CGFloat = 55
        let height = min(area.height - 24, 52 + rowHeight * CGFloat(min(items.count, 6)))
        let body = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        body.material = .popover
        body.state = .active
        body.wantsLayer = true
        body.layer?.cornerRadius = 14
        body.layer?.masksToBounds = true
        let label = NSTextField(labelWithString: "Выберите второе окно")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.frame = NSRect(x: 16, y: height - 32, width: width - 32, height: 20)
        body.addSubview(label)
        let scroll = NSScrollView()
        scroll.frame = NSRect(x: 10, y: 8, width: width - 20, height: height - 52)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let list = NSView(frame: NSRect(x: 0, y: 0, width: scroll.frame.width, height: CGFloat(items.count) * rowHeight))
        for (i, item) in items.enumerated() {
            item.1.frame = NSRect(x: 0, y: list.frame.height - CGFloat(i + 1) * rowHeight, width: list.frame.width, height: rowHeight - 3)
            list.addSubview(item.1)
        }
        scroll.documentView = list
        list.scroll(NSPoint(x: 0, y: max(0, list.frame.height - scroll.frame.height)))
        body.addSubview(scroll)
        panel.setFrame(NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height), display: false)
        panel.contentView = body
        panel.orderFrontRegardless()
        escape = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if event.type != .keyDown || event.keyCode == 53 { self?.hide() }
        }
        outside = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.type == .keyDown {
                if event.keyCode == 53 { self?.hide(); return nil }
            } else if event.window !== self?.panel { self?.hide() }
            return event
        }
        guard CGPreflightScreenCaptureAccess() else { return }
        images = Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            for (_, button, target) in items {
                guard !Task.isCancelled else { return }
                guard let source = target.resolve(in: content.windows),
                      let bitmap = try? await WindowPreview.snapshot(source), !Task.isCancelled else { continue }
                button.image = NSImage(cgImage: bitmap, size: NSSize(width: 82, height: 45))
            }
        }
    }
}
