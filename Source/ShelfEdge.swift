import AppKit

struct ShelfSizing: Equatable {
    static let preference = "largeShelfIcons"
    let compact: Bool

    var height: CGFloat { compact ? 36 : 50 }
    var tileHeight: CGFloat { height - 6 }
    var iconSize: CGFloat { compact ? 20 : 30 }
    var pinWidth: CGFloat { compact ? 36 : 48 }
    var captionX: CGFloat { compact ? 32 : 44 }
    var trayWidth: CGFloat { compact ? 28 : 32 }
    var controlHeight: CGFloat { compact ? 30 : 36 }
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
