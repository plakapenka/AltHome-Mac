// Interactive regression check on the main display with system auto-hide set to Always.
// Run once with the AltHome Mac switch on (hidden), then with it off (visible).
// swift Tests/MenuBarHover.swift hidden|visible
import AppKit

func run(expectVisible: Bool) -> Bool {
    let display = CGDisplayBounds(CGMainDisplayID())
    guard CGPreflightPostEventAccess(), let origin = CGEvent(source: nil)?.location else {
        print("The test runner needs Accessibility permission to simulate mouse movement.")
        return false
    }
    func move(to point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
                mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    func visible() -> Bool? {
        let windows = CGWindowListCopyWindowInfo(.optionAll, 0) as? [[String: Any]] ?? []
        for window in windows where window[kCGWindowName as String] as? String == "Menubar"
                                  && window[kCGWindowOwnerName as String] as? String == "Window Server" {
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.minX == display.minX,
                  frame.width == display.width else { continue }
            return window[kCGWindowIsOnscreen as String] as? Bool == true && frame.intersects(display)
        }
        return nil
    }
    defer { move(to: origin) }
    let x = display.midX
    for _ in 0..<12 {
        move(to: CGPoint(x: x, y: display.minY + 150))
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard visible() == false else {
        print("Cannot establish that the system menu bar is hidden before hovering.")
        return false
    }
    var revealed = false
    for _ in 0..<30 {
        move(to: CGPoint(x: x, y: display.minY))
        Thread.sleep(forTimeInterval: 0.1)
        guard let shown = visible() else { return false }
        revealed = revealed || shown
    }
    print("Menu bar appeared during hover:", revealed)
    return revealed == expectVisible
}

guard let mode = CommandLine.arguments.last, ["hidden", "visible"].contains(mode) else { exit(2) }
exit(run(expectVisible: mode == "visible") ? 0 : 1)
