import SwiftUI
import ApplicationServices

struct DockEntry: Equatable {
    let key: String
    let element: AXUIElement
    let role: String
    let title: String
    let url: URL?
    let running: Bool

    static func read() -> [DockEntry] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        let lists = attr(root, kAXChildrenAttribute) as? [AXUIElement] ?? []
        guard let list = lists.first(where: { attr($0, kAXRoleAttribute) as? String == kAXListRole }) else { return [] }
        let keys = [kAXSubroleAttribute, kAXTitleAttribute, kAXURLAttribute, "AXIsApplicationRunning"] as CFArray
        var occurrences: [String: Int] = [:]
        return (attr(list, kAXChildrenAttribute) as? [AXUIElement] ?? []).compactMap { item in
            var result: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(item, keys, [], &result) == .success,
                  let values = result as? [Any], values.count == 4, let role = values[0] as? String else { return nil }
            let title = values[1] as? String ?? ""
            guard !title.isEmpty || role == "AXSeparatorDockItem" else { return nil }
            let url = values[2] as? URL
            let identity = role == "AXWindowDockItem" ? String(CFHash(item)) : (url?.absoluteString ?? title)
            let base = role + "|" + identity
            let occurrence = occurrences[base, default: 0]
            occurrences[base] = occurrence + 1
            return DockEntry(key: base + "|" + String(occurrence), element: item, role: role, title: title, url: url,
                             running: values[3] as? Bool == true)
        }
    }

    var icon: NSImage {
        if let url, url.isFileURL { return NSWorkspace.shared.icon(forFile: url.path) }
        if role == "AXTrashDockItem", let trash = NSImage(named: NSImage.trashEmptyName) { return trash }
        let symbol = role == "AXWindowDockItem" ? "macwindow" : (url != nil ? "globe" : "app")
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
    }

    func open() {
        // Open folder stacks in Finder so their system popover cannot cover the shelf.
        if role == "AXFolderDockItem", let url {
            if !NSWorkspace.shared.open(url) { NSSound.beep() }
        } else if AXUIElementPerformAction(element, kAXPressAction as CFString) != .success {
            if let url, ["file", "http", "https"].contains(url.scheme) {
                if !NSWorkspace.shared.open(url) { NSSound.beep() }
            } else { NSSound.beep() }
        }
    }
}

enum DockSizing {
    static var systemSize: Double {
        let value = CFPreferencesCopyAppValue("tilesize" as CFString, "com.apple.dock" as CFString) as? NSNumber
        return min(128, max(16, value?.doubleValue ?? 48))
    }
}

final class DockMirror: ObservableObject {
    @Published private(set) var entries: [DockEntry] = []
    var onFirstEntries: (() -> Void)?
    private var reading = false
    private let defaults: UserDefaults
    private var order: [String]
    var dragging = false
    init(defaults: UserDefaults) {
        self.defaults = defaults
        order = defaults.stringArray(forKey: "dockItemOrder") ?? []
    }

    func move(_ key: String, to target: Int) {
        guard let index = entries.firstIndex(where: { $0.key == key }),
              entries.indices.contains(target), index != target else { return }
        var moved = entries
        moved.insert(moved.remove(at: index), at: target)
        let keys = moved.map(\.key)
        order = rememberedOrder(keys, previous: order)
        defaults.set(order.filter { !$0.hasPrefix("AXWindowDockItem|") }, forKey: "dockItemOrder")
        entries = moved
    }

    func refresh() {
        guard !reading else { return }
        reading = true
        DispatchQueue.global(qos: .utility).async {
            let entries = DockEntry.read()
            DispatchQueue.main.async {
                self.reading = false
                let byKey = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
                let sorted = arranged(entries.map(\.key), preferred: self.order).compactMap { byKey[$0] }
                if self.entries != sorted { self.entries = sorted }
                if !entries.isEmpty {
                    let ready = self.onFirstEntries
                    self.onFirstEntries = nil
                    ready?()
                }
            }
        }
    }
}

final class DockEdge: NSButton {
    var entered: (() -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { entered?() }
}

enum DockMode: String {
    case system, taskShelf, hidden

    static func saved(in defaults: UserDefaults) -> DockMode {
        if let raw = defaults.string(forKey: "dockMode"), let mode = DockMode(rawValue: raw) { return mode }
        return defaults.bool(forKey: "mirrorSystemDock") ? .taskShelf : .system
    }
}

// Only touch the two auto-hide settings. Preserve absent keys and later edits made outside AltHome Mac.
enum SystemDockVisibility {
    private static let domain = "com.apple.dock" as CFString
    private static let hidden: [String: NSNumber] = ["autohide": true, "autohide-delay": 86400]
    private static let backupKey = "nativeDockBeforeMirror"

    static func apply(hidden enable: Bool, defaults: UserDefaults) -> Bool {
        let user = kCFPreferencesCurrentUser, host = kCFPreferencesAnyHost
        var backup = defaults.dictionary(forKey: backupKey)
        guard enable || backup != nil else { return true }
        guard CFPreferencesSynchronize(domain, user, host) else { return false }
        func read(_ key: String) -> NSNumber? {
            CFPreferencesCopyValue(key as CFString, domain, user, host) as? NSNumber
        }
        if enable && backup == nil {
            backup = hidden.keys.reduce(into: [String: Any]()) { result, key in result[key] = read(key) }
            defaults.set(backup, forKey: backupKey)
            defaults.synchronize()
        }
        var changed = false
        for (key, desired) in hidden {
            let current = read(key)
            let target = enable ? desired : backup?[key] as? NSNumber
            guard current != target, enable || current == desired else { continue }
            CFPreferencesSetValue(key as CFString, target, domain, user, host)
            changed = true
        }
        guard CFPreferencesSynchronize(domain, user, host) else { return false }
        if !enable { defaults.removeObject(forKey: backupKey) }
        if changed, let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            kill(dock.processIdentifier, SIGTERM)
        }
        return true
    }
}
