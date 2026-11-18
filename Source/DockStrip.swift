import AppKit
import Combine
import QuartzCore

private final class DockIconButton: NSButton {
    var entry: DockEntry
    weak var strip: DockStrip?
    private let artwork = CALayer()
    private let dot = CALayer()
    private var down: NSPoint?
    private var lift: DragImage?
    private let original: NSImage

    init(_ entry: DockEntry) {
        self.entry = entry
        original = entry.icon
        super.init(frame: .zero)
        wantsLayer = true
        isBordered = false
        title = ""
        target = self
        action = #selector(activate)
        var rect = NSRect(x: 0, y: 0, width: 512, height: 512)
        artwork.contents = original.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        artwork.contentsGravity = .resizeAspect
        artwork.minificationFilter = .trilinear
        layer?.addSublayer(artwork)
        layer?.addSublayer(dot)
        dot.cornerRadius = 1.75
        dot.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        update(entry)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ value: DockEntry) {
        entry = value
        toolTip = value.title
        setAccessibilityLabel(value.title)
        dot.isHidden = !value.running
    }
    override func layout() {
        super.layout()
        let side = bounds.width - 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artwork.frame = NSRect(x: 1, y: isFlipped ? 4 : 10, width: side, height: side)
        dot.frame = NSRect(x: bounds.midX - 1.75, y: isFlipped ? bounds.height - 7.5 : 4, width: 3.5, height: 3.5)
        CATransaction.commit()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func activate() { strip?.open(entry) }
    override func mouseDown(with event: NSEvent) {
        lift?.cancel()
        lift = nil
        down = window?.convertPoint(toScreen: event.locationInWindow)
        strip?.pressedKey = entry.key
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down, let window, let strip else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        if lift == nil {
            guard hypot(point.x - down.x, point.y - down.y) >= 5 else { return }
            // Layer-backed artwork is already cached. Draw the same pixels in the lifted tile.
            let icon = original, size = bounds.size, running = entry.running
            let image = NSImage(size: size, flipped: false) { _ in
                icon.draw(in: NSRect(x: 1, y: 10, width: size.width - 2, height: size.width - 2))
                if running {
                    NSColor.white.withAlphaComponent(0.85).setFill()
                    NSBezierPath(ovalIn: NSRect(x: size.width / 2 - 1.75, y: 4, width: 3.5, height: 3.5)).fill()
                }
                return true
            }
            lift = DragImage(source: self, down: down, image: image)
            guard lift != nil else { return }
            strip.beginDrag(entry.key)
        }
        lift?.follow(point)
        _ = superview?.autoscroll(with: event)
        strip.drag(entry.key, event.locationInWindow)
    }
    override func mouseUp(with event: NSEvent) {
        guard down != nil else { return }
        down = nil
        strip?.pressedKey = nil
        if let lift {
            lift.finish()
            strip?.endDrag()
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) { activate() }
    }
    func resetDrag() {
        lift?.cancel()
        lift = nil
        down = nil
    }
}

final class DockStrip: NSView {
    let open: (DockEntry) -> Void
    var resized: ((NSSize) -> Void)?
    private let mirror: DockMirror
    private let available: CGFloat
    private let defaults: UserDefaults
    private let plate: NSView
    private let scroll = NSScrollView()
    private let document = NSView()
    private var entries: [DockEntry] = []
    private var views: [String: NSView] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var side: CGFloat = 45, zoom: CGFloat = 1.55
    fileprivate var pressedKey: String?
    private var hoverRegion = NSRect.zero
    private var naturalWidth: CGFloat = 0, strength: CGFloat = 0, focus: CGFloat = 0
    private var lastTick = CACurrentMediaTime()
    private var sizes: [String: CGFloat] = [:]
    private var stopClock: (() -> Void)?
    private var canvas = NSSize.zero
    override var fittingSize: NSSize { canvas }
    var restingHeight: CGFloat { side + 14 }

    init(mirror: DockMirror, defaults: UserDefaults, available: CGFloat, open: @escaping (DockEntry) -> Void) {
        self.mirror = mirror
        self.defaults = defaults
        self.available = available
        self.open = open
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 18
            plate = glass
        } else {
            let blur = NSVisualEffectView()
            blur.blendingMode = .behindWindow
            blur.material = .popover
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = 18
            blur.layer?.masksToBounds = true
            plate = blur
        }
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(plate)
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        addSubview(scroll)
        mirror.$entries.sink { [weak self] in self?.update($0) }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.configure() }.store(in: &subscriptions)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func update(_ next: [DockEntry]) {
        let keys = Set(next.map(\.key))
        for key in Array(views.keys) where !keys.contains(key) {
            if let button = views[key] as? DockIconButton {
                button.resetDrag()
                if pressedKey == key { pressedKey = nil }
                if dragKey == key { endDrag() }
            }
            sizes.removeValue(forKey: key)
            views.removeValue(forKey: key)?.removeFromSuperview()
        }
        for entry in next {
            if let button = views[entry.key] as? DockIconButton { button.update(entry); continue }
            guard views[entry.key] == nil else { continue }
            let view: NSView
            if entry.role == "AXSeparatorDockItem" {
                view = NSView()
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
            } else {
                let button = DockIconButton(entry)
                button.strip = self
                view = button
            }
            document.addSubview(view)
            views[entry.key] = view
        }
        entries = next
        configure(force: true)
    }

    private func configure(force: Bool = false) {
        let count = entries.filter { $0.role != "AXSeparatorDockItem" }.count
        let margins = CGFloat(16 + (entries.count - count) * 12)
        let size = defaults.object(forKey: "dockIconSize") as? Double ?? DockSizing.systemSize
        let newSide = min(max(16, min(128, size)), max(16, floor((available - margins) / CGFloat(max(count, 1))) - 2))
        let magnifies = defaults.object(forKey: "dockMagnifies") as? Bool ?? true
        let newZoom = magnifies ? min(2, max(1, defaults.object(forKey: "dockZoom") as? Double ?? 1.55)) : 1
        guard force || newSide != side || newZoom != zoom else { return }
        side = newSide
        zoom = newZoom
        naturalWidth = margins + CGFloat(count) * (side + 2)
        // Reserve space for the lens once. The window and its shadow stay stationary during mouse movement.
        let newCanvas = NSSize(width: min(available, ceil(naturalWidth + 3 * side * (zoom - 1))),
                               height: ceil(side * zoom) + 14)
        if newCanvas != canvas {
            canvas = newCanvas
            resized?(canvas)
        }
        place(animateNeighbors: mirror.dragging)
    }

    func startClock() {
        stop()
        if #available(macOS 14, *) {
            let link = displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            stopClock = { link.invalidate() }
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            stopClock = { timer.invalidate() }
        }
        lastTick = CACurrentMediaTime()
    }
    func stop() {
        stopClock?()
        stopClock = nil
        if let dragKey {
            (views[dragKey] as? DockIconButton)?.resetDrag()
            endDrag()
        }
    }
    override func viewWillMove(toWindow window: NSWindow?) {
        if window == nil { stop() }
        super.viewWillMove(toWindow: window)
    }
    @objc private func tick() {
        guard let window, window.isVisible else { stop(); return }
        let now = CACurrentMediaTime(), dt = min(0.08, now - lastTick)
        lastTick = now
        guard pressedKey == nil, !mirror.dragging, zoom > 1 else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let inside = hoverRegion.contains(point)
        let target: CGFloat = inside ? 1 : 0
        if !inside && strength == 0 { return }
        let local = document.convert(point, from: self)
        let aim = max(side / 2 + 8, min(naturalWidth - side / 2 - 8, naturalWidth / 2 + local.x - document.bounds.midX))
        let oldStrength = strength, oldFocus = focus
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if inside {
            focus = (strength == 0 || reduce) ? aim : focus + (aim - focus) * (1 - exp(-dt / 0.022))
            if abs(focus - aim) < 0.1 { focus = aim }
        }
        strength += (target - strength) * (reduce ? 1 : 1 - exp(-dt / 0.055))
        if abs(target - strength) < 0.002 { strength = target }
        if oldStrength != strength || oldFocus != focus { place(animateNeighbors: false) }
    }

    private func place(animateNeighbors: Bool) {
        var base: CGFloat = 8, contentWidth: CGFloat = 16, height = restingHeight
        for entry in entries {
            if entry.role == "AXSeparatorDockItem" {
                contentWidth += 12
                base += 12
                continue
            }
            if !mirror.dragging || sizes[entry.key] == nil {
                let distance = min(1, abs(base + (side + 2) / 2 - focus) / (2 * (side + 2)))
                sizes[entry.key] = side * (1 + strength * (zoom - 1) * (1 + cos(.pi * distance)) / 2)
            }
            let size = sizes[entry.key] ?? side
            height = max(height, size + 14)
            contentWidth += size + 2
            base += side + 2
        }
        // Keep the scroll viewport fixed too. Only the icons and glass plate move within it.
        let documentWidth = max(canvas.width, ceil(contentWidth))
        var leading = 8 + (documentWidth - contentWidth) / 2
        let width = min(available, contentWidth)
        let x = (canvas.width - width) / 2
        hoverRegion = NSRect(x: x, y: 0, width: width, height: height)
        let plateFrame = NSRect(x: x, y: 0, width: width, height: restingHeight)
        if plate.frame != plateFrame { plate.frame = plateFrame }
        let viewport = NSRect(origin: .zero, size: canvas)
        if scroll.frame != viewport { scroll.frame = viewport }
        let documentSize = NSSize(width: documentWidth, height: canvas.height)
        if document.frame.size != documentSize { document.setFrameSize(documentSize) }
        for entry in entries {
            guard let view = views[entry.key] else { continue }
            let separator = entry.role == "AXSeparatorDockItem"
            let size = sizes[entry.key] ?? side
            let width = separator ? 12 : size + 2
            let rect = separator ? NSRect(x: leading + 5.5, y: 7, width: 1, height: side * 0.76)
                                 : NSRect(x: leading, y: 0, width: width, height: size + 14)
            let previous = view.frame
            if previous != rect {
                let layer = view.layer
                let visualX = previous.minX + (layer?.presentation()?.position.x ?? layer?.position.x ?? 0) - (layer?.position.x ?? 0)
                view.frame = rect
                if animateNeighbors, entry.key != dragKey, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let slide = CABasicAnimation(keyPath: "position.x")
                    slide.isAdditive = true
                    slide.fromValue = visualX - rect.minX
                    slide.toValue = 0
                    slide.duration = 0.17
                    slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer?.add(slide, forKey: "dockShift")
                }
            }
            leading += width
        }
    }

    private var dragKey: String?
    func beginDrag(_ key: String) { dragKey = key; mirror.dragging = true }
    func drag(_ key: String, _ location: NSPoint) {
        guard let source = entries.firstIndex(where: { $0.key == key }) else { return }
        let point = document.convert(location, from: nil)
        let centers = entries.map { views[$0.key]?.frame.midX ?? 0 }
        let target = dragDestination(from: source, centers: centers, x: point.x)
        if target != source { mirror.move(key, to: target) }
    }
    func endDrag() { dragKey = nil; mirror.dragging = false }
}
