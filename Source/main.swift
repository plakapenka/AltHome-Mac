import AppKit
import UniformTypeIdentifiers
import ApplicationServices
import ServiceManagement

struct Item: Codable, Equatable {
    let key: String
    let path: String
    let name: String
    var url: URL { URL(fileURLWithPath: path) }
    init(_ url: URL, name: String? = nil) {
        path = url.standardizedFileURL.path
        key = Bundle(url: url)?.bundleIdentifier ?? path
        self.name = name ?? FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }
}

func ordered(_ pins: [Item], _ apps: [Item]) -> [Item] {
    var seen = Set<String>()
    return (pins + apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }).filter { seen.insert($0.key).inserted }
}
func attr(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success else { return nil }
    return value
}
func element(_ e: AXUIElement, _ key: String) -> AXUIElement? {
    guard let value = attr(e,key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
func minimized(_ window: AXUIElement) -> Bool { attr(window,kAXMinimizedAttribute) as? Bool == true }
func windows(_ app: NSRunningApplication) -> (AXUIElement?, [AXUIElement]) {
    let query = queryWindows(app)
    return (query.focused, query.all ?? [])
}
func queryWindows(_ app: NSRunningApplication) -> (focused: AXUIElement?, all: [AXUIElement]?) {
    let e = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(e, 0.35)
    return (element(e,kAXFocusedWindowAttribute), attr(e,kAXWindowsAttribute) as? [AXUIElement])
}

// Without accessibility access, follow actual window IDs. A window seen on screen
// can still be restored after it becomes minimized or its application is hidden.
func observedWindows(previous: [CGWindowID:pid_t]) -> [CGWindowID:pid_t] {
    guard let rows = CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else { return previous }
    var result: [CGWindowID:pid_t] = [:]
    for row in rows {
        guard row[kCGWindowLayer as String] as? Int == 0,
              let id = row[kCGWindowNumber as String] as? CGWindowID,
              let pid = row[kCGWindowOwnerPID as String] as? pid_t,
              let bounds = row[kCGWindowBounds as String] as? [String:CGFloat],
              (bounds["Width"] ?? 0) > 1, (bounds["Height"] ?? 0) > 1 else { continue }
        if previous[id] == pid || (row[kCGWindowIsOnscreen as String] as? Bool == true &&
                                   (row[kCGWindowAlpha as String] as? Double ?? 1) > 0) {
            result[id] = pid
        }
    }
    return result
}
func windowRect(_ w: AXUIElement) -> CGRect? {
    guard let pos = attr(w,kAXPositionAttribute), CFGetTypeID(pos) == AXValueGetTypeID(),
          let size = attr(w,kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    guard AXValueGetValue(pos as! AXValue,.cgPoint,&pt), AXValueGetValue(size as! AXValue,.cgSize,&sz) else { return nil }
    return CGRect(origin:pt,size:sz)
}
func setMini(_ w: AXUIElement, _ value: Bool) -> Bool {
    AXUIElementSetAttributeValue(w,kAXMinimizedAttribute as CFString,(value ? kCFBooleanTrue : kCFBooleanFalse)) == .success
}

enum TileID: Hashable {
    case app(String)
    case window(pid_t, AXUIElement)
}
struct WindowEntry: Equatable {
    let window: AXUIElement
    let title: String
    let focused: Bool
    var fullScreen = false
}
struct TaskEntry {
    let id: TileID
    let item: Item
    let app: NSRunningApplication?
    let entry: WindowEntry?
    var caption: String? {
        guard app != nil else { return nil }
        if let title = entry?.title, !title.isEmpty { return title }
        return item.name
    }
}
class ShelfMenuSurface: NSView {
    var makeMenu: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
}

final class ShelfBackground: ShelfMenuSurface {
    static let solidColor = NSColor(srgbRed: 0.115, green: 0.12, blue: 0.13, alpha: 1)
    var blurred = false
    override var isOpaque: Bool { !blurred }
    override func draw(_ dirtyRect: NSRect) {
        (blurred ? NSColor.clear : Self.solidColor).setFill()
        dirtyRect.fill(using: .copy)
        let pixel = 1 / (window?.backingScaleFactor ?? 1)
        (blurred ? NSColor.white.withAlphaComponent(0.16) : NSColor(white:0.24,alpha:1)).setFill()
        let lineY = (window as? Bar)?.edge == .top ? bounds.minY : bounds.maxY - pixel
        NSRect(x:0,y:lineY,width:bounds.width,height:pixel).fill()
    }
}

final class Bar: NSPanel {
    var edge: ShelfEdge = .bottom
    var sizing = ShelfSizing(compact: false)
    let surface = ShelfBackground()
    private var backdrop: NSVisualEffectView?

    func setBlurred(_ blurred: Bool) {
        guard let root = contentView else { return }
        isOpaque = !blurred
        backgroundColor = blurred ? .clear : ShelfBackground.solidColor
        if blurred, backdrop == nil {
            let effect = ShelfBackdrop(frame: root.bounds)
            effect.autoresizingMask = [.width, .height]
            root.addSubview(effect, positioned: .below, relativeTo: surface)
            backdrop = effect
        } else if !blurred {
            backdrop?.removeFromSuperview()
            backdrop = nil
        }
        surface.blurred = blurred
        surface.layer?.isOpaque = !blurred
        surface.needsDisplay = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class Action: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}
class ShelfButton: NSButton {
    private var hover = false
    var selected = false
    private var area: NSTrackingArea?
    override init(frame: NSRect) {
        super.init(frame:frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect:.zero,options:[.inVisibleRect,.activeAlways,.mouseEnteredAndExited],owner:self)
        addTrackingArea(a); area = a
    }
    override func mouseEntered(with e: NSEvent) { hover = true; tint() }
    override func mouseExited(with e: NSEvent) { hover = false; tint() }
    var showsHover: Bool { hover }
    func tint() {
        let hover = showsHover
        let outlined = selected || hover
        layer?.cornerRadius = outlined ? 6 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(selected ? 0.2 : 0.12).cgColor
        layer?.borderWidth = outlined ? 1 / (window?.backingScaleFactor ?? 1) : 0
        layer?.backgroundColor = NSColor.white.withAlphaComponent(selected ? (hover ? 0.22 : 0.16) : (hover ? 0.08 : 0)).cgColor
    }
}

final class Tile: ShelfButton {
    static let maximumWidth: CGFloat = 204
    private static let trailingInset: CGFloat = 10
    private static let captionDrawingAllowance: CGFloat = 6
    private static let captionFont = NSFont.systemFont(ofSize:13, weight:.medium)
    private static let measuringLabel: NSTextField = {
        let label = NSTextField(labelWithString:"")
        label.font = captionFont
        label.maximumNumberOfLines = 1
        return label
    }()
    static func preferredWidth(for text: String?, sizing: ShelfSizing) -> CGFloat {
        guard !sizing.compact, let text else { return sizing.pinWidth }
        measuringLabel.stringValue = text
        let textWidth = ceil(measuringLabel.intrinsicContentSize.width) + captionDrawingAllowance
        return min(maximumWidth, sizing.captionX + textWidth + trailingInset)
    }

    let item: Item
    var press: (() -> Void)?
    var context: (() -> NSMenu)?
    var previewHover: ((Bool) -> Void)?
    var dismissPreview: (() -> Void)?
    var reorder: ((CGFloat) -> Void)?
    var finishDrag: (() -> Void)?
    var revealForFileDrag: (() -> Void)?
    private var fileHoverTimer: Timer?
    private var fileHovering = false
    override var showsHover: Bool { super.showsHover || fileHovering }
    private var dragImage: DragImage?
    private var pressPoint: NSPoint?
    private var cancelledClick = false
    private var dragging = false
    private let icon = NSImageView()
    private let caption = NSTextField(labelWithString:"")
    private let indicator = NSView()
    init(_ item: Item) {
        self.item = item
        super.init(frame: NSRect(x:0,y:0,width:48,height:44))
        isBordered = false
        imagePosition = .noImage
        title = ""
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 1.5
        indicator.isHidden = true
        addSubview(indicator)
        caption.font = Self.captionFont
        caption.textColor = .labelColor
        caption.lineBreakMode = .byTruncatingTail
        caption.maximumNumberOfLines = 1
        caption.cell?.truncatesLastVisibleLine = true
        addSubview(caption)
        target = self
        action = #selector(clicked)
        setAccessibilityLabel(item.name)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isEnabled && super.hitTest(point) != nil ? self : nil }
    override func menu(for event: NSEvent) -> NSMenu? {
        dismissPreview?()
        return context?()
    }
    override func mouseDown(with event: NSEvent) {
        dismissPreview?()
        guard !event.modifierFlags.contains(.control) else { super.mouseDown(with: event); return }
        dragImage?.cancel()
        dragImage = nil
        pressPoint = event.locationInWindow
        cancelledClick = false
        dragging = false
        highlight(true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let pressPoint, let strip = superview else { return }
        let cursor = event.locationInWindow
        if abs(cursor.y - pressPoint.y) >= 5 { cancelledClick = true }
        guard dragging || abs(cursor.x - pressPoint.x) >= 5 else { return }
        let point = NSPoint(x: cursor.x, y: pressPoint.y)
        highlight(false)
        if !dragging, let window {
            dragImage = DragImage(source: self, down: window.convertPoint(toScreen: pressPoint),
                                  backgroundColor: ShelfBackground.solidColor)
        }
        dragging = true
        if let window {
            let visible = window.convertToScreen(strip.convert(strip.visibleRect, to: nil))
            dragImage?.follow(window.convertPoint(toScreen: point), minimumX: visible.minX)
        }
        _ = strip.autoscroll(with: event)
        let local = strip.convert(point, from: nil)
        reorder?(local.x)
    }
    override func mouseUp(with event: NSEvent) {
        guard pressPoint != nil else { return }
        pressPoint = nil
        highlight(false)
        if dragging { dragging = false; finishDrag?(); dragImage?.finish() }
        else if !cancelledClick && isEnabled && bounds.contains(convert(event.locationInWindow, from: nil)) { clicked() }
    }
    @objc func clicked() { press?() }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with:event)
        if !fileHovering && NSEvent.pressedMouseButtons & 1 == 0 { previewHover?(true) }
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with:event)
        previewHover?(false)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        endFileHover()
        guard isEnabled, revealForFileDrag != nil,
              sender.draggingPasteboard.availableType(from: [.fileURL]) != nil else { return [] }
        dismissPreview?()
        fileHovering = true
        tint()
        let timer = Timer(timeInterval: 0.55, repeats: false) { [weak self] _ in
            guard let self, self.fileHovering, self.isEnabled, let window = self.window,
                  self.visibleRect.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)),
                  NSEvent.pressedMouseButtons & 1 != 0 else { return }
            self.revealForFileDrag?()
        }
        fileHoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        // The tile reveals a window. Only the destination inside that window accepts the drop.
        return []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { endFileHover() }
    override func draggingEnded(_ sender: NSDraggingInfo) { endFileHover() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endFileHover() }
        super.viewWillMove(toWindow: newWindow)
    }
    private func endFileHover() {
        fileHoverTimer?.invalidate()
        fileHoverTimer = nil
        if fileHovering { fileHovering = false; tint() }
    }

    func place(in targetFrame: NSRect, appearing: Bool, animate: Bool) {
        let oldX = frame.minX
        let modelX = layer?.position.x ?? 0
        let visualX = oldX + (layer?.presentation()?.position.x ?? modelX) - modelX
        if frame != targetFrame { frame = targetFrame }
        guard let layer, animate, !dragging else { return }
        if appearing {
            let fade = CABasicAnimation(keyPath:"opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.16
            fade.timingFunction = CAMediaTimingFunction(name:.easeOut)
            layer.add(fade, forKey:"tileAppearance")
        }
        // Lay out at the final position immediately; animate just the visual offset.
        guard appearing || oldX != targetFrame.minX else { return }
        let offset = appearing ? -5 : visualX - targetFrame.minX
        let slide = CABasicAnimation(keyPath:appearing ? "position.y" : "position.x")
        slide.isAdditive = true
        slide.fromValue = offset
        slide.toValue = 0
        slide.duration = 0.18
        slide.timingFunction = CAMediaTimingFunction(name:.easeOut)
        layer.add(slide, forKey:appearing ? "tileRise" : "tileShift")
    }

    func fadeOut(completion: @escaping () -> Void) {
        dragImage?.cancel()
        dragImage = nil
        endFileHover()
        revealForFileDrag = nil
        isEnabled = false
        setAccessibilityElement(false)
        toolTip = nil
        press = nil
        context = nil
        previewHover = nil
        alphaValue = CGFloat(layer?.presentation()?.opacity ?? 1)
        layer?.removeAnimation(forKey:"tileAppearance")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.13
            context.timingFunction = CAMediaTimingFunction(name:.easeIn)
            self.animator().alphaValue = 0
        } completionHandler: { completion() }
    }

    func update(image: NSImage, running: Bool, active: Bool, pinned: Bool, text: String?, sizing: ShelfSizing) {
        icon.image = image
        caption.stringValue = text ?? ""
        caption.isHidden = sizing.compact || text == nil
        let iconSize = sizing.iconSize
        let markHeight: CGFloat = sizing.compact ? 2 : 3
        let gap: CGFloat = sizing.compact ? 2 : 3
        let stackHeight = iconSize + (running ? gap + markHeight : 0)
        let stackMinY = bounds.midY - stackHeight / 2
        let iconY = isFlipped ? stackMinY : stackMinY + stackHeight - iconSize
        let iconCenterX = caption.isHidden ? bounds.midX : sizing.pinWidth / 2
        icon.frame = NSRect(x:iconCenterX-iconSize/2, y:iconY, width:iconSize, height:iconSize)
        indicator.isHidden = !running
        if running {
            let markWidth: CGFloat = active ? (sizing.compact ? 12 : 16) : (sizing.compact ? 6 : 8)
            let markY = isFlipped ? icon.frame.maxY + gap : stackMinY
            indicator.frame = NSRect(x:iconCenterX-markWidth/2, y:markY, width:markWidth, height:markHeight)
            indicator.layer?.backgroundColor = (active ? NSColor(srgbRed:0.38,green:0.83,blue:1,alpha:1) : NSColor.white).cgColor
        }
        let labelHeight = ceil(caption.intrinsicContentSize.height)
        caption.frame = NSRect(x:sizing.captionX, y:bounds.midY-labelHeight/2,
                               width:max(1,bounds.width-sizing.captionX-Self.trailingInset), height:labelHeight)
        selected = active; tint()
        let label = (text != nil && text != item.name) ? "\(item.name) — \(text!)" : item.name
        setAccessibilityLabel(label)
        toolTip = running ? nil : label + (pinned ? " · закреплено" : "") + (running ? " · запущено" : "") + "\nПравый клик — меню"
        setAccessibilityValue(active ? "Активно" : running ? "Запущено" : "Закреплено")
    }
}
final class Delegate: NSObject, NSApplicationDelegate {
    let ws = NSWorkspace.shared
    let defaults = CommandLine.arguments.contains("--ui-check") ? UserDefaults(suiteName:"local.taskshelf.layoutcheck")! : UserDefaults.standard
    var bar: Bar!
    var settingsWindow: NSWindow?
    let strip = ShelfMenuSurface()
    let scroll = NSScrollView()
    let desktopButton = DesktopButton(frame:.zero)
    let desktop = ShowDesktop()
    let menuBarEdge = MenuBarEdge()
    let fnCommand = FnCommand()
    lazy var screenshotShortcut = ScreenshotShortcut { [weak self] in self?.notify($0) }
    lazy var layoutShortcut = LayoutShortcut { [weak self] in self?.tray.nextInputLanguage() }
    let clockLabel = ShelfButton(frame:.zero)
    lazy var tray = Tray(self)
    let preview = WindowPreview()
    var pins: [Item] = []
    var tiles: [TileID:Tile] = [:]
    private var fadingTiles: [TileID:Tile] = [:]
    var snapshots: [pid_t:[WindowEntry]] = [:]
    var layoutOrder: [TileID] = []
    private var manualWindowOrder: [TileID] = []
    private var draggingTile: TileID?
    private lazy var appOrder = defaults.stringArray(forKey: "taskAppOrder") ?? []
    var observed: [CGWindowID:pid_t] = [:]
    private var monitors: [pid_t:WindowMonitor] = [:]
    private var nextReconciliation: TimeInterval = 0
    private var hadWindowAccess = false
    private var taskRenderPending = false
    private var lastClockMinute = -1
    var remembered: [pid_t:AXUIElement] = [:]
    var expanded: [(pid_t, AXUIElement, CGRect, CGRect)] = []
    var zoomMonitor: CFMachPort?
    var zoomCheck: DispatchWorkItem?
    var maximizedWindowCheck: DispatchWorkItem?
    var exitingFullScreen = Set<AXUIElement>()
    var firstTitleClick: FirstTitleClick?
    var titleBarClick: FirstTitleClick?
    var chatTitleDrag: ChatTitleDrag?
    var timer: Timer?
    let timeFormatter = DateFormatter()
    let dateFormatter = DateFormatter()
    var showsDate: Bool { defaults.bool(forKey:"showDate") }
    var geometry: NSRect = .zero
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        defaults.register(defaults:["showDate": true, ShelfSizing.preference: true])
        if let data = defaults.data(forKey:"pins"), let saved = try? JSONDecoder().decode([Item].self,from:data) { pins = saved }
        bar = Bar(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        bar.isReleasedWhenClosed = false
        bar.hasShadow = false
        bar.level = .floating
        bar.hidesOnDeactivate = false
        // Keep the shelf in place when a wallpaper click invokes Show Desktop.
        bar.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllApplications]
        bar.appearance = NSAppearance(named:.darkAqua)
        let glass = bar.surface
        glass.makeMenu = { [weak self] in self?.panelMenu() }
        strip.makeMenu = glass.makeMenu
        glass.wantsLayer = true
        let root = NSView()
        root.wantsLayer = true
        bar.contentView = root
        glass.frame = root.bounds
        glass.autoresizingMask = [.width, .height]
        root.addSubview(glass)
        updateShelfAppearance()
        ws.notificationCenter.addObserver(self, selector: #selector(updateShelfAppearance),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = false
        scroll.documentView = strip
        glass.addSubview(scroll)
        clockLabel.contentTintColor = .white
        clockLabel.isBordered = false
        clockLabel.target = tray
        clockLabel.action = #selector(Tray.showClock)
        clockLabel.setAccessibilityLabel("Часы")
        clockLabel.font = .monospacedDigitSystemFont(ofSize:13,weight:.medium)
        clockLabel.alignment = .center
        clockLabel.cell?.usesSingleLineMode = false
        clockLabel.cell?.wraps = true
        glass.addSubview(clockLabel)
        desktopButton.title = ""
        desktopButton.isBordered = false
        desktopButton.target = self
        desktopButton.action = #selector(toggleDesktop)
        updateDesktopLabel(false)
        glass.addSubview(desktopButton)
        tray.install(glass)
        if !CommandLine.arguments.contains("--ui-check") {
            if defaults.bool(forKey: ScreenshotShortcut.preference) && !screenshotShortcut.setEnabled(true) {
                defaults.set(false, forKey: ScreenshotShortcut.preference)
                DispatchQueue.main.async { self.notify(Self.screenshotShortcutUnavailable) }
            }
            let mode = DockMode.saved(in: defaults)
            tray.configureDock(mode == .taskShelf && !AXIsProcessTrusted() ? .system : mode)
        }
        timeFormatter.dateFormat = "HH:mm"
        dateFormatter.dateFormat = "dd.MM.yyyy"
        let nc = ws.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            nc.addObserver(self, selector:#selector(workspaceChanged(_:)), name:name, object:nil)
        }
        nc.addObserver(self, selector:#selector(activeSpaceChanged), name:NSWorkspace.activeSpaceDidChangeNotification, object:nil)
        nc.addObserver(self, selector:#selector(refresh), name:NSWorkspace.didWakeNotification, object:nil)
        NotificationCenter.default.addObserver(self, selector:#selector(refresh),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        timer = Timer.scheduledTimer(timeInterval:2,target:self,selector:#selector(maintenance),userInfo:nil,repeats:true)
        timer?.tolerance = 0.4
        refresh()
        bar.orderFrontRegardless()
        if CommandLine.arguments.contains("--ui-check") {
            DispatchQueue.main.async {
                guard self.bar.isVisible, !self.tiles.isEmpty,
                      let tile = self.tiles.values.first, let screen = NSScreen.screens.first,
                      screen.frame.contains(self.bar.frame),
                      self.bar.frame == self.bar.edge.shelfFrame(on: screen, height: self.bar.sizing.height),
                      let menu = tile.context?() else { exit(2) }
                guard self.tray.apple.glyph.image != nil,
                      self.tray.apple.frame.maxX <= self.scroll.frame.minX,
                      let firstControl = self.tray.buttons.first,
                      self.scroll.frame.maxX <= firstControl.frame.minX,
                      !firstControl.title.isEmpty,
                      self.tray.buttons.contains(where: { $0.toolTip?.hasPrefix("Wi-Fi · ") == true && $0.image != nil }),
                      self.bar.contentView?.layer?.cornerRadius == 0
                else { exit(9) }
                let small = !self.defaults.bool(forKey: ShelfSizing.preference)
                guard self.bar.frame.height == (small ? 36 : 50),
                      tile.frame.height == self.bar.sizing.tileHeight,
                      tile.subviews.compactMap({ $0 as? NSImageView }).first?.frame.height == (small ? 20 : 30),
                      self.bar.surface.bounds.contains(self.clockLabel.frame),
                      self.tray.buttons.allSatisfy({ self.bar.surface.bounds.contains($0.frame) }) else { exit(19) }
                print("PASS: shelf and icon dimensions, small icons:", small)
                let blurred = self.defaults.bool(forKey: "blurShelfBackground") && !self.ws.accessibilityDisplayShouldReduceTransparency
                guard let root = self.bar.contentView,
                      self.bar.isOpaque == !blurred, self.bar.surface.isOpaque == !blurred,
                      self.bar.surface.frame == root.bounds,
                      root.hitTest(NSPoint(x: 1, y: 1)) === self.bar.surface,
                      self.bar.alphaValue == 1 else { exit(15) }
                let effects = root.subviews.compactMap { $0 as? NSVisualEffectView }
                if blurred {
                    guard effects.count == 1, let effect = effects.first, effect === root.subviews.first,
                          effect.frame == root.bounds, effect.blendingMode == .behindWindow else { exit(16) }
                } else if !effects.isEmpty { exit(17) }
                print("PASS: shelf background and hit testing, blur:", blurred)
                print("PASS: Apple menu, input source, Wi-Fi, square panel, separate task and tray areas")
                let edge = self.bar.edge
                let usable = self.usableFrame(on: screen)
                let expected = accessibilityFrame(usable, primary: screen)
                let visible = accessibilityFrame(screen.visibleFrame, primary: screen)
                guard !usable.intersects(self.bar.frame),
                      shelfLimitedZoom(visible, visible: visible, usable: expected) == expected else { exit(13) }
                let actions: [() -> Void] = [self.tray.showApple, self.tray.showClock] +
                    self.tray.buttons.filter { button in
                        ["Wi-Fi", "Звук", "Аккумулятор"].contains { button.toolTip?.hasPrefix($0) == true }
                    }.map { button in { self.tray.invoke(button) } }
                for open in actions {
                    open()
                    guard let panel = self.bar.childWindows?.compactMap({ $0 as? SlidingShelfPanel }).last(where: { !$0.isClosing }),
                          screen.visibleFrame.contains(panel.frame), panel.frame.height > 0,
                          panel.frame.minY == edge.popupY(beside: self.bar.frame, height: panel.frame.height) else { exit(14) }
                    if panel.anchor === self.tray.apple {
                        func containsBackdrop(_ view: NSView) -> Bool {
                            view is ShelfBackdrop || view.subviews.contains(where: containsBackdrop)
                        }
                        guard let content = panel.contentView, containsBackdrop(content) == blurred else { exit(18) }
                        print("PASS: Start menu follows shelf blur:", blurred)
                    }
                }
                self.tray.dismissForPlacementChange()
                print("PASS: Start, calendar and tray panels open toward the desktop at the " + edge.rawValue + " edge")

                let already = self.pins.contains { $0.key == tile.item.key }
                guard let entry = menu.items.first(where:{$0.title == (already ? "Открепить" : "Закрепить")}) else { exit(3) }
                self.invoke(entry)
                guard self.pins.contains(where:{$0.key == tile.item.key}) != already,
                      let data = self.defaults.data(forKey:"pins"),
                      try! JSONDecoder().decode([Item].self,from:data) == self.pins else { exit(4) }
                let next = self.menu(tile.item)
                self.invoke(next.items.first(where:{$0.title == (already ? "Закрепить" : "Открепить")})!)
                print("PASS: bar at selected screen edge, \(self.tiles.count) app icons, contextual pin and unpin with persistence. AX permission: \(AXIsProcessTrusted())")
                guard let app = self.liveApps().first else { exit(5) }
                let pid = app.processIdentifier
                // Exercise the view model with two distinct accessibility identities.
                let one = AXUIElementCreateApplication(pid), two = AXUIElementCreateSystemWide()
                let first = WindowEntry(window:one,title:"Я",focused:true)
                let second = WindowEntry(window:two,title:String(repeating:"Длинный заголовок ",count:4),focused:false)
                self.snapshots[pid] = [first,second]
                self.render()
                let firstID = TileID.window(pid,one), secondID = TileID.window(pid,two)
                guard let a = self.tiles[firstID], let b = self.tiles[secondID],
                      a.frame.width == Tile.preferredWidth(for:first.title, sizing:self.bar.sizing), a.frame.width < 116,
                      b.frame.width == (small ? self.bar.sizing.pinWidth : 204),
                      a.subviews.compactMap({ $0 as? NSTextField }).first?.isHidden == small,
                      b.subviews.compactMap({ $0 as? NSTextField }).first?.isHidden == small,
                      !a.frame.intersects(b.frame),
                      a.accessibilityLabel()?.contains(first.title) == true, b.accessibilityLabel()?.contains(second.title) == true
                else { exit(6) }
                let oldOrder = self.layoutOrder
                self.snapshots[pid] = [second,first]
                self.render()
                guard oldOrder == self.layoutOrder else { exit(7) }
                self.snapshots[pid] = [first]
                self.render()
                guard self.tiles[firstID] === a, self.tiles[secondID] == nil else { exit(8) }
                print("PASS: separate window buttons, correct caption visibility and widths, stable order, removal on close")
                let item = a.item
                let savedPins = self.pins
                self.pins.removeAll { $0.key == item.key }
                self.snapshots[pid] = []
                self.render()
                guard !self.tiles.values.contains(where:{ $0.item.key == item.key }) else { exit(10) }
                self.pins.append(item)
                self.render()
                guard let pin = self.tiles[.app(item.key)], pin.frame.width == self.bar.sizing.pinWidth,
                      pin.context?().item(withTitle:"Закрыть окно") == nil else { exit(11) }
                self.snapshots[pid] = [second]
                self.render()
                guard self.tiles[secondID] != nil, self.tiles[.app(item.key)] == nil else { exit(12) }
                self.pins = savedPins
                print("PASS: closing last window removes task, preserves compact pin, reopening restores task")
                NSApp.terminate(nil)
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        monitors.values.forEach { $0.stop() }
        monitors.removeAll()
        _ = fnCommand.setEnabled(false)
        layoutShortcut.stop()
        _ = screenshotShortcut.setEnabled(false)
        menuBarEdge.stop()
        if !CommandLine.arguments.contains("--ui-check") {
            _ = SystemDockVisibility.apply(hidden: false, defaults: defaults)
        }
    }

    func liveApps() -> [NSRunningApplication] {
        ws.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.bundleURL != nil && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }
    @objc private func workspaceChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { refresh(); return }
        syncWindows(changedPID: app.processIdentifier)
        if note.name == NSWorkspace.didActivateApplicationNotification { scheduleMaximizedWindowFit() }
        renderTasks()
    }

    @objc private func activeSpaceChanged() {
        refresh()
        scheduleMaximizedWindowFit()
    }

    @objc func refresh() {
        nextReconciliation = ProcessInfo.processInfo.systemUptime + 30
        syncWindows(changedPID: nil)
        render()
    }

    private func syncWindows(changedPID: pid_t?) {
        let apps = liveApps()
        hadWindowAccess = AXIsProcessTrusted()
        observed = observedWindows(previous: observed)
        let live = Set(apps.map(\.processIdentifier))
        for pid in Array(monitors.keys) where !hadWindowAccess || !live.contains(pid) {
            monitors.removeValue(forKey: pid)?.stop()
            snapshots.removeValue(forKey: pid)
        }
        if hadWindowAccess && !CommandLine.arguments.contains("--ui-check") {
            if zoomMonitor == nil { monitorTitleBarZoom() }
            _ = fnCommand.setEnabled(defaults.bool(forKey: "fnCommandLetters"))
            _ = layoutShortcut.apply(LayoutShortcutMode.saved(in: defaults))
            if defaults.bool(forKey: "blockMenuBarHover") { _ = menuBarEdge.start() }
            for app in apps {
                let pid = app.processIdentifier
                if let existing = monitors[pid], !existing.app.isTerminated {
                    if changedPID == nil || changedPID == pid { existing.request() }
                    continue
                }
                monitors.removeValue(forKey: pid)?.stop()
                snapshots.removeValue(forKey: pid)
                monitors[pid] = WindowMonitor(app: app) { [weak self] entries in
                    guard let self, !app.isTerminated, self.snapshots[pid] != entries else { return }
                    let previous = self.snapshots[pid]?.first(where: { $0.focused })
                    if app.isActive, let focused = entries?.first(where: { $0.focused }),
                       focused.window != previous?.window || focused.fullScreen != previous?.fullScreen {
                        self.scheduleMaximizedWindowFit()
                    }
                    self.snapshots[pid] = entries
                    self.scheduleTaskRender()
                }
                monitors[pid]?.request()
            }
        }
    }

    private func scheduleTaskRender() {
        guard !taskRenderPending else { return }
        taskRenderPending = true
        DispatchQueue.main.async {
            self.taskRenderPending = false
            self.renderTasks()
        }
    }

    @objc private func maintenance() {
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextReconciliation || AXIsProcessTrusted() != hadWindowAccess {
            refresh()
            return
        }
        // WindowServer also covers apps which omit AX notifications or have no AX window list.
        let latest = observedWindows(previous: observed)
        if observed != latest {
            let changed = Set(observed.compactMap { latest[$0.key] != $0.value ? $0.value : nil })
                .union(latest.compactMap { observed[$0.key] != $0.value ? $0.value : nil })
            observed = latest
            for pid in changed { monitors[pid]?.request() }
            if changed.contains(where: { snapshots[$0] == nil }) { scheduleTaskRender() }
        }
        let minute = Int(Date().timeIntervalSince1970 / 60)
        if minute != lastClockMinute || tray.statusChanged() { layoutControls() }
        tray.scan()
        if tray.dockVisible { tray.refreshVisibleDock() }
    }
    private func updateClock(at date: Date, rightEdge: CGFloat) {
        let alignment = NSMutableParagraphStyle()
        alignment.alignment = .center
        let title = NSMutableAttributedString(string:timeFormatter.string(from:date), attributes:[
            .font: NSFont.monospacedDigitSystemFont(ofSize:bar.sizing.compact ? 12 : 13, weight:.medium),
            .foregroundColor: NSColor.white, .paragraphStyle: alignment
        ])
        if showsDate {
            title.append(NSAttributedString(string:"\n" + dateFormatter.string(from:date), attributes:[
                .font: NSFont.monospacedDigitSystemFont(ofSize:bar.sizing.compact ? 10 : 11, weight:.regular),
                .foregroundColor: NSColor(white:0.86, alpha:1), .paragraphStyle: alignment
            ]))
        }
        clockLabel.attributedTitle = title
        clockLabel.setAccessibilityValue(title.string.replacingOccurrences(of:"\n", with:", "))
        let width = max(54, ceil(title.size().width) + 12)
        clockLabel.frame = NSRect(x:rightEdge-width, y:bar.sizing.controlY, width:width, height:bar.sizing.controlHeight)
    }
    @objc func updateShelfAppearance() {
        bar.setBlurred(defaults.bool(forKey: "blurShelfBackground") && !ws.accessibilityDisplayShouldReduceTransparency)
    }

    func render() {
        layoutControls()
        renderTasks()
    }
    func layoutControls() {
        guard let screen = NSScreen.screens.first, bar != nil else { return }
        let edge = ShelfEdge(rawValue: defaults.string(forKey: "shelfEdge") ?? "") ?? .bottom
        let sizing = ShelfSizing(compact: !defaults.bool(forKey: ShelfSizing.preference))
        let frame = edge.shelfFrame(on: screen, height: sizing.height)
        if geometry != frame || bar.edge != edge {
            let previous = geometry != .zero && (bar.edge != edge || bar.sizing != sizing) ? usableFrame(on: screen) : nil
            tray.dismissForPlacementChange()
            preview.hide()
            bar.edge = edge
            bar.sizing = sizing
            geometry = frame
            bar.setFrame(frame, display: true)
            bar.surface.needsDisplay = true
            if let previous {
                tray.layoutPinnedDock()
                refitWindows(from: previous, on: screen)
            }
        }
        let width = frame.width
        let desktopWidth: CGFloat = 12
        desktopButton.frame = NSRect(x:width-desktopWidth, y:0, width:desktopWidth, height:frame.height)
        let now = Date()
        lastClockMinute = Int(now.timeIntervalSince1970 / 60)
        updateClock(at:now, rightEdge:desktopButton.frame.minX-3)
        let trayLeft = tray.layout(width)
        let tasksLeft = tray.apple.frame.maxX + 4
        let tasksFrame = NSRect(x: tasksLeft, y: 3, width: max(1, trayLeft - tasksLeft - 3), height: sizing.tileHeight)
        if scroll.frame != tasksFrame {
            scroll.frame = tasksFrame
            updateStripWidth()
        }
    }
    private func renderTasks() {
        guard bar != nil else { return }
        let apps = liveApps()
        let pids = Set(apps.map { $0.processIdentifier })
        remembered = remembered.filter { pids.contains($0.key) }
        expanded.removeAll { !pids.contains($0.0) }
        let observedOwners = Set(observed.values)
        let entries = apps.compactMap { app in app.bundleURL.map { Item($0,name:app.localizedName) } }
        let ranks = Dictionary(uniqueKeysWithValues:layoutOrder.enumerated().map { ($1,$0) })
        var tasks: [TaskEntry] = []
        let items = ordered(pins, entries)
        let byApp = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0) })
        for key in arranged(items.map(\.key), preferred: appOrder) {
            guard let item = byApp[key] else { continue }
            let matches = apps.filter { ($0.bundleIdentifier ?? $0.bundleURL?.standardizedFileURL.path) == item.key }
            var appTasks: [TaskEntry] = []
            for app in matches {
                let pid = app.processIdentifier
                if let windows = snapshots[pid] {
                    appTasks.append(contentsOf:windows.map {
                        TaskEntry(id:.window(pid,$0.window),item:item,app:app,entry:$0)
                    })
                } else if observedOwners.contains(pid), !appTasks.contains(where:{ $0.id == .app(item.key) }) {
                    appTasks.append(TaskEntry(id:.app(item.key),item:item,app:app,entry:nil))
                }
            }
            if appTasks.isEmpty && pins.contains(where:{ $0.key == item.key }) {
                tasks.append(TaskEntry(id:.app(item.key),item:item,app:nil,entry:nil))
            } else {
                tasks.append(contentsOf:appTasks.sorted { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) })
            }
        }
        if !manualWindowOrder.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
            manualWindowOrder = arranged(tasks.map(\.id), preferred: manualWindowOrder)
            tasks = manualWindowOrder.compactMap { byID[$0] }
        }
        layoutOrder = tasks.map { $0.id }
        if let draggingTile, !layoutOrder.contains(draggingTile) { self.draggingTile = nil }
        let keys = Set(layoutOrder)
        let animateTiles = bar.isVisible && !ws.accessibilityDisplayShouldReduceMotion
        for key in Array(tiles.keys) where !keys.contains(key) {
            if let tile = tiles.removeValue(forKey:key) {
                if preview.anchor === tile { preview.hide() }
                if animateTiles {
                    fadingTiles[key] = tile
                    tile.fadeOut { [weak self, weak tile] in
                        guard let self, let tile, self.fadingTiles[key] === tile else { return }
                        tile.removeFromSuperview()
                        self.fadingTiles.removeValue(forKey:key)
                        self.updateStripWidth()
                    }
                } else {
                    tile.removeFromSuperview()
                }
            }
        }
        var x: CGFloat = 0
        for task in tasks {
            let item = task.item
            let tile = tiles[task.id] ?? Tile(item)
            let appearing = tile.superview == nil
            if appearing {
                fadingTiles.removeValue(forKey:task.id)?.removeFromSuperview()
                tiles[task.id] = tile
                strip.addSubview(tile)
            }
            tile.press = { [weak self] in
                guard let self else { return }
                if let app = task.app, let entry = task.entry, !app.isTerminated {
                    let focused = element(AXUIElementCreateApplication(app.processIdentifier),kAXFocusedWindowAttribute)
                    if app.isActive, focused.map({ CFEqual($0,entry.window) }) == true, !minimized(entry.window) {
                        if !setMini(entry.window,true) { self.notify("Это окно не поддерживает сворачивание.") }
                    } else { self.bring(entry.window,app) }
                } else if let app = task.app, !app.isTerminated { self.toggle(item,app) }
                else { self.launch(item) }
                self.refresh()
            }
            tile.revealForFileDrag = task.app.map { app in
                { [weak self] in
                    guard let self, !app.isTerminated else { return }
                    if let entry = task.entry {
                        self.bring(entry.window, app, reportFailure: false)
                    } else {
                        app.unhide()
                        app.activate(options: [])
                    }
                }
            }
            if task.app == nil && preview.anchor === tile { preview.hide() }
            tile.reorder = { [weak self] x in self?.moveTask(task.id, toX: x) }
            tile.finishDrag = { [weak self] in self?.draggingTile = nil }
            tile.dismissPreview = { [weak self] in self?.preview.hide() }
            tile.previewHover = { [weak self, weak tile] hovering in
                guard let self, let tile else { return }
                if hovering && self.draggingTile == nil && (!self.tray.dockVisible || self.tray.dockPinned) { self.preview.show(for:tile, task:task, frame:windowRect, close: self.closeWindow) }
                else if self.preview.anchor === tile { self.preview.leftTile() }
            }
            tile.context = { [weak self] in self?.menu(item,target:task.entry?.window,owner:task.app) ?? NSMenu() }
            let width = Tile.preferredWidth(for:task.caption, sizing:bar.sizing)
            tile.place(in:NSRect(x:x,y:0,width:width,height:bar.sizing.tileHeight), appearing:appearing, animate:animateTiles)
            x += width + 4
            let active = task.app?.isActive == true && (task.entry?.focused ?? true)
            tile.update(image:task.app?.icon ?? ws.icon(forFile:item.path),running:task.app != nil,active:active,pinned:pins.contains(where:{$0.key==item.key}),text:task.caption, sizing:bar.sizing)
        }
        updateStripWidth()
    }
    private func moveTask(_ id: TileID, toX x: CGFloat) {
        guard let index = layoutOrder.firstIndex(of: id) else { return }
        draggingTile = id
        preview.hide()
        let centers = layoutOrder.compactMap { tiles[$0]?.frame.midX }
        guard centers.count == layoutOrder.count else { return }
        let target = dragDestination(from: index, centers: centers, x: x)
        guard index != target else { return }
        var moved = layoutOrder
        moved.insert(moved.remove(at: index), at: target)
        manualWindowOrder = moved
        var seen = Set<String>()
        let apps = moved.compactMap { tiles[$0]?.item.key }.filter { seen.insert($0).inserted }
        appOrder = rememberedOrder(apps, previous: appOrder)
        defaults.set(appOrder, forKey: "taskAppOrder")
        render()
    }

    private func updateStripWidth() {
        let lastTile = tiles.values.map { $0.frame.maxX }.max() ?? 0
        let lastFadingTile = fadingTiles.values.map { $0.frame.maxX }.max() ?? 0
        strip.frame.size = NSSize(width:max(scroll.contentSize.width, lastTile, lastFadingTile),height:bar.sizing.tileHeight)
    }
    private func updateDesktopLabel(_ showingDesktop: Bool) {
        let label = showingDesktop ? "Восстановить окна" : "Показать рабочий стол"
        desktopButton.setAccessibilityLabel(label)
        desktopButton.toolTip = label
    }
    @objc private func toggleDesktop() {
        preview.hide()
        desktop.toggle(apps:liveApps(), frontmost:ws.frontmostApplication) { [weak self] showingDesktop in
            self?.updateDesktopLabel(showingDesktop)
            self?.refresh()
        }
    }
    func launch(_ item: Item) {
        let url = FileManager.default.fileExists(atPath:item.path) ? item.url : ws.urlForApplication(withBundleIdentifier:item.key)
        guard let url else { notify("Приложение не найдено. Закрепите его заново."); return }
        ws.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration()) { _,error in
            if let error { DispatchQueue.main.async { self.notify(error.localizedDescription) } }
        }
    }
    func toggle(_ item: Item, _ app: NSRunningApplication) {
        guard AXIsProcessTrusted() else {
            if app.isActive { app.hide() } else { app.unhide(); app.activate(options:[]) }
            return
        }
        let (focused,all) = windows(app)
        if app.isActive, let window = focused ?? all.first(where:{!minimized($0)}), !minimized(window) {
            if setMini(window,true) { remembered[app.processIdentifier] = window }
            else { notify("Это окно не поддерживает сворачивание.") }
            return
        }
        let previous = remembered[app.processIdentifier].flatMap { last in all.first { CFEqual($0,last) && minimized($0) } }
        if let window = previous ?? focused ?? all.first(where:{!minimized($0)}) ?? all.first {
            bring(window,app)
        } else { launch(item) }
    }
    @discardableResult
    func bring(_ window: AXUIElement, _ app: NSRunningApplication, reportFailure: Bool = true) -> Bool {
        if minimized(window) && !setMini(window,false) {
            if reportFailure { notify("Не удалось восстановить окно.") }
            return false
        }
        app.unhide()
        app.activate(options:[])
        _ = AXUIElementPerformAction(window,kAXRaiseAction as CFString)
        remembered.removeValue(forKey: app.processIdentifier)
        return true
    }
    func writeFrame(_ rect: CGRect, to w: AXUIElement) -> Bool {
        var pos = rect.origin, sz = rect.size
        guard let p = AXValueCreate(.cgPoint,&pos), let s = AXValueCreate(.cgSize,&sz) else { return false }
        guard AXUIElementSetAttributeValue(w,kAXPositionAttribute as CFString,p) == .success else { return false }
        return AXUIElementSetAttributeValue(w,kAXSizeAttribute as CFString,s) == .success
    }
    func fit(_ w: AXUIElement,_ app: NSRunningApplication) {
        bring(w,app)
        guard let current = windowRect(w), let primary = NSScreen.screens.first else { return }
        func overlap(_ screen: NSScreen) -> CGFloat {
            let r = accessibilityFrame(screen.frame,primary:primary).intersection(current)
            return r.isNull ? 0 : r.width*r.height
        }
        guard let screen = NSScreen.screens.max(by:{overlap($0)<overlap($1)}) else { return }
        toggleFittedFrame(w, app: app, current: current, on: screen, reportFailure: true)
    }

    func toggleFittedFrame(_ w: AXUIElement, app: NSRunningApplication, current: CGRect, on screen: NSScreen, reportFailure: Bool) {
        guard let primary = NSScreen.screens.first else { return }
        let saved = expanded.first { CFEqual(w,$0.1) }
        let restoring = saved.map { nearlyEqual($0.3,current) } ?? false
        let goal = restoring ? saved!.2 : accessibilityFrame(usableFrame(on:screen),primary:primary)
        guard writeFrame(goal, to:w) else {
            _ = writeFrame(current, to:w)
            if reportFailure { notify("Приложение ограничивает изменение размера этого окна.") }
            return
        }
        expanded.removeAll { CFEqual(w,$0.1) }
        if !restoring, let actual = windowRect(w) { expanded.append((app.processIdentifier,w,current,actual)) }
    }
    func notify(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Панель задач"; alert.informativeText = message
        alert.runModal()
    }
    @objc func invoke(_ sender: NSMenuItem) { (sender.representedObject as? Action)?.run() }
    func add(_ menu: NSMenu,_ title:String, symbol: String? = nil,_ run:@escaping ()->Void) {
        let m = NSMenuItem(title:title,action:#selector(invoke(_:)),keyEquivalent:"")
        m.image = symbol.flatMap { NSImage(systemSymbolName:$0, accessibilityDescription:nil) }
        m.target = self; m.representedObject = Action(run); menu.addItem(m)
    }
    func save() { if let data = try? JSONEncoder().encode(pins) { defaults.set(data,forKey:"pins") }; refresh() }
    func menu(_ item: Item, target: AXUIElement? = nil, owner: NSRunningApplication? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle:item.name,action:nil,keyEquivalent:"")
        let pinned = pins.contains(where:{$0.key == item.key})
        add(menu,pinned ? "Открепить" : "Закрепить", symbol: pinned ? "pin.slash" : "pin") {
            if pinned { self.pins.removeAll { $0.key == item.key } } else { self.pins.append(item) }
            self.save()
        }
        guard let app = owner, !app.isTerminated else { return menu }
        if AXIsProcessTrusted() {
            let (focused,all) = windows(app)
            if let w = target ?? focused ?? all.first, (attr(w,"AXFullScreen") as? Bool) != true {
                var writable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(w,kAXSizeAttribute as CFString,&writable) == .success && writable.boolValue {
                    add(menu,"Развернуть / вернуть размер", symbol: "arrow.up.left.and.arrow.down.right") { self.fit(w,app) }
                }
            }
            if !all.isEmpty { menu.addItem(.separator()) }
            for (idx,w) in all.enumerated() {
                let title = attr(w,kAXTitleAttribute) as? String ?? ""
                add(menu,(minimized(w) ? "↑  " : "") + (title.isEmpty ? "Окно \(idx+1)" : title)) { self.bring(w,app) }
            }
            // Bind the command when the menu opens, even if focus changes later.
            if let w = target ?? focused ?? (all.count == 1 ? all.first : nil) {
                menu.addItem(.separator())
                add(menu,"Закрыть окно", symbol: "xmark.rectangle") {
                    self.closeWindow(w, app)
                }
            }
        } else {
            menu.addItem(.separator())
            let close = menu.addItem(withTitle:"Закрыть окно",action:nil,keyEquivalent:"")
            close.isEnabled = false
            close.toolTip = "Для закрытия окон включите TaskShelf в разделе «Универсальный доступ»."
            add(menu,"Разрешить доступ к окнам…", symbol: "accessibility") { self.requestWindowAccess() }
        }
        return menu
    }
    private func closeWindow(_ window: AXUIElement, _ app: NSRunningApplication) {
        guard app.bundleIdentifier == "com.tdesktop.Telegram" else {
            pressCloseButton(of: window)
            return
        }
        // Telegram Desktop can acknowledge AXPress without closing. Send its Close Window
        // shortcut only after the selected window has been restored and focused.
        guard bring(window, app) else { return }
        Task { @MainActor in
            let root = AXUIElementCreateApplication(app.processIdentifier)
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !app.isTerminated, attr(window, kAXRoleAttribute) != nil else { return }
                if let focused = element(root, kAXFocusedWindowAttribute),
                   CFEqual(focused, window), !minimized(window) {
                    // ANSI W is virtual key 13. Deliver both events to Telegram itself.
                    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 13, keyDown: true),
                          let up = CGEvent(keyboardEventSource: nil, virtualKey: 13, keyDown: false) else {
                        notify("Не удалось отправить Telegram команду закрытия.")
                        return
                    }
                    for event in [down, up] {
                        event.flags = .maskCommand
                        event.postToPid(app.processIdentifier)
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    refresh()
                    return
                }
            }
            notify("Не удалось выбрать окно Telegram для закрытия.")
        }
    }

    private func pressCloseButton(of window: AXUIElement) {
        guard let button = element(window, kAXCloseButtonAttribute),
              AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            notify("Не удалось закрыть выбранное окно.")
            return
        }
        refresh()
    }

    func requestWindowAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
        if let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            ws.open(url)
        }
    }
    func panelMenu() -> NSMenu {
        let m = NSMenu()
        add(m,"Диспетчер задач", symbol: "waveform.path.ecg") {
            guard let url = self.ws.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else {
                self.notify("Не удалось найти приложение «Мониторинг системы».")
                return
            }
            self.launch(Item(url))
        }
        add(m,"Настройки TaskShelf…", symbol: "gearshape") { self.showSettings() }
        m.addItem(.separator())
        add(m,"Закрепить приложение…", symbol: "pin") {
            let p = NSOpenPanel()
            p.directoryURL = URL(fileURLWithPath:"/Applications"); p.allowedContentTypes = [.applicationBundle]
            p.canChooseFiles = true; p.canChooseDirectories = false
            if p.runModal() == .OK, let u = p.url {
                let item = Item(u)
                if !self.pins.contains(where:{$0.key == item.key}) { self.pins.append(item); self.save() }
            }
        }
        m.addItem(.separator()); add(m,"Завершить панель", symbol: "power") { NSApp.terminate(nil) }
        return m
    }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.run()
