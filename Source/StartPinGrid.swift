import SwiftUI

struct StartPinGrid: NSViewRepresentable {
    let pins: [StartPin]
    let open: (StartPin, CGRect) -> Void
    let unpin: (Item) -> Void
    let extract: ((Item) -> Void)?
    let dissolve: (String) -> Void
    let group: ((String, String) -> Void)?
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

        private var candidate: String?
        private var readyTarget: String?
        private var dwell: Timer?

        private func clearTarget() {
            dwell?.invalidate()
            dwell = nil
            if let readyTarget { buttons[readyTarget]?.selected = false; buttons[readyTarget]?.tint() }
            if let moving { buttons[moving]?.lift?.setDropHighlight(false) }
            candidate = nil
            readyTarget = nil
        }

        func update(_ model: StartPinGrid) {
            let changed = self.model?.pins != model.pins
            self.model = model
            guard changed else { return }
            clearTarget()
            moving = nil
            order = model.pins.map(\.key)
            for key in buttons.keys where !order.contains(key) {
                buttons.removeValue(forKey: key)?.removeFromSuperview()
            }
            for item in model.pins where buttons[item.key]?.item != item {
                buttons[item.key]?.removeFromSuperview()
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
            guard let model, let source = model.pins.firstIndex(where: { $0.key == key }) else { return }
            moving = key
            guard visibleRect.contains(point) else { clearTarget(); return }
            let columns = StartPinGrid.columns(bounds.width)
            let pitch = (bounds.width + gap) / CGFloat(columns)
            let column = min(columns - 1, Int(point.x / pitch))
            let row = Int(point.y / (side + gap))
            let slot = row * columns + column
            let target = min(model.pins.count - 1, slot)
            let iconCenter = CGPoint(x: CGFloat(column) * pitch + (pitch - gap) / 2,
                                     y: CGFloat(row) * (side + gap) + 21)
            let overIcon = abs(point.x - iconCenter.x) <= 21 && abs(point.y - iconCenter.y) <= 20
            let original = model.pins.map(\.key)
            if model.group != nil, case .app = model.pins[source], source != slot,
               slot < original.count, overIcon {
                let destination = original[slot]
                // The destination stays in its original slot while the pointer rests on its icon.
                if candidate != destination {
                    clearTarget()
                    candidate = destination
                    order = original
                    place(animated: true)
                    let timer = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
                        guard let self, self.candidate == destination else { return }
                        self.readyTarget = destination
                        self.buttons[destination]?.selected = true
                        self.buttons[destination]?.tint()
                        self.buttons[key]?.lift?.setDropHighlight(true)
                    }
                    dwell = timer
                    RunLoop.main.add(timer, forMode: .common)
                }
                return
            }
            clearTarget()
            var reordered = original
            reordered.insert(reordered.remove(at: source), at: target)
            if reordered != order { order = reordered; place(animated: true) }
        }

        fileprivate func finish(_ key: String, at point: CGPoint) -> Bool {
            guard moving == key, let model else { return false }
            drag(key, at: point)
            let groupTarget = readyTarget
            let moveTarget = candidate.flatMap { target in model.pins.firstIndex { $0.key == target } }
                ?? order.firstIndex(of: key)
            clearTarget()
            moving = nil
            if visibleRect.contains(point), let groupTarget {
                model.group?(key, groupTarget)
                return true
            } else if visibleRect.contains(point), let moveTarget {
                model.move(key, moveTarget)
            } else {
                order = model.pins.map(\.key)
                place(animated: true)
            }
            return false
        }
    }

    private final class PinButton: ShelfButton {
        let item: StartPin
        private let icon: NSImageView
        weak var grid: Grid?
        private var down: NSPoint?
        fileprivate var lift: DragImage?

        init(_ item: StartPin, grid: Grid) {
            icon = NSImageView(image: Self.icon(for: item))
            self.item = item
            self.grid = grid
            super.init(frame: .zero)
            title = ""
            isBordered = false
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
        private static func icon(for pin: StartPin) -> NSImage {
            if case .app(let item) = pin { return NSWorkspace.shared.icon(forFile: item.path) }
            let images = pin.items.prefix(4).map { NSWorkspace.shared.icon(forFile: $0.path) }
            return NSImage(size: NSSize(width: 32, height: 32), flipped: false) { bounds in
                NSColor.controlAccentColor.withAlphaComponent(0.24).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
                for (i, image) in images.enumerated() {
                    let rect = NSRect(x: 3 + (i % 2) * 14, y: 16 - (i / 2) * 14, width: 13, height: 13)
                    image.draw(in: rect)
                }
                return true
            }
        }

        @objc private func openPin() {
            guard let grid else { return }
            grid.model?.open(item, icon.convert(icon.bounds, to: grid))
        }
        @objc private func unpin() {
            if case .app(let app) = item { grid?.model?.unpin(app) }
        }
        @objc private func extract() {
            if case .app(let app) = item { grid?.model?.extract?(app) }
        }
        @objc private func groupWith(_ sender: NSMenuItem) {
            if let target = sender.representedObject as? String { grid?.model?.group?(item.key, target) }
        }
        @objc private func dissolve() { grid?.model?.dissolve(item.key) }
        override func menu(for event: NSEvent) -> NSMenu? {
            guard let model = grid?.model else { return nil }
            let menu = NSMenu()
            switch item {
            case .folder:
                menu.addItem(withTitle: "Открыть папку", action: #selector(openPin), keyEquivalent: "").target = self
                menu.addItem(withTitle: "Расформировать папку", action: #selector(dissolve), keyEquivalent: "").target = self
            case .app:
                if model.extract != nil {
                    menu.addItem(withTitle: "Вынести из папки", action: #selector(extract), keyEquivalent: "").target = self
                } else if model.group != nil, model.pins.count > 1 {
                    let options = NSMenu()
                    for other in model.pins where other.key != item.key {
                        let option = options.addItem(withTitle: other.name, action: #selector(groupWith(_:)), keyEquivalent: "")
                        option.target = self
                        option.representedObject = other.key
                    }
                    menu.addItem(withTitle: "Объединить в папку с", action: nil, keyEquivalent: "").submenu = options
                }
                menu.addItem(withTitle: "Открепить", action: #selector(unpin), keyEquivalent: "").target = self
            }
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
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    lift = DragImage(source: self, down: down, backgroundColor: .windowBackgroundColor.withAlphaComponent(1))
                }
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
                if grid.finish(item.key, at: grid.convert(event.locationInWindow, from: nil)) { lift.cancel() }
                else { lift.finish() }
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
