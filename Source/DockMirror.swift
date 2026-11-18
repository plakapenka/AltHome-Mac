import SwiftUI
import ApplicationServices

struct DockEntry: Equatable {
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
        return (attr(list, kAXChildrenAttribute) as? [AXUIElement] ?? []).compactMap { item in
            var result: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(item, keys, [], &result) == .success,
                  let values = result as? [Any], values.count == 4, let role = values[0] as? String else { return nil }
            let title = values[1] as? String ?? ""
            guard !title.isEmpty || role == "AXSeparatorDockItem" else { return nil }
            return DockEntry(element: item, role: role, title: title, url: values[2] as? URL,
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

final class DockMirror: ObservableObject {
    @Published private(set) var entries: [DockEntry] = []
    var onFirstEntries: (() -> Void)?
    private var reading = false
    func refresh() {
        guard !reading else { return }
        reading = true
        DispatchQueue.global(qos: .utility).async {
            let entries = DockEntry.read()
            DispatchQueue.main.async {
                self.reading = false
                if self.entries != entries { self.entries = entries }
                if !entries.isEmpty {
                    let ready = self.onFirstEntries
                    self.onFirstEntries = nil
                    ready?()
                }
            }
        }
    }
}

struct DockRow: View {
    @ObservedObject var mirror: DockMirror
    let availableWidth: CGFloat
    let open: (DockEntry) -> Void
    @State private var hover: Int?

    static func width(for entries: [DockEntry]) -> CGFloat {
        16 + entries.reduce(0) { $0 + ($1.role == "AXSeparatorDockItem" ? 13 : 50) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(mirror.entries.indices, id: \.self) { i in
                    let entry = mirror.entries[i]
                    if entry.role == "AXSeparatorDockItem" {
                        Divider().frame(width: 13, height: 34)
                    } else {
                        Button { open(entry) } label: {
                            VStack(spacing: 1) {
                                Image(nsImage: entry.icon).resizable().scaledToFit().frame(width: 40, height: 40)
                                Circle().fill(entry.running ? Color.primary : .clear).frame(width: 4, height: 4)
                            }
                            .frame(width: 50, height: 52)
                            .background(MenuAppearance.selection(hover == i))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(entry.title).accessibilityLabel(entry.title)
                        .onHover { inside in
                            if inside { hover = i } else if hover == i { hover = nil }
                        }
                    }
                }
            }.padding(.horizontal, 8).padding(.vertical, 5)
        }.frame(width: availableWidth, height: 62).background(.regularMaterial)
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

// Only touch the two auto-hide settings. Preserve absent keys and later edits made outside TaskShelf.
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
