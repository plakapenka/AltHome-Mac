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
func shelfLimitedZoom(_ frame: CGRect, before: CGRect, visible: CGRect, usable: CGRect) -> CGRect? {
    guard !nearlyEqual(frame, before), usable.maxY < visible.maxY,
          frame.minY >= visible.minY - 24, frame.minY <= visible.minY + 24,
          frame.maxY >= visible.maxY - 24, frame.maxY > usable.maxY,
          frame.intersects(usable), frame.minY < usable.maxY else { return nil }
    return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: usable.maxY - frame.minY)
}

struct TitleBarClick {
    let window: AXUIElement
    let app: NSRunningApplication
    let point: CGPoint
    let frame: CGRect
}

struct ChatTitleDrag {
    let click: TitleBarClick
    let started: TimeInterval
    var moving = false
    var lastWrite: TimeInterval = 0
}

extension Delegate {
    func usableFrame(on screen: NSScreen) -> CGRect {
        var frame = screen.visibleFrame
        if frame.intersects(bar.frame) {
            let bottom = min(frame.maxY, (tray.pinnedDockTop ?? bar.frame.maxY) + 2)
            frame.size.height = frame.maxY - bottom
            frame.origin.y = bottom
        }
        return frame
    }

    func monitorTitleBarZoom() {
        guard zoomMonitor == nil, AXIsProcessTrusted() else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<Delegate>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.zoomCheck?.cancel()
                owner.titleBarClick = nil
                owner.chatTitleDrag = nil
                if let tap = owner.zoomMonitor { CGEvent.tapEnable(tap:tap,enable:true) }
            } else {
                owner.handleTitleBarMouse(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,options:.defaultTap,
                                         eventsOfInterest:CGEventMask(mask),callback:callback,
                                         userInfo:Unmanaged.passUnretained(self).toOpaque()) else { return }
        zoomMonitor = tap
        CFRunLoopAddSource(CFRunLoopGetMain(),CFMachPortCreateRunLoopSource(nil,tap,0),.commonModes)
        CGEvent.tapEnable(tap:tap,enable:true)
    }

    private func handleTitleBarMouse(_ type: CGEventType, _ event: CGEvent) {
        if type == .leftMouseDown {
            zoomCheck?.cancel()
            titleBarClick = nil
            chatTitleDrag = nil
            guard event.flags.intersection([.maskCommand,.maskAlternate,.maskControl,.maskShift]).isEmpty else { return }
            let count = event.getIntegerValueField(.mouseEventClickState)
            if count == 1, ws.frontmostApplication?.bundleIdentifier == "com.openai.codex",
               let click = chatDragTarget(at:event.location) {
                chatTitleDrag = ChatTitleDrag(click:click,started:ProcessInfo.processInfo.systemUptime)
            }
            if count == 2, let app = ws.frontmostApplication, app != .current {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 0.12)
                if let window = element(root, kAXFocusedWindowAttribute), let frame = windowRect(window),
                   frame.contains(event.location) {
                    titleBarClick = TitleBarClick(window: window, app: app, point: event.location, frame: frame)
                }
            }
        } else if chatTitleDrag != nil {
            updateChatDrag(at:event.location, ending:type == .leftMouseUp)
        } else if type == .leftMouseUp, let click = titleBarClick {
            titleBarClick = nil
            if hypot(event.location.x-click.point.x, event.location.y-click.point.y) <= 4 {
                checkNativeZoom(click, attempt: 0)
            }
        }
    }

    private func checkNativeZoom(_ click: TitleBarClick, attempt: Int, lastFrame: CGRect? = nil) {
        let check = DispatchWorkItem { [weak self] in
            guard let self, click.app.isActive, !click.app.isTerminated,
                  let primary = NSScreen.screens.first,
                  let screen = NSScreen.screens.first(where: { accessibilityFrame($0.frame, primary: primary).contains(click.point) }),
                  screen.frame.intersects(self.bar.frame),
                  let frame = windowRect(click.window), !minimized(click.window),
                  attr(click.window, "AXFullScreen") as? Bool != true else { return }
            let visible = accessibilityFrame(screen.visibleFrame, primary: primary)
            let usable = accessibilityFrame(self.usableFrame(on: screen), primary: primary)
            let previous = self.expanded.first { CFEqual($0.1, click.window) && nearlyEqual($0.3, click.frame) }
            if let previous, nearlyEqual(previous.2, frame) {
                self.expanded.removeAll { CFEqual($0.1, click.window) }
                return
            }
            // Writing an intermediate animation frame lets the app overwrite our adjustment.
            if frame == lastFrame, let fitted = shelfLimitedZoom(frame, before: click.frame, visible: visible, usable: usable) {
                self.applyZoomBounds(previous?.2 ?? fitted, native: frame, click: click,
                                     restoring: previous != nil, retries: 4)
            } else if attempt < 12 {
                self.checkNativeZoom(click, attempt: attempt + 1, lastFrame: frame)
            }
        }
        zoomCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.035 : 0.1), execute: check)
    }

    private func applyZoomBounds(_ goal: CGRect, native: CGRect, click: TitleBarClick, restoring: Bool, retries: Int) {
        if goal.origin == native.origin {
            // Moving an already tiled window can restart the system zoom animation.
            var size = goal.size
            guard let value = AXValueCreate(.cgSize, &size),
                  AXUIElementSetAttributeValue(click.window, kAXSizeAttribute as CFString, value) == .success else { return }
        } else if !writeFrame(goal, to: click.window) { return }
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
