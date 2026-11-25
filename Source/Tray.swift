import AppKit
import Combine
import SwiftUI
import Carbon

private func sourceString(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let p = TISGetInputSourceProperty(source,key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}
private func inputLanguage(_ source: TISInputSource) -> String? {
    guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
          let languages = Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String] else { return nil }
    return languages.first?.components(separatedBy: "-").first
}
private func inputCode() -> String {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "⌨" }
    return inputLanguage(source)?.uppercased() ?? "⌨"
}
private func enabledKeyboards() -> [TISInputSource] {
    let filter: [String: Any] = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                                 kTISPropertyInputSourceIsSelectCapable as String: true]
    guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() else { return [] }
    return (list as NSArray).map { $0 as! TISInputSource }
}
struct Extra: Equatable {
    let label: String
    let identifier: String
    let app: NSRunningApplication
    let target: AXUIElement
}
// The current menu bar hosts both system extras and remote buttons owned by other apps.
private func menuEntries(_ root: AXUIElement, host: NSRunningApplication) -> [Extra] {
    var result: [Extra] = []
    func collect(_ item: AXUIElement, depth: Int) {
        guard depth <= 4, let role = attr(item,kAXRoleAttribute) as? String else { return }
        // MenuBarAgent can embed the owner’s entire AXApplication in another status host.
        // Its windows and main menu are outside the status item.
        guard role != kAXApplicationRole, depth == 0 || role != kAXWindowRole else { return }
        if role == kAXMenuBarItemRole || role == kAXButtonRole {
            var pid: pid_t = 0
            _ = AXUIElementGetPid(item,&pid)
            let app = NSRunningApplication(processIdentifier:pid) ?? host
            let id = attr(item,kAXIdentifierAttribute) as? String ?? ""
            let label = [kAXDescriptionAttribute,kAXTitleAttribute,kAXHelpAttribute].compactMap { attr(item,$0) as? String }.first { !$0.isEmpty }
            result.append(Extra(label:label ?? app.localizedName ?? "Меню",identifier:id,app:app,target:item))
            return
        }
        for child in attr(item,kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            collect(child,depth:depth+1)
        }
    }
    collect(root,depth:0)
    return result
}

final class Tray: NSObject {
    private static let gridLabel = "Значки приложений"
    unowned let owner: Delegate
    private lazy var startLibrary = StartLibrary(defaults:owner.defaults)
    let apple = StartButton(frame:.zero)
    private let dockEdge = DockEdge(frame: .zero)
    private lazy var dockMirror = DockMirror(defaults: owner.defaults)
    private var dockMouseTimer: Timer?
    private var dockAdjustment: DockAdjustment?
    private var editingDockSlider = false
    private var previewEnd: DispatchWorkItem?
    var dockEnabled: Bool { DockMode.saved(in: owner.defaults) == .taskShelf }
    private weak var dockStrip: DockStrip?
    private var dockPanel: SlidingShelfPanel?
    private var dockScreenWidth: CGFloat = 0
    var dockPinned: Bool { owner.defaults.bool(forKey: "dockPinned") }
    var dockVisible: Bool { dockPanel?.isVisible == true && dockPanel?.isClosing == false }
    var pinnedDockInset: CGFloat { dockEnabled && dockPinned && dockVisible ? (dockStrip.map { 6 + $0.restingHeight } ?? 0) : 0 }

    func dismissForPlacementChange() {
        slidingPanel?.dismissImmediately()
        slidingPanel = nil
        dockPanel?.dismissImmediately()
        hideDock()
    }

    func layoutPinnedDock() {
        if dockEnabled && dockPinned && !dockVisible { showDock() }
    }

    func previewDock(_ kind: DockAdjustment, editing: Bool? = nil) {
        guard dockEnabled else { return }
        if let editing { editingDockSlider = editing }
        previewEnd?.cancel()
        dockAdjustment = kind
        if !dockVisible { showDock() }
        dockStrip?.preview(kind)
        if !editingDockSlider {
            let work = DispatchWorkItem { [weak self] in self?.endDockPreview() }
            previewEnd = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
        }
    }

    func endDockPreview() {
        previewEnd?.cancel()
        previewEnd = nil
        dockAdjustment = nil
        editingDockSlider = false
        dockStrip?.preview(nil)
    }

    private func hideDock() {
        dockMouseTimer?.invalidate()
        dockStrip?.stop()
        dockPanel?.dismiss()
        dockPanel = nil
    }

    func setDockPinned(_ pinned: Bool) {
        owner.defaults.set(pinned, forKey: "dockPinned")
        hideDock()
        if dockEnabled && pinned { showDock() }
    }
    var buttons: [TrayControlButton] = []
    var extras: [Extra] = []
    var scanTime = Date.distantPast
    var scanning = false
    var surface: NSView!
    private var slidingPanel: SlidingShelfPanel?
    init(_ owner: Delegate) { self.owner = owner }
    func install(_ view: NSView) {
        surface = view
        volumeChanges = OutputVolumeIndicator.shared.$symbol.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.owner.layoutControls()
        }
        apple.target = self; apple.action = #selector(showApple)
        view.addSubview(apple)
        dockEdge.title = ""
        dockEdge.isBordered = false
        dockEdge.setAccessibilityLabel("Показать Dock")
        dockEdge.target = self
        dockEdge.action = #selector(showDock)
        dockEdge.entered = { [weak self] in self?.showDock() }
        view.addSubview(dockEdge)
    }
    func configureDock(_ mode: DockMode) {
        guard mode != .taskShelf || AXIsProcessTrusted() else {
            owner.requestWindowAccess()
            return
        }
        guard SystemDockVisibility.apply(hidden: mode != .system, defaults: owner.defaults) else {
            owner.notify("Не удалось изменить настройки системного Dock.")
            return
        }
        owner.defaults.set(mode.rawValue, forKey: "dockMode")
        dockEdge.isHidden = mode != .taskShelf
        if mode == .taskShelf { dockMirror.refresh() }
        else { endDockPreview(); hideDock() }
    }

    @objc private func showDock() {
        guard dockEnabled, !dockVisible, let shelf = dockEdge.window as? Bar, let screen = shelf.screen else { return }
        dockMirror.refresh()
        guard !dockMirror.entries.isEmpty else {
            dockMirror.onFirstEntries = { [weak self] in
                guard let self, let window = self.dockEdge.window,
                      self.dockAdjustment != nil || self.dockPinned || window.convertToScreen(self.dockEdge.convert(self.dockEdge.bounds, to: nil))
                        .contains(NSEvent.mouseLocation) else { return }
                self.showDock()
            }
            return
        }
        if !dockPinned {
            slidingPanel?.dismiss()
        }
        owner.preview.hide()
        dockScreenWidth = screen.visibleFrame.width
        weak var presented: SlidingShelfPanel?
        let card = DockStrip(mirror: dockMirror, defaults: owner.defaults, edge: shelf.edge, available: dockScreenWidth - 16) { [weak self] entry in
            if self?.dockPinned == false { self?.hideDock() }
            entry.open()
        }
        card.resized = { size in presented?.fitDock(to: size) }
        dockStrip = card
        let panel = SlidingShelfPanel(title: "Dock TaskShelf", card: card, beside: dockEdge, in: shelf, screen: screen,
                                      cornerRadius: 0)
        presented = panel
        dockPanel = panel
        panel.showPanel(takingKey: false, dismissOnOutsideClick: !dockPinned)
        dockMouseTimer?.invalidate()
        var lastInside = Date()
        if let dockAdjustment { card.preview(dockAdjustment) }
        card.startClock()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self, weak panel, weak shelf, weak card] timer in
            guard let self, let panel, let shelf, panel.isVisible, !panel.isClosing else { card?.stop(); timer.invalidate(); return }
            guard !self.dockPinned, self.dockAdjustment == nil else { return }
            let span = panel.frame.union(shelf.frame)
            let corridor = NSRect(x: panel.frame.minX, y: span.minY, width: panel.frame.width, height: span.height)
            if card?.isPressingIcon == true || corridor.insetBy(dx: -4, dy: -3).contains(NSEvent.mouseLocation) { lastInside = Date() }
            else if Date().timeIntervalSince(lastInside) > 0.28 { panel.dismiss(); timer.invalidate() }
        }
        dockMouseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func openSettings(_ pane:String) {
        if let url = URL(string:"x-apple.systempreferences:"+pane) { owner.ws.open(url) }
    }
    private func toggleVisiblePanel(above anchor: NSButton) -> Bool {
        if let panel = slidingPanel, panel.isVisible, panel.anchor === anchor {
            if panel.isClosing { panel.showPanel() } else { panel.dismiss() }
            return true
        }
        slidingPanel?.dismiss()
        return false
    }

    @objc func showApple() {
        if toggleVisiblePanel(above:apple) { return }
        guard let shelf = apple.window as? Bar, let screen = shelf.screen else { return }
        startLibrary.refresh()
        let bounds = screen.visibleFrame
        let size = NSSize(width:min(580,bounds.width-32),height:min(440,shelf.edge.availableFrame(in: bounds, beside: shelf.frame).height-16))
        let menu = StartMenu(library:startLibrary, size:size, launch:{ [weak self] item in
            self?.slidingPanel?.dismiss()
            self?.owner.launch(item)
        }, remove:{ [weak self] item in
            self?.removeStartApp(item)
        }, browse:{ [weak self] in
            self?.chooseStartPin()
        }, settings:{ [weak self] in
            self?.slidingPanel?.dismiss()
            guard let self else { return }
            guard let url = self.owner.ws.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else {
                self.owner.notify("Не удалось найти системные настройки macOS.")
                return
            }
            self.owner.launch(Item(url))
        }, accountMenu: { [weak self] in self?.startAccountMenu() ?? NSMenu() },
           powerMenu: { [weak self] in self?.startPowerMenu() ?? NSMenu() })
        let panel = SlidingShelfPanel(title:"Пуск",card:NSHostingView(rootView:menu.defaultAppStorage(owner.defaults)),beside:apple,in:shelf,screen:screen) { window in
            menu.focusSearch.send()
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { editor.selectAll(nil) }
        }
        slidingPanel = panel
        panel.showPanel()
    }

    private func removeStartApp(_ item: Item) {
        guard StartLibrary.canTrash(item) else { return }
        slidingPanel?.dismiss()
        NSApp.activate(ignoringOtherApps: true)
        let url = item.url
        let alert = NSAlert()
        alert.icon = owner.ws.icon(forFile: item.path)
        alert.messageText = "Переместить «\(item.name)» в Корзину?"
        alert.informativeText = item.path
        alert.addButton(withTitle: "Отмена").keyEquivalent = "\r"
        alert.addButton(withTitle: "В Корзину").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        let target = url.resolvingSymlinksInPath().standardizedFileURL
        if owner.ws.runningApplications.contains(where: {
            !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == target
        }) {
            owner.notify("Сначала завершите «\(item.name)», затем снова выберите «Удалить».")
            return
        }
        owner.ws.recycle([url]) { [weak self] moved, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if moved.keys.contains(where: { $0.standardizedFileURL.path == item.path }) {
                    self.didTrashStartApp(item)
                } else if let error = error as NSError?, ApplicationTrash.isPermissionError(error) {
                    self.trashStartAppWithFinder(item)
                } else if let error = error as NSError?, ApplicationTrash.isCancellation(error) {
                    return
                } else {
                    self.owner.notify(error?.localizedDescription ?? "Не удалось переместить «\(item.name)» в Корзину.")
                }
            }
        }
    }

    private func trashStartAppWithFinder(_ item: Item) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ApplicationTrash.moveWithFinder(item.url) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.didTrashStartApp(item)
                case .failure(let failure):
                    let error = failure as NSError
                    if ApplicationTrash.isCancellation(error) { return }
                    let alert = NSAlert()
                    alert.messageText = "Не удалось переместить «\(item.name)» в Корзину"
                    alert.informativeText = error.domain == NSOSStatusErrorDomain && error.code == Int(errAEEventNotPermitted)
                        ? "Разрешите TaskShelf управлять Finder в разделе «Конфиденциальность и безопасность → Автоматизация» или откройте расположение программы и удалите её в Finder."
                        : error.localizedDescription
                    alert.addButton(withTitle: "Закрыть")
                    alert.addButton(withTitle: "Показать в Finder")
                    if alert.runModal() == .alertSecondButtonReturn {
                        self.owner.ws.activateFileViewerSelecting([item.url])
                    }
                }
            }
        }
    }

    private func didTrashStartApp(_ item: Item) {
        startLibrary.didTrash(item)
        if owner.pins.contains(where: { $0.path == item.path }) {
            owner.pins.removeAll { $0.path == item.path }
            owner.save()
        }
    }

    private func startAccountMenu() -> NSMenu {
        let menu = NSMenu()
        owner.add(menu, "Заблокировать экран", symbol: "lock") {
            self.slidingPanel?.dismiss()
            self.lockScreen()
        }
        menu.addItem(.separator())
        owner.add(menu, "Завершить сеанс", symbol: "rectangle.portrait.and.arrow.right") { self.perform(.logOut) }
        return menu
    }

    private func startPowerMenu() -> NSMenu {
        let menu = NSMenu()
        owner.add(menu, "Режим сна", symbol: "moon") { self.perform(.sleep) }
        owner.add(menu, "Перезапуск", symbol: "arrow.clockwise") { self.perform(.restart) }
        owner.add(menu, "Выключение", symbol: "power") { self.perform(.shutdown) }
        return menu
    }

    private func perform(_ action: LoginWindowAction) {
        slidingPanel?.dismiss()
        do { try action.perform() } catch { owner.notify(error.localizedDescription) }
    }

    private func lockScreen() {
        guard AXIsProcessTrusted() else { owner.requestWindowAccess(); return }
        // Use Finder's system Apple menu so the action also works with a localized menu title.
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              let bar = element(AXUIElementCreateApplication(finder.processIdentifier), kAXMenuBarAttribute),
              let apple = (attr(bar, kAXChildrenAttribute) as? [AXUIElement])?.first,
              let menu = (attr(apple, kAXChildrenAttribute) as? [AXUIElement])?.first,
              let items = attr(menu, kAXChildrenAttribute) as? [AXUIElement],
              let lock = items.first(where: { attr($0, kAXIdentifierAttribute) as? String == "_lockScreenRequested:" }),
              attr(lock, kAXEnabledAttribute) as? Bool == true,
              AXUIElementPerformAction(lock, kAXPressAction as CFString) == .success else {
            owner.notify("Не удалось заблокировать экран. Используйте Control–Command–Q.")
            return
        }
    }

    private func chooseStartPin() {
        slidingPanel?.dismiss()
        let chooser = NSOpenPanel()
        chooser.directoryURL = URL(fileURLWithPath:"/Applications")
        chooser.allowedContentTypes = [.applicationBundle]
        chooser.canChooseDirectories = false
        chooser.prompt = "Закрепить"
        if chooser.runModal() == .OK, let url = chooser.url {
            startLibrary.setPinned(Item(url),true)
        }
        showApple()
    }
    private func selectKeyboard(_ source: TISInputSource) {
        if TISSelectInputSource(source) != noErr { NSSound.beep() }
        owner.render()
    }

    func nextInputLanguage() {
        let sources = enabledKeyboards()
        guard sources.count > 1, let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        let id = sourceString(current, kTISPropertyInputSourceID)
        let start = sources.firstIndex { sourceString($0, kTISPropertyInputSourceID) == id }
        let next = ((start ?? -1) + 1) % sources.count
        let ordered = sources[next...] + sources[..<next]
        let language = inputLanguage(current)
        selectKeyboard(ordered.first { inputLanguage($0) != language } ?? sources[next])
    }

    func inputs(_ button:NSButton) {
        let m = NSMenu()
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        for source in enabledKeyboards() {
            guard let label = sourceString(source,kTISPropertyLocalizedName) else { continue }
            owner.add(m,label) { self.selectKeyboard(source) }
            if sourceString(source,kTISPropertyInputSourceID) == sourceString(current,kTISPropertyInputSourceID) { m.items.last?.state = .on }
        }
        m.addItem(.separator())
        owner.add(m,"Настройки клавиатуры…", symbol:"keyboard") { self.openSettings("com.apple.Keyboard-Settings.extension") }
        popUp(m,above:button)
    }
    func scan() {
        guard AXIsProcessTrusted() else { extras = []; return }
        guard !scanning, Date().timeIntervalSince(scanTime)>10 else { return }
        scanning = true; scanTime = Date()
        let apps = owner.ws.runningApplications.filter { $0.bundleURL != nil && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        DispatchQueue.global(qos:.utility).async {
            var items: [Extra] = []
            for app in apps {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root,0.2)
                if let menu = element(root,kAXExtrasMenuBarAttribute) {
                    items += menuEntries(menu,host:app)
                }
                if app.bundleIdentifier == "com.apple.MenuBarAgent" {
                    let windows = attr(root,kAXWindowsAttribute) as? [AXUIElement] ?? []
                    for w in windows {
                        guard let size = attr(w,kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { continue }
                        var frameSize = CGSize.zero
                        guard AXValueGetValue(size as! AXValue,.cgSize,&frameSize), frameSize.height <= 64 else { continue }
                        items += menuEntries(w,host:app)
                    }
                }
            }
            var seen = Set<String>()
            let result = items.filter { seen.insert("\($0.app.processIdentifier):" + ($0.identifier.isEmpty ? $0.label : $0.identifier)).inserted }
            DispatchQueue.main.async {
                self.scanning = false
                let updated = AXIsProcessTrusted() ? result : []
                if self.extras != updated {
                    self.extras = updated
                    self.owner.layoutControls()
                }
            }
        }
    }
    private func family(_ e:Extra) -> String {
        if e.app.bundleIdentifier?.lowercased() == "com.apple.textinputmenuagent" { return "keyboard" }
        if ["com.apple.Spotlight","com.apple.campo"].contains(e.app.bundleIdentifier)
            || e.identifier.lowercased() == "com.apple.menuextra.spotlight" { return "spotlight" }
        if e.identifier == "com.apple.menuextra.clock" { return "clock" }
        if e.identifier == "com.apple.menuextra.controlcenter" { return "control" }
        let s = (e.identifier+" "+e.label).lowercased().replacingOccurrences(of:"‑",with:"-")
        for (key,terms) in [("wifi",["wi-fi","wifi"]),("battery",["battery","аккумулятор","батаре"]),("keyboard",["inputmenu","textinput","источник ввода","меню ввода"]),("sound",["volume","sound","громкость","звук"]),("bluetooth",["bluetooth"]),("control",["control center","пункт управления","controlcenter.controlcenter"])] where terms.contains(where:{s.contains($0)}) { return key }
        return ""
    }
    @discardableResult
    func press(_ e:Extra) -> Bool {
        AXUIElementSetMessagingTimeout(e.target,0.4)
        let result = AXUIElementPerformAction(e.target,kAXPressAction as CFString)
        // A menu can keep AXPress pending until the user makes a selection.
        return result == .success || result == .cannotComplete
    }
    @objc func showClock() {
        let clock = owner.clockLabel
        if toggleVisiblePanel(above:clock) { return }
        guard let shelf = clock.window as? Bar, let screen = shelf.screen else { return }
        let card = NSHostingView(rootView: ShelfCalendar())
        let panel = SlidingShelfPanel(title:"Календарь",card:card,beside:clock,in:shelf,screen:screen,
                                      cornerRadius: ShelfPanelSurface.cornerRadius)
        panel.appearance = nil
        slidingPanel = panel
        panel.showPanel()
    }
    private func showControls(_ page:TrayPage, above anchor:NSButton) {
        if toggleVisiblePanel(above:anchor) { return }
        guard let shelf = anchor.window as? Bar, let screen = shelf.screen else { return }
        weak var presented: SlidingShelfPanel?
        let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        let controls = TrayControls(display:display, initialPage:page, wifiUpdates: wifiUpdates.eraseToAnyPublisher(), openAirDrop: { [weak self] in
            presented?.dismiss()
            guard let self else { return }
            guard let finder = self.owner.ws.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
                self.owner.notify("Не удалось открыть AirDrop в Finder.")
                return
            }
            self.owner.launch(Item(finder.appendingPathComponent("Contents/Applications/AirDrop.app")))
        }) { [weak self] pane in
            presented?.dismiss()
            self?.openSettings(pane)
        }
        let card = NSHostingView(rootView:controls
            .onGeometryChange(for:NSSize.self) { $0.size } action: { size in
                presented?.fitContent(to:size)
            })
        let panel = SlidingShelfPanel(title:page.rawValue,card:card,beside:anchor,in:shelf,screen:screen,
                                      cornerRadius: ShelfPanelSurface.cornerRadius)
        panel.appearance = nil
        presented = panel
        slidingPanel = panel
        panel.showPanel()
    }
    private func showApplicationGrid(_ entries: [Extra], above anchor: NSButton) {
        if toggleVisiblePanel(above: anchor) { return }
        guard !entries.isEmpty, let shelf = anchor.window as? Bar, let screen = shelf.screen else { return }
        weak var presented: SlidingShelfPanel?
        let sorted = entries.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        let grid = StatusIconGrid(entries: sorted, open: { [weak self, weak anchor] entry in
            guard let self, let anchor else { return }
            presented?.dismissImmediately()
            if !entry.app.isTerminated { self.showExtra(entry, above: anchor) }
        }, contextMenu: { [weak self] entry in
            self?.statusContextMenu(entry) { presented?.dismissImmediately() } ?? NSMenu()
        })
        let panel = SlidingShelfPanel(title: Self.gridLabel, card: NSHostingView(rootView: grid),
                                      beside: anchor, in: shelf, screen: screen,
                                      cornerRadius: ShelfPanelSurface.cornerRadius)
        panel.appearance = nil
        panel.onPresentationChange = { [weak anchor] expanded in
            (anchor as? TrayControlButton)?.setExpanded(expanded)
        }
        presented = panel
        slidingPanel = panel
        panel.showPanel()
    }

    typealias Control = (label:String,symbol:String?,text:String?,icon:NSImage?,click:(NSButton)->Void)
    private var actions: [(NSButton)->Void] = []
    @objc func invoke(_ b:NSButton) {
        if actions.indices.contains(b.tag) { actions[b.tag](b) }
    }
    private struct Status: Equatable {
        let language = inputCode()
        let wifi = WiFiStatus.current()
        let battery = BatteryStatus.current()
    }
    private var volumeChanges: AnyCancellable?
    private var lastStatus: Status?
    private let wifiUpdates = PassthroughSubject<WiFiStatus, Never>()
    func statusChanged() -> Bool {
        let status = Status()
        if let panel = slidingPanel, panel.isVisible, !panel.isClosing, panel.title == TrayPage.wifi.rawValue {
            wifiUpdates.send(status.wifi)
        }
        return status != lastStatus
    }
    func refreshVisibleDock() { dockMirror.refresh() }
    func layout(_ width:CGFloat) -> CGFloat {
        let status = Status()
        lastStatus = status
        let sizing = owner.bar.sizing
        let edgeWidth = min(width * 0.45, 440)
        dockEdge.frame = NSRect(x: (width - edgeWidth) / 2, y: 0, width: edgeWidth, height: 3)
        dockEdge.isHidden = !dockEnabled
        if dockEnabled {
            if let screen = dockEdge.window?.screen, dockVisible, screen.visibleFrame.width != dockScreenWidth { hideDock() }
            layoutPinnedDock()
            if dockVisible || dockMirror.entries.isEmpty { dockMirror.refresh() }
        }
        apple.frame = NSRect(x: 4, y: 2, width: sizing.compact ? 40 : 52, height: sizing.height - 4)
        apple.setGlyphSize(sizing.compact ? 20 : 26)
        scan()
        var controls: [Control] = []
        func system(_ page:TrayPage, _ label:String, _ symbol:String) {
            controls.append((label,symbol,nil,nil,{ button in self.showControls(page,above:button) }))
        }
        controls.append(("Источник ввода",nil,status.language,nil,{ button in
            self.slidingPanel?.dismiss()
            self.inputs(button)
        }))
        controls.append(("Wi-Fi · " + status.wifi.description, nil, nil, status.wifi.trayIcon, { button in
            self.showControls(.wifi, above: button)
        }))
        system(.sound,"Звук",OutputVolumeIndicator.shared.symbol)
        if let battery = status.battery {
            controls.append(("Аккумулятор · " + battery.description, nil, nil, battery.trayIcon, { button in
                self.showControls(.battery, above:button)
            }))
        }
        // Ignore native duplicates and the intentionally hidden Control Center and Spotlight.
        let excludedFamilies: Set<String> = ["keyboard","wifi","sound","battery","bluetooth","control","clock","spotlight"]
        let extraItems = extras.filter { !excludedFamilies.contains(family($0)) }
        let applications = extraItems.filter { $0.app.bundleIdentifier?.hasPrefix("com.apple.") != true }
        let arrow = owner.bar.edge == .top ? "chevron.down" : "chevron.up"
        if !applications.isEmpty {
            controls.insert((Self.gridLabel,arrow,nil,nil,{ button in
                self.showApplicationGrid(applications,above:button)
            }),at:0)
        }
        for extra in extraItems where extra.app.bundleIdentifier?.hasPrefix("com.apple.") == true {
            let icon = extra.app.icon?.copy() as? NSImage
            icon?.size = NSSize(width:17,height:17)
            controls.append((extra.label,nil,nil,icon,
                             { button in self.showExtra(extra,above:button) }))
        }
        let slots = max(2,Int(width*0.32/sizing.trayWidth))
        if controls.count > slots {
            let overflow = Array(controls.dropFirst(slots-1))
            controls = Array(controls.prefix(slots-1))
            controls.append(("Другие значки",arrow,nil,nil,{ button in
                let menu = NSMenu()
                for c in overflow {
                    self.owner.add(menu,c.label,symbol:c.symbol) { c.click(button) }
                    if let icon = c.icon { menu.items.last?.image = icon }
                }
                self.popUp(menu,above:button)
            }))
        }
        actions = controls.map { $0.click }
        while buttons.count < controls.count {
            let b = TrayControlButton(frame:.zero); b.contentTintColor = .white; b.isBordered = false; b.font = .systemFont(ofSize:12,weight:.semibold)
            b.target = self; b.action = #selector(invoke(_:)); surface.addSubview(b); buttons.append(b)
        }
        while buttons.count > controls.count { buttons.removeLast().removeFromSuperview() }
        let left = owner.clockLabel.frame.minX-4-CGFloat(controls.count)*sizing.trayWidth
        for (i,c) in controls.enumerated() {
            let b = buttons[i]; b.tag = i; b.toolTip = c.label; b.setAccessibilityLabel(c.label)
            b.title = c.text ?? ""
            let isDisclosure = c.label == Self.gridLabel
            if !isDisclosure, let panel = slidingPanel, panel.isVisible, panel.title == Self.gridLabel, panel.anchor === b {
                panel.dismissImmediately()
            }
            if isDisclosure { b.image = nil }
            else if let symbol = c.symbol { b.image = NSImage(systemSymbolName:symbol,accessibilityDescription:c.label) }
            else { b.image = c.icon }
            if sizing.compact, let image = b.image {
                if let symbol = image.withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) {
                    b.image = symbol
                } else if let small = image.copy() as? NSImage {
                    small.size = NSSize(width: image.size.width * 0.85, height: image.size.height * 0.85)
                    b.image = small
                }
            }
            b.frame = NSRect(x:left+CGFloat(i)*sizing.trayWidth,y:sizing.controlY,width:sizing.trayWidth,height:sizing.controlHeight)
            b.setDisclosureVisible(isDisclosure, symbol: arrow)
        }
        return left
    }
}
