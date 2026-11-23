import AppKit
import ScreenCaptureKit

struct PreviewTarget {
    let pid: pid_t
    let window: AXUIElement?
    let title: String
    let frame: CGRect?

    func resolve(in windows: [SCWindow]) -> SCWindow? {
        let candidates = windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 &&
            $0.frame.width > 1 && $0.frame.height > 1
        }
        guard let window else {
            if candidates.count == 1 { return candidates.first }
            // App-only tiles represent the frontmost visible window of that application.
            let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] ?? []
            for row in visible {
                if let id = row[kCGWindowNumber as String] as? UInt32,
                   let match = candidates.first(where:{ $0.windowID == id }) { return match }
            }
            return nil
        }
        if let id = attr(window,"AXWindowNumber") as? UInt32 {
            return candidates.first { $0.windowID == id }
        }
        let titled = title.isEmpty ? [] : candidates.filter { $0.title == title }
        if titled.count == 1 { return titled.first }
        guard let frame else { return nil }
        let aligned = (titled.isEmpty ? candidates : titled).filter {
            let r = $0.frame
            return abs(r.minX-frame.minX) <= 1 && abs(r.minY-frame.minY) <= 1 &&
                   abs(r.width-frame.width) <= 1 && abs(r.height-frame.height) <= 1
        }
        return aligned.count == 1 ? aligned.first : nil
    }
}

private final class PreviewCloseButton: ShelfButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class WindowPreview {
    private let panel: NSPanel
    private static let thumbnailSize = NSSize(width: 248, height: 136)
    private let image = NSImageView(frame: NSRect(origin: NSPoint(x: 10, y: 10), size: WindowPreview.thumbnailSize))
    private let title = NSTextField(labelWithString:"")
    private let icon = NSImageView(frame:NSRect(x:12,y:154,width:17,height:17))
    private let message = NSTextField(wrappingLabelWithString:"")
    private let closeButton = PreviewCloseButton(frame: NSRect(x: 232, y: 148, width: 28, height: 28))
    private var closeAction: (() -> Void)?
    private var hoverTimer: Timer?
    private var pending: Task<Void,Never>?
    private(set) weak var anchor: Tile?

    init() {
        panel = NSPanel(contentRect:NSRect(x:0,y:0,width:268,height:180),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.title = "Предпросмотр окна"
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary, .canJoinAllApplications,.ignoresCycle]
        panel.appearance = NSAppearance(named:.darkAqua)
        let body = NSView(frame:panel.contentRect(forFrameRect:panel.frame))
        body.wantsLayer = true
        body.layer?.cornerRadius = 10
        body.layer?.cornerCurve = .continuous
        body.layer?.backgroundColor = NSColor(srgbRed:0.145,green:0.15,blue:0.16,alpha:1).cgColor
        body.layer?.borderWidth = 0.5
        body.layer?.borderColor = NSColor(white:1,alpha:0.18).cgColor
        panel.contentView = body
        title.frame = NSRect(x:36,y:154,width:190,height:17)
        title.font = .systemFont(ofSize:13,weight:.medium)
        title.lineBreakMode = .byTruncatingTail
        image.imageScaling = .scaleAxesIndependently
        icon.imageScaling = .scaleProportionallyUpOrDown
        message.frame = NSRect(x:16,y:48,width:236,height:46)
        message.font = .systemFont(ofSize:12)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.setAccessibilityLabel("Закрыть окно")
        closeButton.target = self
        closeButton.action = #selector(closePreviewedWindow)
        for view in [title,icon,image,message,closeButton] as [NSView] { body.addSubview(view) }
    }

    @objc private func closePreviewedWindow() {
        guard let closeAction else { return }
        hide()
        closeAction()
    }

    func leftTile() {
        if !panel.isVisible { hide() }
    }

    private func trackPointer() {
        var lastInside = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let tile = self.anchor, let bar = tile.window, !tile.visibleRect.isEmpty else { self.hide(); return }
            let button = bar.convertToScreen(tile.convert(tile.visibleRect, to: nil))
            // The gap between the tile and its preview is also part of the hover target.
            let bridge = NSRect(x: button.minX, y: button.minY, width: button.width,
                                height: max(button.height, self.panel.frame.minY - button.minY))
            let point = NSEvent.mouseLocation
            let now = ProcessInfo.processInfo.systemUptime
            if bridge.contains(point) || self.panel.frame.contains(point) { lastInside = now }
            else if now - lastInside >= 0.2 { self.hide() }
        }
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func hide() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        closeAction = nil
        pending?.cancel()
        pending = nil
        anchor = nil
        panel.orderOut(nil)
        image.image = nil
    }

    func show(for tile: Tile, task: TaskEntry, frame: @escaping (AXUIElement) -> CGRect?, close: @escaping (AXUIElement, NSRunningApplication) -> Void) {
        guard let app = task.app, anchor !== tile else { return }
        hide()
        anchor = tile
        pending = Task { @MainActor [weak self, weak tile] in
            try? await Task.sleep(nanoseconds:350_000_000)
            guard !Task.isCancelled, let self, let tile, let bar = tile.window,
                  let screen = bar.screen, !tile.visibleRect.isEmpty, !app.isTerminated else { return }
            let rect = bar.convertToScreen(tile.convert(tile.visibleRect,to:nil))
            let size = panel.frame.size
            let x = min(max(screen.visibleFrame.minX + 4, rect.midX-size.width/2),screen.visibleFrame.maxX-size.width-4)
            panel.setFrameOrigin(NSPoint(x:x,y:bar.frame.maxY+6))
            title.stringValue = task.caption ?? task.item.name
            icon.image = app.icon
            message.stringValue = "Загрузка…"
            message.isHidden = false
            if let window = task.entry?.window, let button = element(window, kAXCloseButtonAttribute),
               (attr(button, kAXEnabledAttribute) as? Bool) != false {
                closeAction = { close(window, app) }
            }
            closeButton.isEnabled = closeAction != nil
            closeButton.toolTip = closeButton.isEnabled ? "Закрыть окно" : "Закрытие этого окна недоступно"
            panel.orderFrontRegardless()
            trackPointer()
            guard CGPreflightScreenCaptureAccess() else {
                message.stringValue = "Настройки TaskShelf → Основные → Превью окон"
                return
            }
            let target = PreviewTarget(pid:app.processIdentifier,window:task.entry?.window,
                                       title:task.entry?.title ?? "",frame:task.entry.flatMap { frame($0.window) })
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
                guard !Task.isCancelled else { return }
                guard let window = target.resolve(in:content.windows) else {
                    message.stringValue = "Превью окна недоступно"
                    return
                }
                if task.entry == nil, let name = window.title, !name.isEmpty { title.stringValue = name }
                while !Task.isCancelled {
                    let bitmap = try await Self.snapshot(window)
                    guard !Task.isCancelled else { return }
                    guard let bitmap else { break }
                    image.image = NSImage(cgImage: bitmap, size: Self.thumbnailSize)
                    message.isHidden = true
                    try await Task.sleep(nanoseconds:900_000_000)
                }
            } catch { }
            guard !Task.isCancelled else { return }
            image.image = nil
            message.isHidden = false
            message.stringValue = "Превью окна недоступно"
        }
    }

    // Bitmap coordinates start at the top. Keep title bars and browser tabs in view.
    static func thumbnailCrop(in size: CGSize) -> CGRect {
        let aspect = thumbnailSize.width / thumbnailSize.height
        let width = min(size.width, size.height * aspect)
        let height = min(size.height, size.width / aspect)
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: height)
    }

    static func snapshot(_ window: SCWindow) async throws -> CGImage? {
        let bitmap: CGImage?
        if #available(macOS 14.0, *) {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let size = filter.contentRect.size
            guard size.width > 0, size.height > 0 else { return nil }
            let crop = thumbnailCrop(in: size)
            // Keep Retina detail in the visible area and bound capture cost for extreme aspect ratios.
            let scale = min(2 * thumbnailSize.width / crop.width, 2048 / max(size.width, size.height))
            let config = SCStreamConfiguration()
            config.width = max(2, Int((size.width * scale).rounded()))
            config.height = max(2, Int((size.height * scale).rounded()))
            config.scalesToFit = true
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.ignoreGlobalClipSingleWindow = true
            bitmap = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } else {
            bitmap = CGWindowListCreateImage(.null, .optionIncludingWindow, window.windowID, [.boundsIgnoreFraming, .nominalResolution])
        }
        guard let bitmap else { return nil }
        return bitmap.cropping(to: thumbnailCrop(in: CGSize(width: bitmap.width, height: bitmap.height)).integral)
    }
}
