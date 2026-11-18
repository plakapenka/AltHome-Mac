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
struct WindowEntry {
    let window: AXUIElement
    let title: String
    let focused: Bool
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
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed:0.115,green:0.12,blue:0.13,alpha:1).setFill()
        dirtyRect.fill()
        let pixel = 1 / (window?.backingScaleFactor ?? 1)
        NSColor(white:0.24,alpha:1).setFill()
        NSRect(x:0,y:bounds.maxY-pixel,width:bounds.width,height:pixel).fill()
    }
}

final class Bar: NSPanel {
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
    func tint() {
        let outlined = selected || hover
        layer?.cornerRadius = outlined ? 6 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(selected ? 0.2 : 0.12).cgColor
        layer?.borderWidth = outlined ? 1 / (window?.backingScaleFactor ?? 1) : 0
        layer?.backgroundColor = NSColor.white.withAlphaComponent(selected ? (hover ? 0.22 : 0.16) : (hover ? 0.08 : 0)).cgColor
    }
}

final class Tile: ShelfButton {
    static let maximumWidth: CGFloat = 204
    private static let captionX: CGFloat = 44
    private static let trailingInset: CGFloat = 10
    private static let captionDrawingAllowance: CGFloat = 6
    private static let captionFont = NSFont.systemFont(ofSize:13, weight:.medium)
    private static let measuringLabel: NSTextField = {
        let label = NSTextField(labelWithString:"")
        label.font = captionFont
        label.maximumNumberOfLines = 1
        return label
    }()
    static func preferredWidth(for text: String?) -> CGFloat {
        guard let text else { return 48 }
        measuringLabel.stringValue = text
        let textWidth = ceil(measuringLabel.intrinsicContentSize.width) + captionDrawingAllowance
        return min(maximumWidth, captionX + textWidth + trailingInset)
    }

    let item: Item
    var press: (() -> Void)?
    var context: (() -> NSMenu)?
    var previewHover: ((Bool) -> Void)?
    var dismissPreview: (() -> Void)?
    var reorder: ((CGFloat) -> Void)?
    var finishDrag: (() -> Void)?
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
            dragImage = DragImage(source: self, down: window.convertPoint(toScreen: pressPoint))
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
        previewHover?(true)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with:event)
        previewHover?(false)
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

    func update(image: NSImage, running: Bool, active: Bool, pinned: Bool, text: String?) {
        icon.image = image
        caption.stringValue = text ?? ""
        caption.isHidden = text == nil
        let iconSize: CGFloat = 30
        let markHeight: CGFloat = 3
        let gap: CGFloat = 3
        let stackHeight = iconSize + (running ? gap + markHeight : 0)
        let stackMinY = bounds.midY - stackHeight / 2
        let iconY = isFlipped ? stackMinY : stackMinY + stackHeight - iconSize
        let iconCenterX = text == nil ? bounds.midX : 24
        icon.frame = NSRect(x:iconCenterX-iconSize/2, y:iconY, width:iconSize, height:iconSize)
        indicator.isHidden = !running
        if running {
            let markWidth: CGFloat = active ? 16 : 8
            let markY = isFlipped ? icon.frame.maxY + gap : stackMinY
            indicator.frame = NSRect(x:iconCenterX-markWidth/2, y:markY, width:markWidth, height:markHeight)
            indicator.layer?.backgroundColor = (active ? NSColor(srgbRed:0.38,green:0.83,blue:1,alpha:1) : NSColor.white).cgColor
        }
        let labelHeight = ceil(caption.intrinsicContentSize.height)
        caption.frame = NSRect(x:Self.captionX, y:bounds.midY-labelHeight/2,
                               width:max(1,bounds.width-Self.captionX-Self.trailingInset), height:labelHeight)
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
    var querying = false
    var remembered: [pid_t:AXUIElement] = [:]
    var expanded: [(pid_t, AXUIElement, CGRect, CGRect)] = []
    var zoomMonitor: CFMachPort?
    var titleBarClick: TitleBarClick?
    var chatTitleDrag: ChatTitleDrag?
    var timer: Timer?
    let timeFormatter = DateFormatter()
    let dateFormatter = DateFormatter()
    var showsDate: Bool { defaults.bool(forKey:"showDate") }
    var geometry: NSRect = .zero
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        defaults.register(defaults:["showDate":true])
        if let data = defaults.data(forKey:"pins"), let saved = try? JSONDecoder().decode([Item].self,from:data) { pins = saved }
        bar = Bar(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        bar.isReleasedWhenClosed = false
        bar.isOpaque = true
        bar.hasShadow = false
        bar.backgroundColor = NSColor(srgbRed:0.115,green:0.12,blue:0.13,alpha:1)
        bar.level = .floating
        bar.hidesOnDeactivate = false
        bar.collectionBehavior = [.canJoinAllSpaces,.ignoresCycle,.fullScreenNone]
        bar.appearance = NSAppearance(named:.darkAqua)
        let glass = ShelfBackground()
        glass.makeMenu = { [weak self] in self?.panelMenu() }
        strip.makeMenu = glass.makeMenu
        glass.wantsLayer = true
        bar.contentView = glass
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
            let mode = DockMode.saved(in: defaults)
            tray.configureDock(mode == .taskShelf && !AXIsProcessTrusted() ? .system : mode)
        }
        timeFormatter.dateFormat = "HH:mm"
        dateFormatter.dateFormat = "dd.MM.yyyy"
        let nc = ws.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            nc.addObserver(self,selector:#selector(refresh),name:name,object:nil)
        }
        NotificationCenter.default.addObserver(self, selector:#selector(refresh),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        timer = Timer.scheduledTimer(timeInterval:2,target:self,selector:#selector(refresh),userInfo:nil,repeats:true)
        timer?.tolerance = 0.4
        refresh()
        bar.orderFrontRegardless()
        if CommandLine.arguments.contains("--ui-check") {
            DispatchQueue.main.async {
                guard self.bar.isVisible, !self.tiles.isEmpty,
                      let tile = self.tiles.values.first, let screen = NSScreen.screens.first,
                      screen.frame.contains(self.bar.frame),
                      self.bar.frame.minY == screen.frame.minY,
                      let menu = tile.context?() else { exit(2) }
                guard self.tray.apple.glyph.image != nil,
                      self.tray.apple.frame.maxX <= self.scroll.frame.minX,
                      let firstControl = self.tray.buttons.first,
                      self.scroll.frame.maxX <= firstControl.frame.minX,
                      !firstControl.title.isEmpty,
                      self.tray.buttons.contains(where: { $0.toolTip == "Wi-Fi" && $0.image != nil }),
                      self.bar.contentView?.layer?.cornerRadius == 0
                else { exit(9) }
                print("PASS: Apple menu, input source, Wi-Fi, square panel, separate task and tray areas")
                let already = self.pins.contains { $0.key == tile.item.key }
                guard let entry = menu.items.first(where:{$0.title == (already ? "Открепить" : "Закрепить")}) else { exit(3) }
                self.invoke(entry)
                guard self.pins.contains(where:{$0.key == tile.item.key}) != already,
                      let data = self.defaults.data(forKey:"pins"),
                      try! JSONDecoder().decode([Item].self,from:data) == self.pins else { exit(4) }
                let next = self.menu(tile.item)
                self.invoke(next.items.first(where:{$0.title == (already ? "Закрепить" : "Открепить")})!)
                print("PASS: bar flush with bottom of screen, \(self.tiles.count) app icons, contextual pin and unpin with persistence. AX permission: \(AXIsProcessTrusted())")
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
                      a.frame.width == Tile.preferredWidth(for:first.title), a.frame.width < 116,
                      b.frame.width > a.frame.width, b.frame.width <= 204,
                      Tile.preferredWidth(for:second.title) == 204, !a.frame.intersects(b.frame),
                      a.accessibilityLabel()?.contains(first.title) == true, b.accessibilityLabel()?.contains(second.title) == true
                else { exit(6) }
                let oldOrder = self.layoutOrder
                self.snapshots[pid] = [second,first]
                self.render()
                guard oldOrder == self.layoutOrder else { exit(7) }
                self.snapshots[pid] = [first]
                self.render()
                guard self.tiles[firstID] === a, self.tiles[secondID] == nil else { exit(8) }
                print("PASS: two separately labelled wide buttons, stable order, removal on close")
                let item = a.item
                let savedPins = self.pins
                self.pins.removeAll { $0.key == item.key }
                self.snapshots[pid] = []
                self.render()
                guard !self.tiles.values.contains(where:{ $0.item.key == item.key }) else { exit(10) }
                self.pins.append(item)
                self.render()
                guard let pin = self.tiles[.app(item.key)], pin.frame.width == 48,
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
        if !CommandLine.arguments.contains("--ui-check") {
            _ = SystemDockVisibility.apply(hidden: false, defaults: defaults)
        }
    }

    func liveApps() -> [NSRunningApplication] {
        ws.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.bundleURL != nil && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }
    @objc func refresh() {
        observed = observedWindows(previous:observed)
        if !AXIsProcessTrusted() { snapshots.removeAll() }
        render()
        guard AXIsProcessTrusted(), !querying else { return }
        if zoomMonitor == nil && !CommandLine.arguments.contains("--ui-check") { monitorTitleBarZoom() }
        querying = true
        let apps = liveApps()
        DispatchQueue.global(qos:.userInitiated).async {
            var result: [pid_t:[WindowEntry]] = [:]
            for app in apps {
                let (focused, listed) = queryWindows(app)
                guard let all = listed else { continue }
                result[app.processIdentifier] = all.compactMap { w in
                    guard attr(w,kAXRoleAttribute) as? String == kAXWindowRole else { return nil }
                    return WindowEntry(window:w,title:attr(w,kAXTitleAttribute) as? String ?? "",focused:(focused.map { CFEqual($0,w) } ?? false) && !minimized(w))
                }
            }
            let completed = result
            DispatchQueue.main.async {
                self.snapshots = AXIsProcessTrusted() ? completed : [:]
                self.querying = false
                self.render()
            }
        }
    }
    private func updateClock(at date: Date, rightEdge: CGFloat) {
        let alignment = NSMutableParagraphStyle()
        alignment.alignment = .center
        let title = NSMutableAttributedString(string:timeFormatter.string(from:date), attributes:[
            .font: NSFont.monospacedDigitSystemFont(ofSize:13, weight:.medium),
            .foregroundColor: NSColor.white, .paragraphStyle: alignment
        ])
        if showsDate {
            title.append(NSAttributedString(string:"\n" + dateFormatter.string(from:date), attributes:[
                .font: NSFont.monospacedDigitSystemFont(ofSize:11, weight:.regular),
                .foregroundColor: NSColor(white:0.86, alpha:1), .paragraphStyle: alignment
            ]))
        }
        clockLabel.attributedTitle = title
        clockLabel.setAccessibilityValue(title.string.replacingOccurrences(of:"\n", with:", "))
        let width = max(54, ceil(title.size().width) + 12)
        clockLabel.frame = NSRect(x:rightEdge-width, y:7, width:width, height:36)
    }
    func render() {
        guard let screen = NSScreen.screens.first, bar != nil else { return }
        let bounds = screen.visibleFrame
        let frame = NSRect(x:bounds.minX,y:screen.frame.minY,width:bounds.width,height:50)
        if geometry != frame { geometry = frame; bar.setFrame(frame,display:true) }
        let width = frame.width
        let desktopWidth: CGFloat = 12
        desktopButton.frame = NSRect(x:width-desktopWidth, y:0, width:desktopWidth, height:frame.height)
        updateClock(at:Date(), rightEdge:desktopButton.frame.minX-3)
        let trayLeft = tray.layout(width)
        let tasksLeft = tray.apple.frame.maxX + 4
        scroll.frame = NSRect(x: tasksLeft, y: 3, width: max(1, trayLeft - tasksLeft - 3), height: 44)
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
            let width = Tile.preferredWidth(for:task.caption)
            tile.place(in:NSRect(x:x,y:0,width:width,height:44), appearing:appearing, animate:animateTiles)
            x += width + 4
            let active = task.app?.isActive == true && (task.entry?.focused ?? true)
            tile.update(image:task.app?.icon ?? ws.icon(forFile:item.path),running:task.app != nil,active:active,pinned:pins.contains(where:{$0.key==item.key}),text:task.caption)
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
        strip.frame.size = NSSize(width:max(scroll.contentSize.width, lastTile, lastFadingTile),height:44)
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
    func bring(_ window: AXUIElement, _ app: NSRunningApplication) -> Bool {
        if minimized(window) && !setMini(window,false) { notify("Не удалось восстановить окно."); return false }
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
        let saved = expanded.first { CFEqual(w,$0.1) }
        let restoring = saved.map { nearlyEqual($0.3,current) } ?? false
        let goal = restoring ? saved!.2 : accessibilityFrame(usableFrame(on:screen),primary:primary)
        guard writeFrame(goal, to:w) else { _ = writeFrame(current, to:w); notify("Приложение ограничивает изменение размера этого окна."); return }
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
