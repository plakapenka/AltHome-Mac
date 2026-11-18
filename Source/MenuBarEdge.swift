import AppKit

/// Quartz display coordinates have their origin at the top left of the main display.
final class MenuBarEdge {
    private static let clearance: CGFloat = 6
    private var displays: [CGRect] = []
    private var tap: CFMachPort?
    private var displayObserver: NSObjectProtocol?

    static func constrained(_ point: CGPoint, displays: [CGRect]) -> CGPoint? {
        guard let display = displays.first(where: { $0.contains(point) }),
              point.y < display.minY + clearance else { return nil }
        // Leave a shared edge open when another display is immediately above this one.
        let above = CGPoint(x: point.x, y: display.minY - 0.5)
        guard !displays.contains(where: { $0.contains(above) }) else { return nil }
        return CGPoint(x: point.x, y: display.minY + clearance)
    }

    private func updateDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(number.uint32Value)
        }
    }

    func start() -> Bool {
        if tap != nil { return true }
        let events: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let edge = Unmanaged<MenuBarEdge>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = edge.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if let point = MenuBarEdge.constrained(event.location, displays: edge.displays) {
                event.location = point
            }
            return Unmanaged.passUnretained(event)
        }
        // Adjust the movement before session-level consumers can trigger menu bar reveal.
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        updateDisplays()
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in self?.updateDisplays() }
        tap = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        // Enabling the switch also works if the pointer is already resting at the edge.
        if let location = CGEvent(source: nil)?.location, let point = Self.constrained(location, displays: displays) {
            CGWarpMouseCursorPosition(point)
        }
        return true
    }

    func stop() {
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
    }

    deinit { stop() }
}
