import AppKit
import IOKit.ps

struct BatteryStatus: Equatable {
    let fraction: Double
    let onACPower: Bool

    static func current() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String:Any],
                  details[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let charge = details[kIOPSCurrentCapacityKey] as? Int,
                  let capacity = details[kIOPSMaxCapacityKey] as? Int, capacity > 0 else { continue }
            return BatteryStatus(fraction:min(1, max(0, Double(charge) / Double(capacity))),
                                 onACPower:details[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }

    var description: String {
        "\(Int((fraction * 100).rounded()))% · " + (onACPower ? "Питание от сети" : "Питание от аккумулятора")
    }

    var trayIcon: NSImage {
        let image = NSImage(size:NSSize(width:21, height:14), flipped:false) { _ in
            let body = NSRect(x:0.75, y:2, width:17.5, height:10)
            let outline = NSBezierPath(roundedRect:body, xRadius:2.4, yRadius:2.4)
            NSColor.black.withAlphaComponent(0.78).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            NSColor.black.setFill()
            NSBezierPath(roundedRect:NSRect(x:19.25, y:5, width:1.5, height:4), xRadius:0.7, yRadius:0.7).fill()

            let interior = body.insetBy(dx:1.5, dy:1.5)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect:interior, xRadius:1, yRadius:1).addClip()
            NSRect(x:interior.minX, y:interior.minY, width:interior.width * fraction, height:interior.height).fill()
            NSGraphicsContext.restoreGraphicsState()

            if onACPower {
                let bolt = NSBezierPath()
                let center = body.midX
                bolt.move(to:NSPoint(x:center + 1.8, y:11.7))
                bolt.line(to:NSPoint(x:center - 3.1, y:6.6))
                bolt.line(to:NSPoint(x:center - 0.5, y:6.6))
                bolt.line(to:NSPoint(x:center - 1.8, y:2.3))
                bolt.line(to:NSPoint(x:center + 3.1, y:7.6))
                bolt.line(to:NSPoint(x:center + 0.5, y:7.6))
                bolt.close()

                // Clear a halo in the template so the bolt stays legible over the charge fill.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
                bolt.lineJoinStyle = .round
                bolt.lineWidth = 1.6
                bolt.stroke()
                NSGraphicsContext.restoreGraphicsState()
                bolt.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
