// swiftc Source/WiFiStatus.swift Tests/WiFiStatusTests.swift -o /tmp/check-wifi
import AppKit
import CoreWLAN

private final class TestInterface: CWInterface, @unchecked Sendable {
    var powered = true
    var rssi = 0
    var rate = 0.0
    override func powerOn() -> Bool { powered }
    override func rssiValue() -> Int { rssi }
    override func transmitRate() -> Double { rate }
}

@main
struct WiFiStatusTests {
    static func main() {
        let device = TestInterface()
        precondition(WiFiStatus.current(nil) == .off)
        precondition(WiFiStatus.current(device) == .disconnected)
        for (rssi, signal): (Int, WiFiStatus.Signal) in [(-84, .weak), (-75, .fair), (-61, .fair), (-60, .strong)] {
            device.rssi = rssi
            precondition(WiFiStatus.current(device) == .connected(signal))
        }
        device.rssi = 0
        device.rate = 150
        precondition(WiFiStatus.current(device) == .connected(.unknown))
        device.rssi = -127
        device.rate = 0
        precondition(WiFiStatus.current(device) == .disconnected)
        device.rssi = -50
        device.powered = false
        precondition(WiFiStatus.current(device) == .off)

        // Compare the rendered pixels, including the unlit arcs of the variable Wi-Fi symbol.
        let states: [WiFiStatus] = [.off, .disconnected, .connected(.unknown), .connected(.weak), .connected(.fair), .connected(.strong)]
        let pixels = states.map { status -> Data in
            let rep = NSBitmapImageRep(data: status.trayIcon!.tiffRepresentation!)!
            return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
        }
        precondition(Set(pixels).count == states.count)
        print("PASS: distinct Wi-Fi states and rendered signal levels")
    }
}
