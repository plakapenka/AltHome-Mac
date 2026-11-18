import AppKit

/// Fires once, on release. Any other input during the chord belongs to the active app.
struct LayoutChord {
    private var armed = false
    private var cancelled = false

    mutating func handle(_ type: CGEventType, flags: CGEventFlags) -> Bool {
        let pair: CGEventFlags = [.maskCommand, .maskShift]
        let held = flags.intersection(pair)
        if held.isEmpty {
            let fire = type == .flagsChanged && armed && !cancelled
            self = LayoutChord()
            return fire
        }
        if type != .flagsChanged || !flags.intersection([.maskAlternate, .maskControl, .maskSecondaryFn]).isEmpty {
            cancelled = true
        } else if held == pair {
            armed = true
        }
        return false
    }
}

final class LayoutShortcut {
    private var tap: CFMachPort?
    private var chord = LayoutChord()
    private let switchLayout: () -> Void

    init(switchLayout: @escaping () -> Void) { self.switchLayout = switchLayout }

    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let shortcut = Unmanaged<LayoutShortcut>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                shortcut.chord = LayoutChord()
                if let tap = shortcut.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if shortcut.chord.handle(type, flags: event.flags) {
                shortcut.switchLayout()
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .listenOnly, eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        chord = LayoutChord()
    }
    deinit { stop() }
}
