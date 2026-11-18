import AppKit
import Carbon

final class FnCommand {
    private static let letters: Set<CGKeyCode> = Set([
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
        kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
        kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
        kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
        kVK_ANSI_Y, kVK_ANSI_Z
    ].map(CGKeyCode.init))

    private var tap: CFMachPort?
    private var heldLetters = Set<CGKeyCode>()

    func translate(_ type: CGEventType, event: CGEvent) {
        guard type == .keyDown || type == .keyUp else { return }
        let hasFn = event.flags.contains(.maskSecondaryFn)
        guard hasFn || !heldLetters.isEmpty else { return }
        let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp {
            guard heldLetters.remove(key) != nil else { return }
        } else if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            heldLetters.remove(key)
            guard hasFn, Self.letters.contains(key) else { return }
            heldLetters.insert(key)
        } else if !heldLetters.contains(key) {
            return
        }
        event.flags.remove(.maskSecondaryFn)
        event.flags.insert(.maskCommand)
    }

    func setEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            if let tap { CFMachPortInvalidate(tap) }
            tap = nil
            heldLetters.removeAll()
            return true
        }
        if tap != nil { return true }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let handler = Unmanaged<FnCommand>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                handler.heldLetters.removeAll()
                if let tap = handler.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                handler.translate(type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    deinit { _ = setEnabled(false) }
}
