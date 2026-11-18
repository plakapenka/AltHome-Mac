import SwiftUI
import ServiceManagement

private enum SettingsPage: String, CaseIterable {
    case general = "Основные", dock = "Dock"
    var icon: String { self == .general ? "slider.horizontal.3" : "dock.rectangle" }
}

private struct ShelfSettings: View {
    unowned let owner: Delegate
    @State private var page: SettingsPage? = .general
    @AppStorage("showDate") private var showsDate = true
    @AppStorage("mirrorSystemDock") private var mirror = false
    @AppStorage("dockPinned") private var dockPinned = false
    @State private var login = SMAppService.mainApp.status
    @State private var windowAccess = AXIsProcessTrusted()
    @State private var previewAccess = CGPreflightScreenCaptureAccess()

    func refresh() {
        login = SMAppService.mainApp.status
        windowAccess = AXIsProcessTrusted()
        previewAccess = CGPreflightScreenCaptureAccess()
    }

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsPage.allCases, id: \.self, selection: $page) { category in
                Label(category.rawValue, systemImage: category.icon).tag(category)
            }.listStyle(.sidebar).frame(width: 145)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text((page ?? .general).rawValue).font(.title2.weight(.semibold))
                    .padding(.leading, 20).padding(.top, 20)
                Form {
                    if page == .dock {
                        Toggle("Dock над панелью", isOn: Binding(get: { mirror }, set: {
                            owner.tray.configureDock(enabled: $0)
                            owner.render()
                        }))
                        Picker("Отображение", selection: Binding(get: { dockPinned }, set: { owner.tray.setDockPinned($0) })) {
                            Text("Автоматически скрывать").tag(false)
                            Text("Всегда показывать").tag(true)
                        }.pickerStyle(.radioGroup).disabled(!mirror)
                    } else {
                        Section {
                            Toggle("Показывать дату", isOn: $showsDate)
                                .onChange(of: showsDate) { _ in owner.render() }
                            Toggle("Запускать при входе", isOn: Binding(get: { login == .enabled }, set: { enabled in
                                let service = SMAppService.mainApp
                                do {
                                    if !enabled { try service.unregister() }
                                    else if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                                    else {
                                        try service.register()
                                        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                                    }
                                } catch { owner.notify(error.localizedDescription) }
                                refresh()
                            }))
                        }
                        Section("Разрешения") {
                            LabeledContent("Управление окнами") {
                                if windowAccess { Text("Разрешено").foregroundStyle(.secondary) }
                                else { Button("Разрешить…") { owner.requestWindowAccess() } }
                            }
                            LabeledContent("Превью окон") {
                                if previewAccess { Text("Разрешено").foregroundStyle(.secondary) }
                                else { Button("Разрешить…") {
                                    _ = CGRequestScreenCaptureAccess()
                                    refresh()
                                    if !previewAccess, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                        owner.ws.open(url)
                                    }
                                } }
                            }
                        }
                    }
                }.formStyle(.grouped)
            }
        }.frame(width: 535, height: 300)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
    }
}

extension Delegate {
    func showSettings() {
        if settingsWindow == nil {
            let view = ShelfSettings(owner: self).defaultAppStorage(defaults)
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.title = "Настройки TaskShelf"
            window.isReleasedWhenClosed = false
            window.setContentSize(host.view.fittingSize)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.deminiaturize(nil)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
