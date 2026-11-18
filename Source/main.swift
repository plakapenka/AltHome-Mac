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
    let e = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(e, 0.35)
    let all = attr(e,kAXWindowsAttribute) as? [AXUIElement] ?? []
    return (element(e,kAXFocusedWindowAttribute), all)
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
final class ShelfBackground: NSView {
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
final class Tile: NSButton {
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
    private let icon = NSImageView()
    private let caption = NSTextField(labelWithString:"")
    private let activeMark = NSView()
    private var hover = false
    private var selected = false
    private var area: NSTrackingArea?
    init(_ item: Item) {
        self.item = item
        super.init(frame: NSRect(x:0,y:0,width:48,height:44))
        isBordered = false
        imagePosition = .noImage
        title = ""
        wantsLayer = true
        layer?.cornerCurve = .continuous
        icon.frame = NSRect(x:9,y:9,width:30,height:30)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        activeMark.frame = NSRect(x:icon.frame.midX - 8, y:isFlipped ? bounds.height - 5 : 2, width:16, height:3)
        activeMark.wantsLayer = true
        activeMark.layer?.cornerRadius = 1.5
        activeMark.layer?.backgroundColor = NSColor(srgbRed:0.38,green:0.83,blue:1,alpha:1).cgColor
        activeMark.isHidden = true
        addSubview(activeMark)
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
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func menu(for event: NSEvent) -> NSMenu? { context?() }
    @objc func clicked() { press?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect:.zero,options:[.inVisibleRect,.activeAlways,.mouseEnteredAndExited],owner:self)
        addTrackingArea(a); area = a
    }
    override func mouseEntered(with e: NSEvent) { hover = true; tint() }
    override func mouseExited(with e: NSEvent) { hover = false; tint() }
    func tint() {
        activeMark.isHidden = !selected
        let outlined = selected || hover
        layer?.cornerRadius = outlined ? 6 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(selected ? 0.2 : 0.12).cgColor
        layer?.borderWidth = outlined ? 1 / (window?.backingScaleFactor ?? 1) : 0
        layer?.backgroundColor = NSColor.white.withAlphaComponent(selected ? (hover ? 0.22 : 0.16) : (hover ? 0.08 : 0)).cgColor
    }
    func update(image: NSImage, running: Bool, active: Bool, pinned: Bool, text: String?) {
        icon.image = image
        caption.stringValue = text ?? ""
        caption.isHidden = text == nil
        caption.frame = NSRect(x:Self.captionX, y:14, width:max(1,bounds.width-Self.captionX-Self.trailingInset), height:17)
        selected = active; tint()
        let label = (text != nil && text != item.name) ? "\(item.name) — \(text!)" : item.name
        setAccessibilityLabel(label)
        toolTip = label + (pinned ? " · закреплено" : "") + (running ? " · запущено" : "") + "\nПравый клик — меню"
        setAccessibilityValue(active ? "Активно" : running ? "Запущено" : "Закреплено")
    }
}
final class Delegate: NSObject, NSApplicationDelegate {
    let ws = NSWorkspace.shared
    let defaults = CommandLine.arguments.contains("--ui-check") ? UserDefaults(suiteName:"local.taskshelf.layoutcheck")! : UserDefaults.standard
    var bar: Bar!
    let strip = NSView()
    let scroll = NSScrollView()
    let clockLabel = NSTextField(labelWithString:"")
    let options = NSButton()
    lazy var tray = Tray(self)
    var pins: [Item] = []
    var tiles: [TileID:Tile] = [:]
    var snapshots: [pid_t:[WindowEntry]] = [:]
    var layoutOrder: [TileID] = []
    var querying = false
    var remembered: [pid_t:AXUIElement] = [:]
    var expanded: [(pid_t, AXUIElement, CGRect, CGRect)] = []
    var timer: Timer?
    let fmt = DateFormatter()
    var geometry: NSRect = .zero
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
        glass.wantsLayer = true
        bar.contentView = glass
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = false
        scroll.documentView = strip
        glass.addSubview(scroll)
        clockLabel.font = .monospacedDigitSystemFont(ofSize:13,weight:.medium)
        clockLabel.alignment = .center
        glass.addSubview(clockLabel)
        options.title = ""
        options.isBordered = false
        options.image = NSImage(systemSymbolName:"ellipsis.circle",accessibilityDescription:"Меню панели")
        options.toolTip = "Меню панели"
        options.target = self; options.action = #selector(showMenu)
        glass.addSubview(options)
        tray.install(glass)
        fmt.dateFormat = "HH:mm"
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
                guard self.tray.apple.image != nil || self.tray.apple.title == "",
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
                      a.toolTip?.contains(first.title) == true, b.toolTip?.contains(second.title) == true
                else { exit(6) }
                let oldOrder = self.layoutOrder
                self.snapshots[pid] = [second,first]
                self.render()
                guard oldOrder == self.layoutOrder else { exit(7) }
                self.snapshots[pid] = [first]
                self.render()
                guard self.tiles[firstID] === a, self.tiles[secondID] == nil else { exit(8) }
                print("PASS: two separately labelled wide buttons, stable order, removal on close")
                NSApp.terminate(nil)
            }
        }
    }
    func liveApps() -> [NSRunningApplication] {
        ws.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.bundleURL != nil && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }
    func resolve(_ item: Item) -> NSRunningApplication? {
        let matches = liveApps().filter { ($0.bundleIdentifier ?? $0.bundleURL?.standardizedFileURL.path) == item.key }
        return matches.first(where: { $0.isActive }) ?? matches.first
    }
    @objc func refresh() {
        if !AXIsProcessTrusted() { snapshots.removeAll() }
        render()
        guard AXIsProcessTrusted(), !querying else { return }
        querying = true
        let apps = liveApps()
        DispatchQueue.global(qos:.userInitiated).async {
            var result: [pid_t:[WindowEntry]] = [:]
            for app in apps {
                let (focused,all) = windows(app)
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
    func render() {
        guard let screen = NSScreen.screens.first, bar != nil else { return }
        let bounds = screen.visibleFrame
        let frame = NSRect(x:bounds.minX,y:screen.frame.minY,width:bounds.width,height:50)
        if geometry != frame { geometry = frame; bar.setFrame(frame,display:true) }
        let width = frame.width
        let trayLeft = tray.layout(width)
        scroll.frame = NSRect(x:46,y:3,width:max(1,trayLeft-49),height:44)
        clockLabel.frame = NSRect(x:width-99,y:15,width:54,height:20)
        options.frame = NSRect(x:width-44,y:7,width:36,height:36)
        clockLabel.stringValue = fmt.string(from:Date())
        let apps = liveApps()
        let pids = Set(apps.map { $0.processIdentifier })
        remembered = remembered.filter { pids.contains($0.key) }
        expanded.removeAll { !pids.contains($0.0) }
        let entries = apps.compactMap { app in app.bundleURL.map { Item($0,name:app.localizedName) } }
        let ranks = Dictionary(uniqueKeysWithValues:layoutOrder.enumerated().map { ($1,$0) })
        var tasks: [TaskEntry] = []
        for item in ordered(pins,entries) {
            let matches = apps.filter { ($0.bundleIdentifier ?? $0.bundleURL?.standardizedFileURL.path) == item.key }
            let perWindow = matches.flatMap { app in
                (snapshots[app.processIdentifier] ?? []).map {
                    TaskEntry(id:.window(app.processIdentifier,$0.window),item:item,app:app,entry:$0)
                }
            }.sorted { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) }
            if perWindow.isEmpty {
                tasks.append(TaskEntry(id:.app(item.key),item:item,app:matches.first(where:{$0.isActive}) ?? matches.first,entry:nil))
            } else { tasks.append(contentsOf:perWindow) }
        }
        layoutOrder = tasks.map { $0.id }
        let keys = Set(layoutOrder)
        for key in Array(tiles.keys) where !keys.contains(key) { tiles.removeValue(forKey:key)?.removeFromSuperview() }
        var x: CGFloat = 0
        for task in tasks {
            let item = task.item
            let tile = tiles[task.id] ?? Tile(item)
            if tile.superview == nil { tiles[task.id] = tile; strip.addSubview(tile) }
            tile.press = { [weak self] in
                guard let self else { return }
                if let app = task.app, let entry = task.entry, !app.isTerminated {
                    let focused = element(AXUIElementCreateApplication(app.processIdentifier),kAXFocusedWindowAttribute)
                    if app.isActive, focused.map({ CFEqual($0,entry.window) }) == true, !minimized(entry.window) {
                        if !setMini(entry.window,true) { self.notify("Это окно не поддерживает сворачивание.") }
                    } else { self.bring(entry.window,app) }
                } else { self.toggle(item) }
                self.refresh()
            }
            tile.context = { [weak self] in self?.menu(item,target:task.entry?.window,owner:task.app) ?? NSMenu() }
            let width = Tile.preferredWidth(for:task.caption)
            tile.frame = NSRect(x:x,y:0,width:width,height:44)
            x += width + 4
            let active = task.app?.isActive == true && (task.entry?.focused ?? true)
            tile.update(image:task.app?.icon ?? ws.icon(forFile:item.path),running:task.app != nil,active:active,pinned:pins.contains(where:{$0.key==item.key}),text:task.caption)
        }
        strip.frame.size = NSSize(width:max(scroll.contentSize.width,x-4),height:44)
    }
    func launch(_ item: Item) {
        let url = FileManager.default.fileExists(atPath:item.path) ? item.url : ws.urlForApplication(withBundleIdentifier:item.key)
        guard let url else { notify("Приложение не найдено. Закрепите его заново."); return }
        ws.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration()) { _,error in
            if let error { DispatchQueue.main.async { self.notify(error.localizedDescription) } }
        }
    }
    func toggle(_ item: Item) {
        guard let app = resolve(item) else { launch(item); return }
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
    func bring(_ window: AXUIElement, _ app: NSRunningApplication) {
        if minimized(window) && !setMini(window,false) { notify("Не удалось восстановить окно."); return }
        app.unhide()
        app.activate(options:[])
        _ = AXUIElementPerformAction(window,kAXRaiseAction as CFString)
        remembered.removeValue(forKey: app.processIdentifier)
    }
    func windowRect(_ w: AXUIElement) -> CGRect? {
        guard let pos = attr(w,kAXPositionAttribute), CFGetTypeID(pos) == AXValueGetTypeID(),
              let size = attr(w,kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(pos as! AXValue,.cgPoint,&pt), AXValueGetValue(size as! AXValue,.cgSize,&sz) else { return nil }
        return CGRect(origin:pt,size:sz)
    }
    func fit(_ w: AXUIElement,_ app: NSRunningApplication) {
        bring(w,app)
        guard let current = windowRect(w), let primary = NSScreen.screens.first else { return }
        func flip(_ r: CGRect) -> CGRect {
            CGRect(x:r.minX,y:primary.frame.maxY-r.maxY,width:r.width,height:r.height)
        }
        func overlap(_ screen: NSScreen) -> CGFloat {
            let r = flip(screen.frame).intersection(current)
            return r.isNull ? 0 : r.width*r.height
        }
        guard let screen = NSScreen.screens.max(by:{overlap($0)<overlap($1)}) else { return }
        var usable = screen.visibleFrame
        if usable.intersects(bar.frame) {
            let inset = max(0,bar.frame.maxY+2-usable.minY)
            usable.origin.y += inset; usable.size.height -= inset
        }
        let saved = expanded.first { CFEqual(w,$0.1) }
        let restoring = saved.map { abs($0.3.minX-current.minX)<2 && abs($0.3.minY-current.minY)<2 && abs($0.3.width-current.width)<2 && abs($0.3.height-current.height)<2 } ?? false
        let goal = restoring ? saved!.2 : flip(usable)
        func write(_ rect: CGRect) -> Bool {
            var pos = rect.origin, sz = rect.size
            guard let p = AXValueCreate(.cgPoint,&pos), let s = AXValueCreate(.cgSize,&sz) else { return false }
            guard AXUIElementSetAttributeValue(w,kAXPositionAttribute as CFString,p) == .success else { return false }
            return AXUIElementSetAttributeValue(w,kAXSizeAttribute as CFString,s) == .success
        }
        guard write(goal) else { _ = write(current); notify("Приложение ограничивает изменение размера этого окна."); return }
        expanded.removeAll { CFEqual(w,$0.1) }
        if !restoring, let actual = windowRect(w) { expanded.append((app.processIdentifier,w,current,actual)) }
    }
    func notify(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Панель задач"; alert.informativeText = message
        alert.runModal()
    }
    @objc func invoke(_ sender: NSMenuItem) { (sender.representedObject as? Action)?.run() }
    func add(_ menu: NSMenu,_ title:String,_ run:@escaping ()->Void) {
        let m = NSMenuItem(title:title,action:#selector(invoke(_:)),keyEquivalent:"")
        m.target = self; m.representedObject = Action(run); menu.addItem(m)
    }
    func save() { if let data = try? JSONEncoder().encode(pins) { defaults.set(data,forKey:"pins") }; refresh() }
    func menu(_ item: Item, target: AXUIElement? = nil, owner: NSRunningApplication? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle:item.name,action:nil,keyEquivalent:"")
        let pinned = pins.contains(where:{$0.key == item.key})
        add(menu,pinned ? "Открепить" : "Закрепить") {
            if pinned { self.pins.removeAll { $0.key == item.key } } else { self.pins.append(item) }
            self.save()
        }
        guard let app = owner ?? resolve(item), !app.isTerminated else { return menu }
        if AXIsProcessTrusted() {
            let (focused,all) = windows(app)
            if let w = target ?? focused ?? all.first, (attr(w,"AXFullScreen") as? Bool) != true {
                var writable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(w,kAXSizeAttribute as CFString,&writable) == .success && writable.boolValue {
                    add(menu,"Развернуть / вернуть размер") { self.fit(w,app) }
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
                add(menu,"Закрыть окно") {
                    guard let button = element(w,kAXCloseButtonAttribute),
                          AXUIElementPerformAction(button,kAXPressAction as CFString) == .success else {
                        self.notify("Не удалось закрыть выбранное окно.")
                        return
                    }
                    self.refresh()
                }
            }
        } else {
            menu.addItem(.separator())
            add(menu,"Закрыть окно") { self.requestWindowAccess() }
        }
        return menu
    }
    func requestWindowAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
        if let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            ws.open(url)
        }
    }
    @objc func showMenu() {
        let m = NSMenu()
        add(m,"Закрепить приложение…") {
            let p = NSOpenPanel()
            p.directoryURL = URL(fileURLWithPath:"/Applications"); p.allowedContentTypes = [.applicationBundle]
            p.canChooseFiles = true; p.canChooseDirectories = false
            if p.runModal() == .OK, let u = p.url {
                let item = Item(u)
                if !self.pins.contains(where:{$0.key == item.key}) { self.pins.append(item); self.save() }
            }
        }
        if !AXIsProcessTrusted() {
            add(m,"Разрешить доступ к окнам…") {
                self.requestWindowAccess()
            }
        }
        let service = SMAppService.mainApp
        add(m,service.status == .enabled ? "Отключить запуск при входе" : "Запускать при входе") {
            do {
                if service.status == .enabled { try service.unregister() }
                else if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                else { try service.register(); if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() } }
            } catch { self.notify(error.localizedDescription) }
        }
        m.addItem(.separator()); add(m,"Завершить панель") { NSApp.terminate(nil) }
        m.popUp(positioning:nil,at:NSPoint(x:0,y:options.bounds.maxY+6),in:options)
    }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.run()
