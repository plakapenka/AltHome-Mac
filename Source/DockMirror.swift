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

struct DockRow: View {
    @ObservedObject var mirror: DockMirror
    let availableWidth: CGFloat
    let open: (DockEntry) -> Void
    @AppStorage("dockIconSize") private var iconSize = DockSizing.systemSize
    @AppStorage("dockMagnifies") private var magnifies = true
    @AppStorage("dockZoom") private var zoom = 1.55
    @State private var dragged: String?
    @State private var pointer: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        let side = min(CGFloat(iconSize), max(16, floor(fitting)))
        let pitch = side + 2
        let naturalWidth = margins + CGFloat(count) * pitch
        var center: CGFloat = 8
        let sizes = mirror.entries.map { entry -> CGFloat in
            if entry.role == "AXSeparatorDockItem" { center += 12; return 0 }
            defer { center += pitch }
            guard magnifies, let pointer else { return side }
            let distance = min(1, abs(center + pitch / 2 - pointer) / (2 * pitch))
            let weight = (1 + cos(.pi * distance)) / 2
            return side * (1 + (zoom - 1) * weight)
        }
        let contentWidth = margins + sizes.reduce(0, +) + CGFloat(count) * 2
        let width = min(availableWidth, contentWidth)
        var leading: CGFloat = 8
        let centers = sizes.map { size -> CGFloat in
            let width = size == 0 ? 12 : size + 2
            defer { leading += width }
            return leading + width / 2
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(mirror.entries.enumerated()), id: \.element.key) { i, entry in
                    let tileSize = sizes[i]
                    if entry.role == "AXSeparatorDockItem" {
                        Rectangle().fill(.primary.opacity(0.22))
                            .frame(width: 1, height: side * 0.76).frame(width: 12, height: side + 14)
                    } else {
                        Button { open(entry) } label: {
                            VStack(spacing: 1) {
                                Image(nsImage: entry.icon).resizable().scaledToFit().frame(width: tileSize, height: tileSize)
                                Circle().fill(entry.running ? Color.primary.opacity(0.85) : .clear)
                                    .frame(width: 3.5, height: 3.5)
                            }
                            .frame(width: tileSize + 2, height: tileSize + 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(DockPressStyle()).help(entry.title).accessibilityLabel(entry.title)
                        .opacity(dragged == entry.key ? 0.8 : 1)
                        .highPriorityGesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("Dock strip"))
                            .onChanged { value in
                                dragged = entry.key
                                mirror.dragging = true
                                let target = dragDestination(from: i, centers: centers, x: value.location.x)
                                if target != i {
                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.17)) {
                                        mirror.move(entry.key, to: target)
                                    }
                                }
                            }
                            .onEnded { _ in dragged = nil; mirror.dragging = false })
                    }
                }
            }.padding(.horizontal, 8)
                .coordinateSpace(name: "Dock strip")
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard dragged == nil else { return }
                    switch phase {
                    case .active(let point):
                        if magnifies { pointer = point.x * naturalWidth / max(contentWidth, 1) }
                    case .ended: pointer = nil
                    }
                }
        }
        .frame(width: width, height: (sizes.max() ?? side) + 14, alignment: .bottom)
        .background(plate)
        .onDisappear { mirror.dragging = false }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: pointer != nil)
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
