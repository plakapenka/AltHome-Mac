import AppKit
import ApplicationServices

/// One queue per application so a slow AX server cannot delay another app's windows.
final class WindowMonitor {
    let app: NSRunningApplication
    private let queue: DispatchQueue
    private let root: AXUIElement
    private let changed: ([WindowEntry]?) -> Void
    // AX subscriptions and reads are confined to queue.
    private var observer: AXObserver?
    private var subscribed = Set<AXUIElement>()
    private var lastEntries: [WindowEntry]?
    private var appEvents = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]
    // Request coalescing and delivery run on the main thread.
    private var pending = false
    private var reading = false
    private var stopped = false

    init(app: NSRunningApplication, changed: @escaping ([WindowEntry]?) -> Void) {
        self.app = app
        self.changed = changed
        root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.35)
        queue = DispatchQueue(label: "TaskShelf.windows.\(app.processIdentifier)", qos: .userInitiated)
    }

    func request() {
        guard !stopped else { return }
        if reading { pending = true; return }
        reading = true
        queue.async {
            let result = self.read()
            DispatchQueue.main.async {
                guard !self.stopped else { return }
                self.reading = false
                self.changed(result)
                if self.pending {
                    self.pending = false
                    self.request()
                }
            }
        }
    }

    func stop() {
        stopped = true
        queue.async {
            if let observer = self.observer {
                self.observer = nil
                DispatchQueue.main.async {
                    // The callback's unretained context must outlive removal on its delivery thread.
                    withExtendedLifetime(self) {
                        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                    }
                }
            }
        }
    }

    private func attach() {
        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            Unmanaged<WindowMonitor>.fromOpaque(context).takeUnretainedValue().request()
        }
        guard AXObserverCreate(app.processIdentifier, callback, &newObserver) == .success,
              let newObserver else { return }
        observer = newObserver
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
    }

    private func subscribe(_ event: String, on element: AXUIElement, using observer: AXObserver) -> Bool {
        let result = AXObserverAddNotification(observer, element, event as CFString, Unmanaged.passUnretained(self).toOpaque())
        return result == .success || result == .notificationAlreadyRegistered || result == .notificationUnsupported
    }

    private func read() -> [WindowEntry]? {
        guard !app.isTerminated else { return [] }
        if observer == nil { attach() }
        if let observer {
            // A launching application can return cannotComplete before its AX server is ready.
            appEvents.removeAll { event in
                subscribe(event, on: root, using: observer)
            }
        }
        var list: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &list)
        if result == .cannotComplete { return lastEntries }
        guard result == .success, let all = list as? [AXUIElement] else {
            lastEntries = nil
            return nil
        }
        let current = Set(all)
        if let observer {
            let events = [kAXUIElementDestroyedNotification, kAXTitleChangedNotification,
                          kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]
            for window in subscribed.subtracting(current) {
                for event in events { AXObserverRemoveNotification(observer, window, event as CFString) }
            }
            subscribed.formIntersection(current)
            for window in current.subtracting(subscribed) {
                if events.allSatisfy({ subscribe($0, on: window, using: observer) }) {
                    subscribed.insert(window)
                }
            }
        }
        let focused = element(root, kAXFocusedWindowAttribute)
        let keys = [kAXRoleAttribute, kAXTitleAttribute, kAXMinimizedAttribute] as CFArray
        let entries: [WindowEntry] = all.compactMap { window in
            var data: CFArray?
            let result = AXUIElementCopyMultipleAttributeValues(window, keys, [], &data)
            if result == .cannotComplete { return lastEntries?.first { $0.window == window } }
            guard result == .success,
                  let values = data as? [Any], values.count == 3,
                  values[0] as? String == kAXWindowRole else { return nil }
            return WindowEntry(window: window, title: values[1] as? String ?? "",
                               focused: focused == window && values[2] as? Bool != true)
        }
        lastEntries = entries
        return entries
    }
}
