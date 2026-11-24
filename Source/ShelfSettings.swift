import SwiftUI
import ServiceManagement

private enum SettingsPage: String, CaseIterable {
    case general = "Основные", dock = "Dock"
    var icon: String { self == .general ? "slider.horizontal.3" : "dock.rectangle" }
}

private struct ShelfSettings: View {
    unowned let owner: Delegate
    @State private var page: SettingsPage? = .general
    @AppStorage("fnCommandLetters") private var fnCommandLetters = false
    @AppStorage("layoutShortcutMode") private var layoutShortcutMode: String?
    @AppStorage("blockMenuBarHover") private var blockMenuBarHover = false
    @AppStorage("shelfEdge") private var shelfEdge = ShelfEdge.bottom
    @AppStorage("showDate") private var showsDate = true
    @AppStorage("dockMode") private var dockMode = DockMode.system
    @AppStorage("dockPinned") private var dockPinned = false
    @AppStorage("dockIconSize") private var iconSize = DockSizing.systemSize
    @AppStorage("dockMagnifies") private var magnifies = true
    @AppStorage("dockZoom") private var zoom = 1.55
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
                        Picker("Режим Dock", selection: Binding(get: { dockMode }, set: {
                            owner.tray.configureDock($0)
                            owner.render()
                        })) {
                            Text("Системный").tag(DockMode.system)
                            Text("Dock TaskShelf").tag(DockMode.taskShelf)
                            Text("Скрыть оба").tag(DockMode.hidden)
                        }.pickerStyle(.segmented)
                        Picker("Отображение", selection: Binding(get: { dockPinned }, set: { owner.tray.setDockPinned($0) })) {
                            Text("Автоматически скрывать").tag(false)
                            Text("Всегда показывать").tag(true)
                        }.pickerStyle(.radioGroup).disabled(dockMode != .taskShelf)
                        if dockMode == .taskShelf {
                            Section {
                                LabeledContent("Размер значков") {
                                    Slider(value: Binding(get: { iconSize }, set: {
                                        iconSize = $0.rounded()
                                        owner.tray.previewDock(.size)
                                    }), in: 16...128, onEditingChanged: { owner.tray.previewDock(.size, editing: $0) })
                                        .accessibilityLabel("Размер значков")
                                    Text("\(Int(iconSize)) пт").monospacedDigit().frame(width: 48, alignment: .trailing)
                                }
                                Toggle("Увеличение при наведении", isOn: $magnifies)
                                LabeledContent("Увеличение") {
                                    Slider(value: Binding(get: { zoom }, set: {
                                        zoom = $0
                                        owner.tray.previewDock(.magnification)
                                    }), in: 1.1...2, step: 0.05, onEditingChanged: { owner.tray.previewDock(.magnification, editing: $0) })
                                        .accessibilityLabel("Степень увеличения")
                                    Text(zoom, format: .percent.precision(.fractionLength(0)))
                                        .monospacedDigit().frame(width: 48, alignment: .trailing)
                                }.disabled(!magnifies)
                            }
                            .onDisappear { owner.tray.endDockPreview() }
                        }
                    } else {
                        Section {
                            Picker("Положение панели", selection: $shelfEdge) {
                                Text("Снизу").tag(ShelfEdge.bottom)
                                Text("Сверху").tag(ShelfEdge.top)
                            }.pickerStyle(.segmented)
                            .onChange(of: shelfEdge) { _ in owner.render() }
                            Toggle("Показывать дату", isOn: $showsDate)
                                .onChange(of: showsDate) { _ in owner.render() }
                            Picker("Переключение языка", selection: Binding(get: {
                                layoutShortcutMode.flatMap(LayoutShortcutMode.init(rawValue:)) ?? LayoutShortcutMode.saved(in: owner.defaults)
                            }, set: { mode in
                                if mode != .system && !AXIsProcessTrusted() { owner.requestWindowAccess(); return }
                                guard owner.layoutShortcut.apply(mode) else {
                                    owner.notify("Не удалось включить сочетание. Проверьте доступ TaskShelf к мониторингу ввода в настройках macOS.")
                                    return
                                }
                                layoutShortcutMode = mode.rawValue
                            })) {
                                ForEach(LayoutShortcutMode.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .help("Если Command и Control поменяны местами в macOS, для физической клавиши ⌘ выберите Control + Shift.")
                            Toggle("Fn как ⌘ для букв", isOn: Binding(get: { fnCommandLetters }, set: { enabled in
                                if enabled && !AXIsProcessTrusted() { owner.requestWindowAccess(); return }
                                guard owner.fnCommand.setEnabled(enabled) else {
                                    owner.notify("Не удалось включить сочетания Fn. Проверьте «Универсальный доступ» для TaskShelf.")
                                    return
                                }
                                fnCommandLetters = enabled
                            }))
                            .help("Fn+C копирует, Fn+V вставляет, Fn+Z отменяет действие. Одиночное Fn выполняет действие из настроек macOS.")
                            Toggle("Блокировать строку меню при наведении", isOn: Binding(get: { blockMenuBarHover }, set: { enabled in
                                if enabled {
                                    guard AXIsProcessTrusted() else { owner.requestWindowAccess(); return }
                                    guard owner.menuBarEdge.start() else {
                                        owner.notify("Не удалось включить блокировку верхнего края. Проверьте «Универсальный доступ» для TaskShelf.")
                                        return
                                    }
                                } else {
                                    owner.menuBarEdge.stop()
                                }
                                blockMenuBarHover = enabled
                            }))
                            .help("Для скрытой строки меню. В настройках macOS выберите автоскрытие «Всегда».")
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
        }.frame(width: 590, height: 420)
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
