// swiftc Source/FnCommand.swift Tests/FnCommandTests.swift -o /tmp/check-fn-command
import AppKit
import Carbon

@main
struct FnCommandTests {
    static func main() {
        let handler = FnCommand()
        let fn = CGEventFlags.maskSecondaryFn, cmd = CGEventFlags.maskCommand
        func check(_ type: CGEventType, _ key: Int, _ flags: CGEventFlags, _ expected: CGEventFlags, repeatKey: Bool = false) {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: type == .keyDown)!
            event.type = type
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
            handler.translate(type, event: event)
            precondition(event.flags == expected)
        }
        for key in [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_Z] {
            check(.keyDown, key, fn, cmd)
            check(.keyDown, key, [], cmd, repeatKey: true)
            check(.keyUp, key, [], cmd)
            check(.keyDown, key, [], [])
            check(.keyDown, key, fn, fn, repeatKey: true)
            check(.keyUp, key, fn, fn)
        }
        check(.keyDown, kVK_ANSI_Z, [fn,.maskShift], [cmd,.maskShift])
        check(.keyDown, kVK_ANSI_C, fn, cmd)
        check(.keyUp, kVK_ANSI_Z, [.maskShift], [cmd,.maskShift])
        check(.keyUp, kVK_ANSI_C, [], cmd)
        for key in [kVK_UpArrow, kVK_F1, kVK_Delete, kVK_ANSI_1] {
            check(.keyDown, key, fn, fn)
            check(.keyUp, key, fn, fn)
        }
        check(.flagsChanged, kVK_Function, fn, fn)
        check(.flagsChanged, kVK_Function, [], [])
        print("PASS Fn shortcuts, repeats, release order, untouched Fn and non-letter keys")
    }
}
