import AppKit
import ApplicationServices

// AppKit reports window frames from the bottom left. Accessibility uses the top left.
func accessibilityFrame(_ frame: CGRect, primary: NSScreen) -> CGRect {
    CGRect(x:frame.minX, y:primary.frame.maxY-frame.maxY, width:frame.width, height:frame.height)
}

func nearlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX-b.minX) < 2 && abs(a.minY-b.minY) < 2 &&
    abs(a.width-b.width) < 2 && abs(a.height-b.height) < 2
}

// Match the result of a native zoom, including vertical-only zoom and macOS tiling margins.
func shelfLimitedZoom(_ frame: CGRect, visible: CGRect, usable: CGRect) -> CGRect? {
    if usable.minY > visible.minY {
        // Reflect AX coordinates so both placements share the native zoom/margin rules.
        func reflected(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: -r.maxY, width: r.width, height: r.height)
        }
        return limitBottomOfZoom(reflected(frame), visible: reflected(visible), usable: reflected(usable)).map(reflected)
    }
    return limitBottomOfZoom(frame, visible: visible, usable: usable)
}

private func limitBottomOfZoom(_ frame: CGRect, visible: CGRect, usable: CGRect) -> CGRect? {
    guard usable.maxY < visible.maxY, abs(frame.minY - visible.minY) <= 24,
          frame.intersects(usable), frame.minY < usable.maxY else { return nil }
    let coversShelf = frame.maxY >= visible.maxY - 24 && frame.maxY > usable.maxY
    // Earlier versions left two points under a maximized window.
    let gap = usable.maxY - frame.maxY
    let oldInset = gap > 0 && gap <= 2 && abs(frame.minX - usable.minX) < 2 && abs(frame.width - usable.width) < 2
    guard coversShelf || oldInset else { return nil }
    return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: usable.maxY - frame.minY)
}

struct TitleBarClick {
    let window: AXUIElement
    let app: NSRunningApplication
    let point: CGPoint
    let frame: CGRect
}

// A custom title bar can finish zooming before the second click's AX query returns.
struct FirstTitleClick {
    let point: CGPoint
    let pid: pid_t
    let number: CGWindowID
    let frame: CGRect

    init?(at point: CGPoint) {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] else { return nil }
        for window in windows where window[kCGWindowLayer as String] as? Int == 0 {
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point) else { continue }
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  let id = window[kCGWindowNumber as String] as? CGWindowID else { return nil }
            self.point = point
            pid = owner
            number = id
            frame = rect
            return
        }
        return nil
    }
}

struct ChatTitleDrag {
    let click: TitleBarClick
    let started: TimeInterval
    var moving = false
    var lastWrite: TimeInterval = 0
}

extension Delegate {
    func usableFrame(on screen: NSScreen) -> CGRect {
        guard screen.frame.intersects(bar.frame) else { return screen.visibleFrame }
        return bar.edge.availableFrame(in: screen.visibleFrame, beside: bar.frame, inset: tray.pinnedDockInset)
    }

    func refitWindows(from previous: CGRect, on screen: NSScreen) {
        guard !CommandLine.arguments.contains("--ui-check"), AXIsProcessTrusted(), let primary = NSScreen.screens.first else { return }
        let old = accessibilityFrame(previous, primary: primary)
        let new = accessibilityFrame(usableFrame(on: screen), primary: primary)
        for entry in snapshots.values.joined() {
            guard !entry.fullScreen, !minimized(entry.window), let frame = windowRect(entry.window),
                  old.contains(CGPoint(x: frame.midX, y: frame.midY)),
                  abs(frame.minY - old.minY) < 2, abs(frame.maxY - old.maxY) < 2 else { continue }
            let target = CGRect(x: frame.minX, y: new.minY, width: frame.width, height: new.height)
            if writeFrame(target, to: entry.window),
               let i = expanded.firstIndex(where: { CFEqual(entry.window, $0.1) }) {
                expanded[i].3 = windowRect(entry.window) ?? target
            }
        }
        scheduleMaximizedWindowFit()
    }

    // Space transitions and reopened maximized windows can arrive without a double-click.
    func scheduleMaximizedWindowFit() {
        maximizedWindowCheck?.cancel()
        guard !CommandLine.arguments.contains("--ui-check"), AXIsProcessTrusted(),
              let app = ws.frontmostApplication, app.activationPolicy == .regular else { return }
        let check = DispatchWorkItem { [weak self] in
            guard let self, app.isActive, NSEvent.pressedMouseButtons == 0,
                  let primary = NSScreen.screens.first, let screen = self.bar.screen else { return }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.15)
            guard let window = element(root, kAXFocusedWindowAttribute),
                  !minimized(window), !self.exitingFullScreen.contains(window),
                  let frame = windowRect(window),
                  accessibilityFrame(screen.frame, primary: primary).contains(CGPoint(x: frame.midX, y: frame.midY)) else { return }
            if attr(window, "AXFullScreen") as? Bool == true {
                // A full-screen window can exclude the camera housing at the top.
                // Leave side-by-side Split View windows in their shared Space.
                let display = accessibilityFrame(screen.frame, primary: primary)
                let usable = accessibilityFrame(self.usableFrame(on: screen), primary: primary)
                if abs(frame.minX - display.minX) < 2, abs(frame.width - display.width) < 2,
                   frame.maxY > usable.maxY || frame.minY < usable.minY {
                    self.fitAfterFullScreen(window, app: app, on: screen)
                }
                return
            }
            guard let fitted = shelfLimitedZoom(frame, visible: accessibilityFrame(screen.visibleFrame, primary: primary),
                                                usable: accessibilityFrame(self.usableFrame(on: screen), primary: primary)) else { return }
            _ = self.applyFittedFrame(fitted, current: frame, to: window)
        }
        maximizedWindowCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: check)
    }

    private func fitAfterFullScreen(_ window: AXUIElement, app: NSRunningApplication, on screen: NSScreen) {
        guard exitingFullScreen.insert(window).inserted else { return }
        Task { @MainActor in
            defer { exitingFullScreen.remove(window) }
            let key = "AXFullScreen" as CFString
            let result = AXUIElementSetAttributeValue(window, key, kCFBooleanFalse)
            guard result == .success || result == .cannotComplete else { return }
            // AppKit restores the window in its desktop Space asynchronously. Use that
            // rectangle for the next toggle, never the screen-sized transition frame.
            try? await Task.sleep(nanoseconds: 450_000_000)
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.15)
            var last: CGRect?
            for attempt in 0..<18 {
                guard !app.isTerminated, bar.screen == screen else { return }
                let focused = app.isActive && element(root, kAXFocusedWindowAttribute) == window
                let full = attr(window, "AXFullScreen") as? Bool
                if attempt == 6, focused, full == true {
                    // Some apps acknowledge the first request during entry but discard it.
                    _ = AXUIElementSetAttributeValue(window, key, kCFBooleanFalse)
                }
                if focused, full == false, !minimized(window), let current = windowRect(window) {
                    if current == last {
                        toggleFittedFrame(window, app: app, current: current, on: screen, reportFailure: false)
                        return
                    }
                    last = current
                } else {
                    last = nil
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func applyFittedFrame(_ target: CGRect, current: CGRect, to window: AXUIElement) -> Bool {
        // Moving an already tiled window can restart the system zoom animation.
        if target.origin == current.origin { return resize(window, to: target.size) }
        return writeFrame(target, to: window)
    }

    private func resize(_ window: AXUIElement, to size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }

    func monitorTitleBarZoom() {
        guard zoomMonitor == nil, AXIsProcessTrusted() else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<Delegate>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.zoomCheck?.cancel()
                owner.snap.cancel()
                owner.firstTitleClick = nil
                owner.titleBarClick = nil
                owner.chatTitleDrag = nil
                if let tap = owner.zoomMonitor { CGEvent.tapEnable(tap:tap,enable:true) }
            } else {
                owner.handleTitleBarMouse(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,options:.listenOnly,
                                         eventsOfInterest:CGEventMask(mask),callback:callback,
                                         userInfo:Unmanaged.passUnretained(self).toOpaque()) else { return }
        zoomMonitor = tap
        CFRunLoopAddSource(CFRunLoopGetMain(),CFMachPortCreateRunLoopSource(nil,tap,0),.commonModes)
        CGEvent.tapEnable(tap:tap,enable:true)
    }

    private func handleTitleBarMouse(_ type: CGEventType, _ event: CGEvent) {
        if type == .leftMouseDown {
            snap.mouseDown(at: event.location)
            zoomCheck?.cancel()
            titleBarClick = nil
            chatTitleDrag = nil
            guard event.flags.intersection([.maskCommand,.maskAlternate,.maskControl,.maskShift]).isEmpty else { return }
            let count = event.getIntegerValueField(.mouseEventClickState)
            if count == 1 {
                firstTitleClick = FirstTitleClick(at: event.location)
                if let firstTitleClick { snap.begin(firstTitleClick) }
            }
            if count == 1, let first = firstTitleClick, event.location.y - first.frame.minY < 36,
               let front = ws.frontmostApplication, front.processIdentifier == first.pid,
               front.bundleIdentifier == "com.openai.codex", let click = chatDragTarget(at:event.location) {
                chatTitleDrag = ChatTitleDrag(click:click,started:ProcessInfo.processInfo.systemUptime)
            }
            if count == 2 {
                maximizedWindowCheck?.cancel()
                if let first = firstTitleClick, hypot(event.location.x-first.point.x, event.location.y-first.point.y) <= 4 {
                    titleBarClick = first
                }
                firstTitleClick = nil
            }
        } else if chatTitleDrag != nil {
            updateChatDrag(at:event.location, ending:type == .leftMouseUp)
        } else if type == .leftMouseUp, let click = titleBarClick {
            titleBarClick = nil
            if hypot(event.location.x-click.point.x, event.location.y-click.point.y) <= 4 {
                resolveZoomWindow(click, attempt: 0)
            }
        }
        if type == .leftMouseDragged || type == .leftMouseUp {
            snap.track(event.location, ending: type == .leftMouseUp, owner: self)
        }
    }

    private func resolveZoomWindow(_ first: FirstTitleClick, attempt: Int) {
        // Query AX after releasing the mouse event: some toolkits can't answer during native zoom.
        let check = DispatchWorkItem { [weak self] in
            guard let self, let app = NSRunningApplication(processIdentifier: first.pid), !app.isTerminated else { return }
            let root = AXUIElementCreateApplication(first.pid)
            AXUIElementSetMessagingTimeout(root, 0.15)
            if app.isActive, let window = element(root, kAXFocusedWindowAttribute) {
                if let id = attr(window, "AXWindowNumber") as? CGWindowID, id != first.number { return }
                self.checkNativeZoom(TitleBarClick(window: window, app: app, point: first.point, frame: first.frame), attempt: 0)
            } else if attempt < 6 {
                self.resolveZoomWindow(first, attempt: attempt + 1)
            }
        }
        zoomCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.1), execute: check)
    }

    private func checkNativeZoom(_ click: TitleBarClick, attempt: Int, lastFrame: CGRect? = nil) {
        let check = DispatchWorkItem { [weak self] in
            guard let self, click.app.isActive, !click.app.isTerminated,
                  let primary = NSScreen.screens.first,
                  let screen = NSScreen.screens.first(where: { accessibilityFrame($0.frame, primary: primary).contains(click.point) }),
                  screen.frame.intersects(self.bar.frame),
                  !minimized(click.window),
                  attr(click.window, "AXFullScreen") as? Bool != true else { return }
            guard let frame = windowRect(click.window) else {
                if attempt < 12 { self.checkNativeZoom(click, attempt: attempt + 1) }
                return
            }
            let visible = accessibilityFrame(screen.visibleFrame, primary: primary)
            let usable = accessibilityFrame(self.usableFrame(on: screen), primary: primary)
            let previous = self.expanded.first { CFEqual($0.1, click.window) && nearlyEqual($0.3, click.frame) }
            if let previous, nearlyEqual(previous.2, frame) {
                self.expanded.removeAll { CFEqual($0.1, click.window) }
                return
            }
            // Writing an intermediate animation frame lets the app overwrite our adjustment.
            if frame == lastFrame, let fitted = shelfLimitedZoom(frame, visible: visible, usable: usable) {
                if !nearlyEqual(frame, click.frame) {
                    self.applyZoomBounds(previous?.2 ?? fitted, native: frame, click: click,
                                         restoring: previous != nil, retries: 4)
                    return
                }
                // A custom title bar may have already zoomed by the time AX reports the first frame.
                // There is no original size to save in that case.
                if attempt >= 3, click.point.y - frame.minY < 36 {
                    _ = self.applyFittedFrame(fitted, current: frame, to: click.window)
                    return
                }
            }
            if attempt < 12 { self.checkNativeZoom(click, attempt: attempt + 1, lastFrame: frame) }
        }
        zoomCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.035 : 0.1), execute: check)
    }

    private func applyZoomBounds(_ goal: CGRect, native: CGRect, click: TitleBarClick, restoring: Bool, retries: Int) {
        guard applyFittedFrame(goal, current: native, to: click.window) else { return }
        expanded.removeAll { CFEqual($0.1, click.window) }
        if !restoring { expanded.append((click.app.processIdentifier, click.window, click.frame, goal)) }
        guard retries > 0 else { return }
        let verify = DispatchWorkItem { [weak self] in
            guard let self, click.app.isActive, let actual = windowRect(click.window),
                  nearlyEqual(actual, native), attr(click.window, "AXFullScreen") as? Bool != true else { return }
            self.applyZoomBounds(goal, native: native, click: click, restoring: restoring, retries: retries - 1)
        }
        zoomCheck = verify
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: verify)
    }

    private func updateChatDrag(at point: CGPoint, ending: Bool) {
        guard var drag = chatTitleDrag else { return }
        defer { if chatTitleDrag != nil { chatTitleDrag = ending ? nil : drag } }
        let dx = point.x - drag.click.point.x, dy = point.y - drag.click.point.y
        let now = ProcessInfo.processInfo.systemUptime
        if !drag.moving {
            guard hypot(dx,dy) >= 6, ending || now-drag.started >= 0.09 else { return }
            guard let current = windowRect(drag.click.window), nearlyEqual(current,drag.click.frame) else {
                // AppKit already started its own drag.
                chatTitleDrag = nil
                return
            }
            drag.moving = true
        }
        guard ending || now-drag.lastWrite >= 1/60 else { return }
        var origin = CGPoint(x:drag.click.frame.minX+dx,y:drag.click.frame.minY+dy)
        if let value = AXValueCreate(.cgPoint,&origin) {
            _ = AXUIElementSetAttributeValue(drag.click.window,kAXPositionAttribute as CFString,value)
        }
        drag.lastWrite = now
    }

    private func chatDragTarget(at point: CGPoint) -> TitleBarClick? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system,0.12)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system,Float(point.x),Float(point.y),&hit) == .success,
              let hit, let role = attr(hit,kAXRoleAttribute) as? String else { return nil }
        let target = role == kAXWindowRole ? hit : element(hit,kAXWindowAttribute)
        guard let window = target, let rect = windowRect(window), rect.contains(point),
              point.y-rect.minY < 36, attr(window,"AXFullScreen") as? Bool != true else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window,&pid) == .success,
              let app = NSRunningApplication(processIdentifier:pid), app.isActive else { return nil }
        let isTitle: Bool
        switch role {
        case kAXWindowRole, kAXToolbarRole: isTitle = true
        case kAXStaticTextRole:
            isTitle = element(window,kAXTitleUIElementAttribute).map { CFEqual($0,hit) } == true ||
                      (attr(hit,kAXValueAttribute) as? String).map { !$0.isEmpty && $0 == attr(window,kAXTitleAttribute) as? String } == true
        case kAXGroupRole:
            let parent = element(hit,kAXParentAttribute)
            isTitle = parent.map { CFEqual($0,window) || attr($0,kAXRoleAttribute) as? String == kAXToolbarRole } == true
        default: isTitle = false
        }
        var writable = DarwinBoolean(false)
        guard isTitle, AXUIElementIsAttributeSettable(window,kAXPositionAttribute as CFString,&writable) == .success,
              writable.boolValue else { return nil }
        return TitleBarClick(window:window,app:app,point:point,frame:rect)
    }
}
