// swiftc Source/LayoutShortcut.swift Tests/LayoutChord.swift -o /tmp/check-layout-chord
import AppKit

@main
struct LayoutChordTests {
    static func main() {
        typealias Event = (CGEventType, CGEventFlags)
        let command: Event = (.flagsChanged, .maskCommand)
        let shift: Event = (.flagsChanged, .maskShift)
        let both: Event = (.flagsChanged, [.maskCommand, .maskShift])
        let released: Event = (.flagsChanged, [])
        func verify(_ events: [Event], switches: [Int]) {
            var chord = LayoutChord()
            let actual = events.indices.filter { chord.handle(events[$0].0, flags: events[$0].1) }
            precondition(actual == switches)
        }
        verify([command, both, shift, released, shift, both, command, released], switches: [3,7])
        verify([command, released, shift, released], switches: [])
        for type: CGEventType in [.keyDown, .leftMouseDown, .scrollWheel] {
            verify([command, both, (type, both.1), shift, released], switches: [])
        }
        verify([shift, (.keyDown, shift.1), both, command, released], switches: [])
        verify([command, both, (.flagsChanged, [.maskControl, .maskCommand, .maskShift]), both, shift, released], switches: [])
        verify([command, both, (.keyDown, both.1), shift, released, command, both, command, released], switches: [8])
        print("PASS modifier order, release, ordinary shortcuts, extra modifiers and pointer gestures")
    }
}
