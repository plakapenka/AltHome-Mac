import AppKit

extension Tray {
    // NSMenu takes the top-left corner when no item is selected for positioning.
    func popUp(_ menu: NSMenu, above button: NSButton) {
        guard let window = button.window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds,to:nil))
        let visible = screen.visibleFrame
        let size = menu.size
        let x = max(visible.minX+4,min(anchor.midX-size.width/2,visible.maxX-size.width-4))
        let top = owner.bar.edge.menuTop(beside: window.frame, height: size.height, visible: visible)
        menu.popUp(positioning:nil,at:NSPoint(x:x,y:top),in:nil)
    }
}
