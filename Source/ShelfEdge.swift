import AppKit

enum ShelfEdge: String {
    case bottom, top

    func shelfFrame(on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let top = min(visible.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        return CGRect(x: visible.minX, y: self == .top ? top - 50 : screen.frame.minY,
                      width: visible.width, height: 50)
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
