import Carbon
import Foundation

final class ScreenshotShortcut {
    static let preference = "optionShiftScreenshot"
    private static let hotKeyID = EventHotKeyID(signature: 0x54535343, id: 1) // TSSC
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var capture: Process?
    private let reportError: (String) -> Void

    init(reportError: @escaping (String) -> Void) { self.reportError = reportError }

    func setEnabled(_ enabled: Bool) -> Bool {
        guard enabled else {
            stop()
            return true
        }
        if hotKey != nil { return true }
        let target = GetApplicationEventTarget()
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(target, { _, event, context in
            var id = EventHotKeyID()
            guard let event, let context,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == ScreenshotShortcut.hotKeyID.signature, id.id == ScreenshotShortcut.hotKeyID.id
            else { return OSStatus(eventNotHandledErr) }
            Unmanaged<ScreenshotShortcut>.fromOpaque(context).takeUnretainedValue().startCapture()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return false }
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(optionKey | shiftKey), Self.hotKeyID,
                                         target, UInt32(kEventHotKeyExclusive), &hotKey)
        guard result == noErr else { stop(); return false }
        return true
    }

    private func startCapture() {
        guard capture?.isRunning != true else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-c", "-d"]
        do {
            try process.run()
            capture = process
        } catch {
            reportError("Не удалось открыть инструмент снимка экрана. " + error.localizedDescription)
        }
    }

    private func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        if let capture, capture.isRunning { capture.terminate() }
        capture = nil
    }

    deinit { stop() }
}
