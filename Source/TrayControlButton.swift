import AppKit

/// Only the glyph rotates, keeping the hover outline and click target stationary.
final class TrayControlButton: ShelfButton {
    private let chevron = CALayer()
    private var expanded = false

    private var symbolName: String?

    func setDisclosureVisible(_ visible: Bool, symbol: String) {
        guard visible else {
            if chevron.superlayer != nil {
                setExpanded(false, animated: false)
                chevron.removeFromSuperlayer()
            }
            return
        }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard chevron.superlayer == nil || symbolName != symbol || chevron.position != center, let layer else { return }
        symbolName = symbol
        let scale = window?.backingScaleFactor ?? 2
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        chevron.bounds = CGRect(origin: .zero, size: glyph.size)
        chevron.position = center
        chevron.contentsScale = scale
        chevron.contents = glyph.layerContents(forContentsScale: scale)
        layer.addSublayer(chevron)
    }

    func setExpanded(_ value: Bool, animated: Bool = true) {
        setAccessibilityExpanded(value)
        guard value != expanded else { return }
        expanded = value
        let end = value ? CGFloat.pi : 0
        let key = "transform.rotation.z"
        let start = (chevron.presentation() ?? chevron).value(forKeyPath: key) as? CGFloat ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.setValue(end, forKeyPath: key)
        chevron.removeAnimation(forKey: key)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let turn = CABasicAnimation(keyPath: key)
            turn.fromValue = start < -CGFloat.pi + 0.001 ? CGFloat.pi : start
            turn.toValue = end
            turn.duration = 0.18
            turn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            chevron.add(turn, forKey: key)
        }
        CATransaction.commit()
    }
}
