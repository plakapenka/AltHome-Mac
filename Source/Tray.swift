import AppKit
import SwiftUI
import Carbon
import CoreWLAN

private func sourceString(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let p = TISGetInputSourceProperty(source,key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}
private func inputCode() -> String {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let p = TISGetInputSourceProperty(source,kTISPropertyInputSourceLanguages),
          let langs = Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String],
          let first = langs.first else { return "⌨" }
    return first.components(separatedBy:"-")[0].uppercased()
}
struct Extra {
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

final class Tray: NSObject, NSPopoverDelegate {
    unowned let owner: Delegate
    private lazy var startLibrary = StartLibrary(defaults:owner.defaults)
    let apple = StartButton(frame:.zero)
    var buttons: [ShelfButton] = []
    var extras: [Extra] = []
    var scanTime = Date.distantPast
    var scanning = false
    var surface: NSView!
    private var popover: NSPopover?
    private weak var popoverAnchor: NSButton?
    private let popoverClicks = OutsideClickMonitor()
    private var slidingPanel: SlidingShelfPanel?
    init(_ owner: Delegate) { self.owner = owner }
    func install(_ view: NSView) {
        surface = view
        apple.target = self; apple.action = #selector(showApple)
        view.addSubview(apple)
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
        popover?.performClose(nil)
        return false
    }

    @objc func showApple() {
        if toggleVisiblePanel(above:apple) { return }
        guard let shelf = apple.window, let screen = shelf.screen else { return }
        startLibrary.refresh()
        let bounds = screen.visibleFrame
        let size = NSSize(width:min(580,bounds.width-32),height:min(440,bounds.maxY-shelf.frame.maxY-16))
        let menu = StartMenu(library:startLibrary, size:size, launch:{ [weak self] item in
            self?.slidingPanel?.dismiss()
            self?.owner.launch(item)
        }, browse:{ [weak self] in
            self?.chooseStartPin()
        }, power:{ [weak self] action in
            self?.slidingPanel?.dismiss()
            do { try action.requestDialog() } catch { self?.owner.notify(error.localizedDescription) }
        })
        let panel = SlidingShelfPanel(title:"Пуск",card:NSHostingView(rootView:menu),above:apple,in:shelf,screen:screen) { window in
            menu.focusSearch.send()
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { editor.selectAll(nil) }
        }
        slidingPanel = panel
        panel.showPanel()
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
    func inputs(_ button:NSButton) {
        let m = NSMenu()
        let sources = TISCreateInputSourceList(nil,false).takeRetainedValue() as NSArray
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        for s in sources {
            let source = s as! TISInputSource
            guard let selectable = TISGetInputSourceProperty(source,kTISPropertyInputSourceIsSelectCapable),
                  CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(selectable).takeUnretainedValue()),
                  sourceString(source,kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String),
                  let label = sourceString(source,kTISPropertyLocalizedName) else { continue }
            owner.add(m,label) {
                if TISSelectInputSource(source) != noErr { NSSound.beep() }
                self.owner.render()
            }
            if sourceString(source,kTISPropertyInputSourceID) == sourceString(current,kTISPropertyInputSourceID) { m.items.last?.state = .on }
        }
        m.addItem(.separator())
        owner.add(m,"Настройки клавиатуры…") { self.openSettings("com.apple.Keyboard-Settings.extension") }
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
                self.extras = AXIsProcessTrusted() ? result : []; self.scanning = false; self.owner.render()
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
        guard let shelf = clock.window, let screen = shelf.screen else { return }
        let calendar = ShelfCalendar { [weak self] in self?.openNotifications() }
        let card = NSHostingView(rootView:calendar.background(Color(nsColor:.windowBackgroundColor)))
        let panel = SlidingShelfPanel(title:"Календарь",card:card,above:clock,in:shelf,screen:screen)
        slidingPanel = panel
        panel.showPanel()
    }
    private func openNotifications() {
        slidingPanel?.dismiss()
        if let clock = extras.first(where:{ family($0) == "clock" }) { press(clock) }
    }

    private func dismissPopover(for anchor: NSButton) -> Bool {
        slidingPanel?.dismiss()
        let wasOpen = popover?.isShown == true && popoverAnchor === anchor
        popover?.performClose(nil)
        return wasOpen
    }
    func popoverDidShow(_ notification: Notification) {
        guard let panel = notification.object as? NSPopover,
              let window = panel.contentViewController?.view.window, let anchor = popoverAnchor else { return }
        popoverClicks.start(window:window,anchor:anchor) { [weak panel] in panel?.performClose(nil) }
    }

    func popoverWillClose(_ notification: Notification) { popoverClicks.stop() }

    private func present(_ controller:NSViewController, above anchor:NSButton, size:NSSize? = nil,
                         dismissOnOutsideClick:Bool = false) {
        let panel = NSPopover()
        panel.animates = false
        panel.behavior = dismissOnOutsideClick ? .applicationDefined : .transient
        if dismissOnOutsideClick { panel.delegate = self }
        panel.contentViewController = controller
        if let size { panel.contentSize = size }
        popover = panel
        popoverAnchor = anchor
        panel.show(relativeTo:anchor.bounds,of:anchor,preferredEdge:.maxY)
    }
    private func showControls(_ page:TrayPage, above anchor:NSButton) {
        if dismissPopover(for:anchor) { return }
        let controls = TrayControls(initialPage:page) { [weak self] pane in
            self?.popover?.performClose(nil)
            self?.openSettings(pane)
        }
        present(NSHostingController(rootView:controls),above:anchor,dismissOnOutsideClick:true)
    }
    private func showApplicationGrid(_ entries: [Extra], above anchor: NSButton) {
        if dismissPopover(for:anchor) { return }
        let sorted = entries.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        let grid = StatusIconGrid(entries:sorted) { [weak self, weak anchor] entry in
            guard let self, let anchor else { return }
            self.popover?.performClose(nil)
            if !entry.app.isTerminated { self.showExtra(entry,above:anchor) }
        }
        present(NSHostingController(rootView:grid),above:anchor,size:grid.size)
    }
    typealias Control = (label:String,symbol:String?,text:String?,icon:NSImage?,click:(NSButton)->Void)
    private var actions: [(NSButton)->Void] = []
    @objc func invoke(_ b:NSButton) {
        if actions.indices.contains(b.tag) { actions[b.tag](b) }
    }
    func layout(_ width:CGFloat) -> CGFloat {
        apple.frame = NSRect(x:1,y:3,width:44,height:44)
        scan()
        var controls: [Control] = []
        let wifi = CWWiFiClient.shared().interface()
        func system(_ page:TrayPage, _ label:String, _ symbol:String) {
            controls.append((label,symbol,nil,nil,{ button in self.showControls(page,above:button) }))
        }
        controls.append(("Источник ввода",nil,inputCode(),nil,{ button in
            self.popover?.performClose(nil)
            self.inputs(button)
        }))
        system(.wifi,"Wi-Fi",wifi?.powerOn() == false ? "wifi.slash" : "wifi")
        system(.sound,"Звук","speaker.wave.2")
        if let battery = BatteryStatus.current() {
            controls.append(("Аккумулятор · " + battery.description, nil, nil, battery.trayIcon, { button in
                self.showControls(.battery, above:button)
            }))
        }
        // Ignore native duplicates and the intentionally hidden Control Center and Spotlight.
        let excludedFamilies: Set<String> = ["keyboard","wifi","sound","battery","bluetooth","control","clock","spotlight"]
        let extraItems = extras.filter { !excludedFamilies.contains(family($0)) }
        let applications = extraItems.filter { $0.app.bundleIdentifier?.hasPrefix("com.apple.") != true }
        if !applications.isEmpty {
            controls.insert(("Значки приложений","chevron.up",nil,nil,{ button in
                self.showApplicationGrid(applications,above:button)
            }),at:0)
        }
        for extra in extraItems where extra.app.bundleIdentifier?.hasPrefix("com.apple.") == true {
            let icon = extra.app.icon?.copy() as? NSImage
            icon?.size = NSSize(width:17,height:17)
            controls.append((extra.label,nil,nil,icon,
                             { button in self.showExtra(extra,above:button) }))
        }
        let slots = max(2,Int(width*0.32/32))
        if controls.count > slots {
            let overflow = Array(controls.dropFirst(slots-1))
            controls = Array(controls.prefix(slots-1))
            controls.append(("Другие значки","chevron.up",nil,nil,{ button in
                let menu = NSMenu()
                for c in overflow { self.owner.add(menu,c.label) { c.click(button) } }
                self.popUp(menu,above:button)
            }))
        }
        actions = controls.map { $0.click }
        while buttons.count < controls.count {
            let b = ShelfButton(frame:.zero); b.contentTintColor = .white; b.isBordered = false; b.font = .systemFont(ofSize:12,weight:.semibold)
            b.target = self; b.action = #selector(invoke(_:)); surface.addSubview(b); buttons.append(b)
        }
        while buttons.count > controls.count { buttons.removeLast().removeFromSuperview() }
        let left = owner.clockLabel.frame.minX-4-CGFloat(controls.count)*32
        for (i,c) in controls.enumerated() {
            let b = buttons[i]; b.tag = i; b.toolTip = c.label; b.setAccessibilityLabel(c.label)
            b.title = c.text ?? ""
            if let symbol = c.symbol { b.image = NSImage(systemSymbolName:symbol,accessibilityDescription:c.label) }
            else { b.image = c.icon }
            b.frame = NSRect(x:left+CGFloat(i)*32,y:7,width:32,height:36)
        }
        return left
    }
}
