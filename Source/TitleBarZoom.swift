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
                owner.titleBarClick = nil
                owner.chatTitleDrag = nil
                if let tap = owner.zoomMonitor { CGEvent.tapEnable(tap:tap,enable:true) }
            } else if owner.handleTitleBarMouse(type,event) {
                return nil
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

    private func handleTitleBarMouse(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .leftMouseDown {
            titleBarClick = nil
            chatTitleDrag = nil
            guard event.flags.intersection([.maskCommand,.maskAlternate,.maskControl,.maskShift]).isEmpty else { return false }
            let count = event.getIntegerValueField(.mouseEventClickState)
            if count == 1, ws.frontmostApplication?.bundleIdentifier == "com.openai.codex",
               let click = titleTarget(at:event.location, forDrag:true) {
                chatTitleDrag = ChatTitleDrag(click:click,started:ProcessInfo.processInfo.systemUptime)
            }
            guard count == 2,
                  UserDefaults.standard.string(forKey:"AppleActionOnDoubleClick") == "Fill",
                  let click = titleTarget(at:event.location, forDrag:false) else { return false }
            titleBarClick = click
            return true
        } else if chatTitleDrag != nil {
            updateChatDrag(at:event.location, ending:type == .leftMouseUp)
        } else if type == .leftMouseUp, let click = titleBarClick {
            titleBarClick = nil
            guard hypot(event.location.x-click.point.x,event.location.y-click.point.y) <= 4 else { return true }
            DispatchQueue.main.async { [weak self] in
                guard !click.app.isTerminated, click.app.isActive else { return }
                self?.fit(click.window,click.app)
            }
            return true
        }
        return false
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

    private func titleTarget(at point: CGPoint, forDrag: Bool) -> TitleBarClick? {
        guard let primary = NSScreen.screens.first,
              forDrag || accessibilityFrame(primary.frame,primary:primary).contains(point) else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system,0.12)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system,Float(point.x),Float(point.y),&hit) == .success,
              let hit, let role = attr(hit,kAXRoleAttribute) as? String else { return nil }
        let target = role == kAXWindowRole ? hit : element(hit,kAXWindowAttribute)
        guard let window = target, let rect = windowRect(window), rect.contains(point),
              point.y-rect.minY < (forDrag ? 36 : 52), attr(window,"AXFullScreen") as? Bool != true else { return nil }
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
        var pid: pid_t = 0
        guard isTitle, AXUIElementIsAttributeSettable(window,(forDrag ? kAXPositionAttribute : kAXSizeAttribute) as CFString,&writable) == .success,
              writable.boolValue, AXUIElementGetPid(window,&pid) == .success,
              let app = NSRunningApplication(processIdentifier:pid), app.isActive else { return nil }
        // Let macOS restore a window that was already natively filled before TaskShelf started.
        if forDrag && app.bundleIdentifier != "com.openai.codex" { return nil }
        if !forDrag && nearlyEqual(rect,accessibilityFrame(primary.visibleFrame,primary:primary)) { return nil }
        return TitleBarClick(window:window,app:app,point:point,frame:rect)
    }
}
