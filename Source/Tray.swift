import AppKit
import SwiftUI
import Carbon
import CoreWLAN
import IOKit.ps

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
private func charge() -> Int? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for source in sources {
        guard let dict = IOPSGetPowerSourceDescription(info,source)?.takeUnretainedValue() as? [String:Any],
              dict[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let value = dict[kIOPSCurrentCapacityKey] as? Int,
              let max = dict[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        return min(100,value*100/max)
    }
    return nil
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

final class Tray {
    unowned let owner: Delegate
    let apple = ShelfButton(frame:.zero)
    var buttons: [NSButton] = []
    var extras: [Extra] = []
    var scanTime = Date.distantPast
    var scanning = false
    var surface: NSView!
    private var popover: NSPopover?
    private weak var popoverAnchor: NSButton?
    init(_ owner: Delegate) { self.owner = owner }
    func install(_ view: NSView) {
        surface = view
        let font = NSFont.systemFont(ofSize:26, weight:.medium)
        if let symbol = NSImage(systemSymbolName:"apple.logo", accessibilityDescription:"Меню Apple") {
            apple.image = symbol.withSymbolConfiguration(.init(pointSize:font.pointSize, weight:.medium)) ?? symbol
            apple.imagePosition = .imageOnly
            apple.imageScaling = .scaleNone
        } else {
            apple.attributedTitle = NSAttributedString(string:"", attributes:[.font:font,.foregroundColor:NSColor.white])
        }
        apple.contentTintColor = .white
        apple.setAccessibilityLabel("Меню Apple")
        apple.isBordered = false
        apple.target = self; apple.action = #selector(showApple)
        apple.toolTip = "Меню Apple"
        view.addSubview(apple)
    }
    func openSettings(_ pane:String) {
        if let url = URL(string:"x-apple.systempreferences:"+pane) { owner.ws.open(url) }
    }
    @objc func showApple() {
        if AXIsProcessTrusted(), let app = owner.ws.frontmostApplication {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root,0.4)
            if let bar = element(root,kAXMenuBarAttribute),
               let list = attr(bar,kAXChildrenAttribute) as? [AXUIElement],
               let appleItem = list.first(where:{ attr($0,kAXSubroleAttribute) as? String == "AXAppleMenu" || (attr($0,kAXTitleAttribute) as? String) == "Apple" || (attr($0,kAXTitleAttribute) as? String) == "" }),
               AXUIElementPerformAction(appleItem,kAXPressAction as CFString) == .success { return }
        }
        let m = NSMenu()
        owner.add(m,"Об этом Mac") { self.owner.ws.open(URL(fileURLWithPath:"/System/Library/CoreServices/Applications/About This Mac.app")) }
        owner.add(m,"Системные настройки…") { self.owner.ws.open(URL(fileURLWithPath:"/System/Applications/System Settings.app")) }
        owner.add(m,"App Store…") { self.owner.ws.open(URL(fileURLWithPath:"/System/Applications/App Store.app")) }
        m.popUp(positioning:nil,at:NSPoint(x:0,y:apple.bounds.maxY+4),in:apple)
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
        if dismissPopover(for:owner.clockLabel) { return }
        let calendar = NSDatePicker()
        calendar.datePickerStyle = .clockAndCalendar
        calendar.datePickerElements = [.yearMonthDay]
        calendar.dateValue = Date()
        calendar.sizeToFit()
        let view = NSView()
        let showNotifications = NSButton(title:"Центр уведомлений",target:self,action:#selector(openNotifications))
        showNotifications.bezelStyle = .rounded
        showNotifications.sizeToFit()
        let width = max(calendar.frame.width,showNotifications.frame.width)+24
        showNotifications.setFrameOrigin(NSPoint(x:(width-showNotifications.frame.width)/2,y:8))
        calendar.setFrameOrigin(NSPoint(x:(width-calendar.frame.width)/2,y:showNotifications.frame.maxY+8))
        view.frame.size = NSSize(width:width,height:calendar.frame.maxY+12)
        view.addSubview(calendar)
        view.addSubview(showNotifications)
        let controller = NSViewController()
        controller.view = view
        present(controller,above:owner.clockLabel)
    }
    @objc private func openNotifications() {
        popover?.performClose(nil)
        if let clock = extras.first(where:{ family($0) == "clock" }) { press(clock) }
    }

    private func dismissPopover(for anchor: NSButton) -> Bool {
        let wasOpen = popover?.isShown == true && popoverAnchor === anchor
        popover?.performClose(nil)
        return wasOpen
    }
    private func present(_ controller:NSViewController, above anchor:NSButton, size:NSSize? = nil) {
        let panel = NSPopover()
        panel.animates = false
        panel.behavior = .transient
        panel.contentViewController = controller
        if let size { panel.contentSize = size }
        popover = panel
        popoverAnchor = anchor
        panel.show(relativeTo:anchor.bounds,of:anchor,preferredEdge:.maxY)
    }
    private func showControls(_ page:TrayPage, above anchor:NSButton) {
        if dismissPopover(for:anchor) { return }
        let controls = TrayControls(page:page) { [weak self] pane in
            self?.popover?.performClose(nil)
            self?.openSettings(pane)
        }
        present(NSHostingController(rootView:controls),above:anchor)
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
        system(.bluetooth,"Bluetooth","antenna.radiowaves.left.and.right")
        if let value = charge() {
            let step = min(4,(value+12)/25)*25
            system(.battery,"Аккумулятор · "+String(value)+"%","battery."+String(step)+"percent")
        }
        // Ignore native duplicates and the intentionally hidden Control Center.
        let excludedFamilies: Set<String> = ["keyboard","wifi","sound","battery","bluetooth","control","clock"]
        let extraItems = extras.filter { !excludedFamilies.contains(family($0)) }
        let applications = extraItems.filter { $0.app.bundleIdentifier?.hasPrefix("com.apple.") != true }
        if !applications.isEmpty {
            controls.insert(("Значки приложений","chevron.up",nil,nil,{ button in
                self.showApplicationGrid(applications,above:button)
            }),at:0)
        }
        for extra in extraItems where extra.app.bundleIdentifier?.hasPrefix("com.apple.") == true {
            let isSpotlight = ["com.apple.Spotlight","com.apple.campo"].contains(extra.app.bundleIdentifier)
            controls.append((extra.label,isSpotlight ? "magnifyingglass" : nil,nil,
                             isSpotlight ? nil : extra.app.icon,
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
            let b = NSButton(); b.contentTintColor = .white; b.isBordered = false; b.font = .systemFont(ofSize:12,weight:.semibold)
            b.target = self; b.action = #selector(invoke(_:)); surface.addSubview(b); buttons.append(b)
        }
        while buttons.count > controls.count { buttons.removeLast().removeFromSuperview() }
        let left = owner.clockLabel.frame.minX-4-CGFloat(controls.count)*32
        for (i,c) in controls.enumerated() {
            let b = buttons[i]; b.tag = i; b.toolTip = c.label; b.setAccessibilityLabel(c.label)
            b.title = c.text ?? ""
            if let symbol = c.symbol { b.image = NSImage(systemSymbolName:symbol,accessibilityDescription:c.label) }
            else if let icon = c.icon?.copy() as? NSImage { icon.size = NSSize(width:17,height:17); b.image = icon }
            else { b.image = nil }
            b.frame = NSRect(x:left+CGFloat(i)*32,y:7,width:32,height:36)
        }
        return left
    }
}
