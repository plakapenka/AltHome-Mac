import AppKit

struct ShelfSizing: Equatable {
    static let iconPreference = "largeShelfIcons"
    static let heightPreference = "compactShelfHeight"
    let largeIcons: Bool
    let compactHeight: Bool

    var height: CGFloat { compactHeight ? 36 : 50 }
    var tileInset: CGFloat { compactHeight ? 1 : 3 }
    var tileHeight: CGFloat { height - 2 * tileInset }
    var iconSize: CGFloat { largeIcons ? 30 : 20 }
    var pinWidth: CGFloat { largeIcons ? 48 : 36 }
    var captionX: CGFloat { largeIcons ? 44 : 32 }
    var trayWidth: CGFloat { largeIcons ? 32 : 28 }
    var controlHeight: CGFloat { compactHeight ? 30 : 36 }
    var controlY: CGFloat { (height - controlHeight) / 2 }
}

enum ShelfEdge: String {
    case bottom, top

    func shelfFrame(on screen: NSScreen, height: CGFloat) -> CGRect {
        let visible = screen.visibleFrame
        let top = min(visible.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        return CGRect(x: visible.minX, y: self == .top ? top - height : screen.frame.minY,
                      width: visible.width, height: height)
    }

    func availableFrame(in visible: CGRect, beside shelf: CGRect, inset: CGFloat = 0) -> CGRect {
        let low = self == .bottom ? max(visible.minY, shelf.maxY + inset) : visible.minY
        let high = self == .top ? min(visible.maxY, shelf.minY - inset) : visible.maxY
        return CGRect(x: visible.minX, y: low, width: visible.width, height: max(0, high - low))
    }

    func popupY(beside anchor: CGRect, height: CGFloat, gap: CGFloat = 6) -> CGFloat {
        self == .top ? anchor.minY - gap - height : anchor.maxY + gap
    }

    func menuTop(beside anchor: CGRect, height: CGFloat, visible: CGRect) -> CGFloat {
        let top = popupY(beside: anchor, height: height) + height
        return min(visible.maxY - 4, max(visible.minY + height + 4, top))
    }
}
