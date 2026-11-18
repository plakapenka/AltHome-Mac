import AppKit

// A status-item NSMenu belongs to another process and has no writable AX position.
// Present its current menu items locally, then resolve the chosen command in its owner.
extension Tray {
    private struct MenuStep {
        let index: Int
        let title: String
    }

    private func openStatusMenu(_ entry: Extra) -> AXUIElement? {
        let root = AXUIElementCreateApplication(entry.app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,0.25)
        func visibleMenu(_ parent: AXUIElement, depth: Int) -> AXUIElement? {
            if attr(parent,kAXRoleAttribute) as? String == kAXMenuRole {
                return (windowRect(parent)?.height ?? 0) > 1 ? parent : nil
            }
            guard depth > 0 else { return nil }
            for child in attr(parent,kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let m = visibleMenu(child,depth:depth-1) { return m }
            }
            return nil
        }
        if let menu = visibleMenu(entry.target,depth:2) { return menu }
        guard let bar = element(root,kAXExtrasMenuBarAttribute) else { return nil }
        return visibleMenu(bar,depth:4)
    }

    private func copyItems(_ source: AXUIElement, entry: Extra, path: [MenuStep]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (i,item) in (attr(source,kAXChildrenAttribute) as? [AXUIElement] ?? []).enumerated() {
            let title = attr(item,kAXTitleAttribute) as? String ?? ""
            guard !title.isEmpty else { menu.addItem(.separator()); continue }
            let steps = path + [MenuStep(index:i,title:title)]
            owner.add(menu,title) { [weak self] in self?.performCommand(steps,entry:entry) }
            guard let copy = menu.items.last else { continue }
            copy.isEnabled = attr(item,kAXEnabledAttribute) as? Bool ?? true
            if let mark = attr(item,kAXMenuItemMarkCharAttribute) as? String, !mark.isEmpty { copy.state = .on }
            if let sub = submenu(of:item), path.count < 5 {
                copy.submenu = copyItems(sub,entry:entry,path:steps)
            }
        }
        return menu
    }

    private func submenu(of item: AXUIElement) -> AXUIElement? {
        (attr(item,kAXChildrenAttribute) as? [AXUIElement] ?? []).first { attr($0,kAXRoleAttribute) as? String == kAXMenuRole }
    }

    private func performCommand(_ path: [MenuStep], entry: Extra) {
        guard press(entry), let root = openStatusMenu(entry) else { return }
        var menu = root
        for (depth,step) in path.enumerated() {
            let items = attr(menu,kAXChildrenAttribute) as? [AXUIElement] ?? []
            guard items.indices.contains(step.index),
                  attr(items[step.index],kAXTitleAttribute) as? String == step.title else { break }
            let item = items[step.index]
            if depth == path.count-1 {
                guard attr(item,kAXEnabledAttribute) as? Bool != false else { break }
                _ = AXUIElementPerformAction(item,kAXPressAction as CFString)
                return
            }
            guard let sub = submenu(of:item) else { break }
            menu = sub
        }
        _ = AXUIElementPerformAction(root,kAXCancelAction as CFString)
    }

    private func storedMenu(_ entry: Extra) -> AXUIElement? {
        if let menu = submenu(of:entry.target) { return menu }
        let root = AXUIElementCreateApplication(entry.app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,0.2)
        guard let bar = element(root,kAXExtrasMenuBarAttribute) else { return nil }
        let items = attr(bar,kAXChildrenAttribute) as? [AXUIElement] ?? []
        let match = items.first { item in
            (!entry.identifier.isEmpty && attr(item,kAXIdentifierAttribute) as? String == entry.identifier)
                || [kAXDescriptionAttribute,kAXTitleAttribute,kAXHelpAttribute].contains { attr(item,$0) as? String == entry.label }
        }
        return (match ?? (items.count == 1 ? items.first : nil)).flatMap { submenu(of:$0) }
    }

    func showExtra(_ entry: Extra, above button: NSButton) {
        if let source = storedMenu(entry) {
            let menu = copyItems(source,entry:entry,path:[])
            if !menu.items.isEmpty { popUp(menu,above:button); return }
        }
        press(entry)
    }
}
