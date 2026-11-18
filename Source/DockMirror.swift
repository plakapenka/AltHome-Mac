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
    @Published private(set) var iconSize: CGFloat = 45
    var onFirstEntries: (() -> Void)?
    private var reading = false
    func refresh() {
        guard !reading else { return }
        reading = true
        DispatchQueue.global(qos: .utility).async {
            let entries = DockEntry.read()
            let tile = CFPreferencesCopyAppValue("tilesize" as CFString, "com.apple.dock" as CFString) as? NSNumber
            let size = CGFloat(min(128, max(16, tile?.doubleValue ?? 48)))
            DispatchQueue.main.async {
                self.reading = false
                if self.iconSize != size { self.iconSize = size }
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
    static let cornerRadius: CGFloat = 18

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    @ViewBuilder private var plate: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.regularMaterial)
                .overlay(shape.strokeBorder(.primary.opacity(0.16), lineWidth: 0.5))
        }
    }

    var body: some View {
        let count = mirror.entries.filter { $0.role != "AXSeparatorDockItem" }.count
        let separators = mirror.entries.count - count
        let margins = CGFloat(16 + separators * 12)
        let fitting = (availableWidth - margins) / CGFloat(max(count, 1)) - 2
        let side = min(mirror.iconSize, max(24, floor(fitting)))
        let width = min(availableWidth, margins + CGFloat(count) * (side + 2))
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(mirror.entries.indices, id: \.self) { i in
                    let entry = mirror.entries[i]
                    if entry.role == "AXSeparatorDockItem" {
                        Rectangle().fill(.primary.opacity(0.22))
                            .frame(width: 1, height: side * 0.76).frame(width: 12)
                    } else {
                        Button { open(entry) } label: {
                            VStack(spacing: 1) {
                                Image(nsImage: entry.icon).resizable().scaledToFit().frame(width: side, height: side)
                                Circle().fill(entry.running ? Color.primary.opacity(0.85) : .clear)
                                    .frame(width: 3.5, height: 3.5)
                            }
                            .frame(width: side + 2, height: side + 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(DockPressStyle()).help(entry.title).accessibilityLabel(entry.title)
                    }
                }
            }.padding(.horizontal, 8)
        }
        .frame(width: width, height: side + 14)
        .background(plate)
    }
}

private struct DockPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
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
