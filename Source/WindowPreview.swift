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

final class WindowPreview {
    private let panel: NSPanel
    private let image = NSImageView(frame:NSRect(x:10,y:10,width:248,height:136))
    private let title = NSTextField(labelWithString:"")
    private let icon = NSImageView(frame:NSRect(x:12,y:154,width:17,height:17))
    private let message = NSTextField(wrappingLabelWithString:"")
    private var pending: Task<Void,Never>?
    private(set) weak var anchor: Tile?

    init() {
        panel = NSPanel(contentRect:NSRect(x:0,y:0,width:268,height:180),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenNone,.ignoresCycle]
        panel.appearance = NSAppearance(named:.darkAqua)
        let body = NSView(frame:panel.contentRect(forFrameRect:panel.frame))
        body.wantsLayer = true
        body.layer?.cornerRadius = 10
        body.layer?.cornerCurve = .continuous
        body.layer?.backgroundColor = NSColor(srgbRed:0.145,green:0.15,blue:0.16,alpha:1).cgColor
        body.layer?.borderWidth = 0.5
        body.layer?.borderColor = NSColor(white:1,alpha:0.18).cgColor
        panel.contentView = body
        title.frame = NSRect(x:36,y:154,width:220,height:17)
        title.font = .systemFont(ofSize:13,weight:.medium)
        title.lineBreakMode = .byTruncatingTail
        image.imageScaling = .scaleProportionallyUpOrDown
        icon.imageScaling = .scaleProportionallyUpOrDown
        message.frame = NSRect(x:16,y:48,width:236,height:46)
        message.font = .systemFont(ofSize:12)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        for view in [title,icon,image,message] as [NSView] { body.addSubview(view) }
    }

    func hide() {
        pending?.cancel()
        pending = nil
        anchor = nil
        panel.orderOut(nil)
        image.image = nil
    }

    func show(for tile: Tile, task: TaskEntry, frame: @escaping (AXUIElement) -> CGRect?) {
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
            panel.orderFrontRegardless()
            guard CGPreflightScreenCaptureAccess() else {
                message.stringValue = "ПКМ по фону панели →\n«Разрешить превью окон…»"
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
                    image.image = NSImage(cgImage:bitmap,size:.zero)
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

    static func snapshot(_ window: SCWindow) async throws -> CGImage? {
        if #available(macOS 14.0, *) {
            let config = SCStreamConfiguration()
            let scale = min(496 / max(1,window.frame.width), 272 / max(1,window.frame.height))
            config.width = max(2, Int(window.frame.width * scale))
            config.height = max(2, Int(window.frame.height * scale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow:window)
            return try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
        }
        return CGWindowListCreateImage(.null,.optionIncludingWindow,window.windowID,[.boundsIgnoreFraming,.nominalResolution])
    }
}
