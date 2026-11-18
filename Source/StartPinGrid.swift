import SwiftUI

struct StartPinGrid: NSViewRepresentable {
    let pins: [Item]
    let launch: (Item) -> Void
    let unpin: (Item) -> Void
    let move: (String, Int) -> Void

    private static let side: CGFloat = 72
    private static let gap: CGFloat = 4
    fileprivate static func columns(_ width: CGFloat) -> Int {
        max(1, Int((width + gap) / (side + gap)))
    }
    static func height(count: Int, width: CGFloat) -> CGFloat {
        let columns = columns(width)
        let rows = (count + columns - 1) / columns
        return max(0, CGFloat(rows) * (side + gap) - gap)
    }

    func makeNSView(context: Context) -> Grid { Grid() }
    func updateNSView(_ grid: Grid, context: Context) { grid.update(self) }

    final class Grid: NSView {
        override var isFlipped: Bool { true }
        fileprivate var model: StartPinGrid?
        private var buttons: [String: PinButton] = [:]
        private var order: [String] = []
        private var moving: String?

        func update(_ model: StartPinGrid) {
            let changed = self.model?.pins != model.pins
            self.model = model
            guard changed else { return }
            moving = nil
            order = model.pins.map(\.key)
            for key in buttons.keys where !order.contains(key) {
                buttons.removeValue(forKey: key)?.removeFromSuperview()
            }
            for item in model.pins where buttons[item.key] == nil {
                let button = PinButton(item, grid: self)
                buttons[item.key] = button
                addSubview(button)
            }
            needsLayout = true
        }

        override func layout() {
            super.layout()
            place(animated: false)
        }

        private func place(animated: Bool) {
            let columns = StartPinGrid.columns(bounds.width)
            let pitch = (bounds.width + gap) / CGFloat(columns)
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = 0.18
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for (i, key) in order.enumerated() {
                    guard let button = buttons[key] else { continue }
                    let frame = NSRect(x: CGFloat(i % columns) * pitch, y: CGFloat(i / columns) * (side + gap),
                                       width: max(0, pitch - gap), height: side)
                    guard button.frame != frame else { continue }
                    if animated && key != moving && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        button.animator().frame = frame
                    } else {
                        button.frame = frame
                    }
                }
            }
        }

        fileprivate func drag(_ key: String, at point: CGPoint) {
            guard let source = order.firstIndex(of: key) else { return }
            moving = key
            guard bounds.contains(point) else { return }
            let columns = StartPinGrid.columns(bounds.width)
            let col = min(columns - 1, Int(point.x / ((bounds.width + gap) / CGFloat(columns))))
            let row = Int(point.y / (side + gap))
            let target = min(order.count - 1, row * columns + col)
            guard source != target else { return }
            order.remove(at: source)
            order.insert(key, at: target)
            place(animated: true)
        }

        fileprivate func finish(_ key: String, at point: CGPoint) {
            guard moving == key else { return }
            if visibleRect.contains(point), let index = order.firstIndex(of: key) {
                model?.move(key, index)
            } else {
                order = model?.pins.map(\.key) ?? []
                place(animated: true)
            }
            moving = nil
        }
    }

    private final class PinButton: ShelfButton {
        let item: Item
        weak var grid: Grid?
        private var down: NSPoint?
        private var lift: DragImage?

        init(_ item: Item, grid: Grid) {
            self.item = item
            self.grid = grid
            super.init(frame: .zero)
            title = ""
            isBordered = false
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: item.path))
            icon.imageScaling = .scaleProportionallyUpOrDown
            let caption = NSTextField(wrappingLabelWithString: item.name)
            caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            caption.maximumNumberOfLines = 2
            caption.lineBreakMode = .byTruncatingTail
            caption.alignment = .center
            for view in [icon, caption] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                icon.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                icon.centerXAnchor.constraint(equalTo: centerXAnchor),
                icon.widthAnchor.constraint(equalToConstant: 32), icon.heightAnchor.constraint(equalToConstant: 32),
                caption.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 5),
                caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
                caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3)
            ])
            toolTip = item.name
            setAccessibilityLabel(item.name)
            target = self
            action = #selector(openPin)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
        @objc private func openPin() { grid?.model?.launch(item) }
        @objc private func unpin() { grid?.model?.unpin(item) }
        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            menu.addItem(withTitle: "Открепить", action: #selector(unpin), keyEquivalent: "").target = self
            return menu
        }
        override func mouseDown(with event: NSEvent) {
            lift?.cancel()
            lift = nil
            down = window?.convertPoint(toScreen: event.locationInWindow)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let down, let window, let grid else { return }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            if lift == nil {
                guard hypot(point.x - down.x, point.y - down.y) >= 5 else { return }
                lift = DragImage(source: self, down: down)
            }
            guard let lift else { return }
            lift.follow(point)
            _ = grid.autoscroll(with: event)
            grid.drag(item.key, at: grid.convert(event.locationInWindow, from: nil))
        }
        override func mouseUp(with event: NSEvent) {
            guard down != nil else { return }
            down = nil
            if let lift, let grid {
                grid.finish(item.key, at: grid.convert(event.locationInWindow, from: nil))
                lift.finish()
            } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
                openPin()
            }
        }
        override func viewWillMove(toWindow window: NSWindow?) {
            if window == nil { lift?.cancel(); lift = nil; down = nil }
            super.viewWillMove(toWindow: window)
        }
    }
}
