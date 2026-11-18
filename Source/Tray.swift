import AppKit
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
final class Tray {
    unowned let owner: Delegate
    let apple = NSButton()
    var buttons: [NSButton] = []
    var extras: [Extra] = []
    var scanTime = Date.distantPast
    var scanning = false
    var surface: NSView!
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
        m.popUp(positioning:nil,at:NSPoint(x:0,y:button.bounds.maxY+4),in:button)
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
                guard let menu = element(root,kAXExtrasMenuBarAttribute),
                      let children = attr(menu,kAXChildrenAttribute) as? [AXUIElement] else { continue }
                for child in children {
                    let id = attr(child,kAXIdentifierAttribute) as? String ?? ""
                    let name = [kAXDescriptionAttribute,kAXTitleAttribute,kAXHelpAttribute].compactMap { attr(child,$0) as? String }.first(where:{!$0.isEmpty}) ?? app.localizedName ?? "Меню"
                    items.append(Extra(label:name,identifier:id,app:app,target:child))
                }
            }
            let result = items
            DispatchQueue.main.async {
                self.extras = AXIsProcessTrusted() ? result : []; self.scanning = false; self.owner.render()
            }
        }
    }
    private func family(_ e:Extra) -> String {
        let s = (e.identifier+" "+e.label).lowercased().replacingOccurrences(of:"‑",with:"-")
        for (key,terms) in [("wifi",["wi-fi","wifi"]),("battery",["battery","аккумулятор","батаре"]),("keyboard",["inputmenu","textinput","источник ввода","меню ввода"]),("sound",["volume","sound","громкость","звук"]),("bluetooth",["bluetooth"]),("control",["control center","пункт управления","controlcenter.controlcenter"])] where terms.contains(where:{s.contains($0)}) { return key }
        return ""
    }
    private func press(_ e:Extra) {
        if AXUIElementPerformAction(e.target,kAXPressAction as CFString) != .success { NSSound.beep() }
    }
    typealias Control = (label:String,symbol:String?,text:String?,icon:NSImage?,click:(NSButton)->Void)
    private var actions: [(NSButton)->Void] = []
    @objc func invoke(_ b:NSButton) { if actions.indices.contains(b.tag) { actions[b.tag](b) } }
    func layout(_ width:CGFloat) -> CGFloat {
        apple.frame = NSRect(x:0,y:2,width:44,height:46)
        scan()
        var controls: [Control] = []
        let wifi = CWWiFiClient.shared().interface()
        func system(_ key:String,_ label:String,_ symbol:String,_ pane:String) {
            let match = extras.first { family($0)==key }
            controls.append((label,symbol,nil,nil,{ _ in
                if let match { self.press(match) } else { self.openSettings(pane) }
            }))
        }
        controls.append(("Источник ввода",nil,inputCode(),nil,{ self.inputs($0) }))
        system("wifi","Wi-Fi",wifi?.powerOn() == false ? "wifi.slash" : "wifi","com.apple.wifi-settings-extension")
        system("sound","Звук","speaker.wave.2","com.apple.Sound-Settings.extension")
        system("bluetooth","Bluetooth","antenna.radiowaves.left.and.right","com.apple.BluetoothSettings")
        if let value = charge() {
            let step = min(4,(value+12)/25)*25
            system("battery","Аккумулятор · "+String(value)+"%","battery."+String(step)+"percent","com.apple.Battery-Settings.extension")
        }
        system("control","Пункт управления","switch.2","com.apple.ControlCenter-Settings.extension")
        var consumed = Set<AXUIElement>()
        for key in ["keyboard","wifi","sound","battery","bluetooth","control"] {
            if let first = extras.first(where:{ family($0) == key }) { consumed.insert(first.target) }
        }
        for extra in extras where !consumed.contains(extra.target) {
            controls.append((extra.label,nil,nil,extra.app.icon,{ _ in self.press(extra) }))
        }
        let slots = max(2,Int(width*0.32/32))
        if controls.count > slots {
            let overflow = Array(controls.dropFirst(slots-1))
            controls = Array(controls.prefix(slots-1))
            controls.append(("Другие значки","chevron.up",nil,nil,{ button in
                let menu = NSMenu()
                for c in overflow { self.owner.add(menu,c.label) { c.click(button) } }
                menu.popUp(positioning:nil,at:NSPoint(x:0,y:36),in:button)
            }))
        }
        actions = controls.map { $0.click }
        while buttons.count < controls.count {
            let b = NSButton(); b.isBordered = false; b.font = .systemFont(ofSize:12,weight:.semibold)
            b.target = self; b.action = #selector(invoke(_:)); surface.addSubview(b); buttons.append(b)
        }
        while buttons.count > controls.count { buttons.removeLast().removeFromSuperview() }
        let left = width-103-CGFloat(controls.count)*32
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
