import SwiftUI
import Combine
import CoreLocation
import CoreWLAN
import CoreBluetooth
import IOBluetooth

enum TrayPage: String {
    case wifi = "Wi-Fi", sound = "Звук", bluetooth = "Bluetooth", airDrop = "AirDrop", battery = "Аккумулятор"

    var settingsTitle: String {
        switch self {
        case .airDrop: return "Настройки AirDrop…"
        case .wifi: return "Настройки Wi-Fi…"
        case .sound: return "Настройки звука…"
        case .bluetooth: return "Настройки Bluetooth…"
        case .battery: return "Настройки аккумулятора"
        }
    }
    var settings: String {
        switch self {
        case .airDrop: return "com.apple.AirDrop-Handoff-Settings.extension"
        case .wifi: return "com.apple.wifi-settings-extension"
        case .sound: return "com.apple.Sound-Settings.extension"
        case .bluetooth: return "com.apple.BluetoothSettings"
        case .battery: return "com.apple.Battery-Settings.extension"
        }
    }
}

private struct NetworkChoice: Identifiable {
    let id: String
    let network: CWNetwork
}

private func networkChoices(_ networks: Set<CWNetwork>) -> [NetworkChoice] {
    var names = Set<String>()
    return networks.sorted { $0.rssiValue > $1.rssiValue }.compactMap {
        guard let name = $0.ssid, !name.isEmpty, name != "<redacted>", names.insert(name).inserted else { return nil }
        return NetworkChoice(id:name,network:$0)
    }
}

private struct WirelessSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.blue)
            .environment(\.controlActiveState, .active)
    }
}

private final class WiFiLocationAccess: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WiFiLocationAccess()
    private let manager = CLLocationManager()
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined

    private override init() {
        super.init()
        status = manager.authorizationStatus
        manager.delegate = self
    }

    func request() {
        NSApp.activate(ignoringOtherApps: true)
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
    }
}

private struct WiFiControls: View {
    let updates: AnyPublisher<WiFiStatus, Never>
    let openSettings: (String) -> Void
    @ObservedObject private var access = WiFiLocationAccess.shared
    @State private var connection = WiFiStatus.off
    @State private var connected: String?
    private var power: Bool { connection != .off }
    @State private var networks: [NetworkChoice] = []
    @State private var scanID: UUID?
    @State private var connecting = false
    private var busy: Bool { scanID != nil || connecting }
    @State private var message = ""
    @State private var selected: NetworkChoice?
    @State private var password = ""
    private var interface: CWInterface? { CWWiFiClient.shared().interface() }

    private func updateConnection(_ status: WiFiStatus) {
        connection = status
        connected = status.associated ? interface?.ssid() : nil
    }

    private func load() {
        updateConnection(.current(interface))
        if !power || access.status != .authorizedAlways {
            networks = []
            selected = nil
            password = ""
            scanID = nil
        } else if networks.isEmpty {
            networks = networkChoices(interface?.cachedScanResults() ?? [])
        }
    }
    private func scan() {
        guard let device = interface, power, access.status == .authorizedAlways, !busy else { return }
        let id = UUID()
        scanID = id
        message = ""
        DispatchQueue.global(qos:.utility).async {
            let discovered = Result { try device.scanForNetworks(withSSID:nil) }
            DispatchQueue.main.async {
                guard scanID == id else { return }
                scanID = nil
                load()
                guard power, access.status == .authorizedAlways else { return }
                switch discovered {
                case .success(let list): networks = networkChoices(list)
                case .failure: message = "Не удалось обновить список сетей."
                }
            }
        }
    }
    private func connect(_ choice: NetworkChoice) {
        guard !busy, let device = interface else { return }
        let secret = password.isEmpty ? nil : password
        connecting = true
        message = ""
        password = ""
        DispatchQueue.global(qos:.userInitiated).async {
            let result = Result { try device.associate(to:choice.network,password:secret) }
            DispatchQueue.main.async {
                connecting = false
                switch result {
                case .success: selected = nil; message = "Подключено к «" + choice.id + "»."
                case .failure: message = "Не удалось подключиться. Проверьте пароль или откройте настройки Wi-Fi."
                }
                load()
            }
        }
    }
    private func setPower(_ enabled: Bool) {
        guard let device = interface else { return }
        do {
            try device.setPower(enabled)
            scanID = nil
            selected = nil
            password = ""
            message = ""
            load()
            if power { scan() }
        } catch {
            message = "Не удалось переключить Wi-Fi."
            load()
        }
    }

    private var connectionSummary: some View {
        HStack(spacing: 11) {
            Image(systemName: connection.symbol, variableValue: connection.value)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(connection.associated ? Color.white : .secondary)
                .frame(width: 36, height: 36)
                .background(connection.associated ? Color.blue : Color.primary.opacity(0.08), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(connected ?? "Wi-Fi")
                    .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(connection.description)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            WirelessSwitch(title: "Wi-Fi", isOn: Binding(get: { power }, set: setPower))
                .disabled(connecting || interface == nil)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func networkRow(_ choice: NetworkChoice) -> some View {
        let signal = WiFiStatus.Signal(rssi: choice.network.rssiValue).value
        let secured = !choice.network.supportsSecurity(.none)
        return Button {
            selected = choice
            password = ""
            message = ""
        } label: {
            HStack(spacing: 10) {
                Text(choice.id).lineLimit(1)
                Spacer(minLength: 8)
                if secured {
                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Image(systemName: "wifi", variableValue: signal)
                    .font(.system(size: 13, weight: .medium)).frame(width: 18)
            }
            .padding(.horizontal, 4).frame(height: 33)
        }
        .buttonStyle(MenuRowStyle())
        .accessibilityLabel(choice.id)
        .accessibilityValue(secured ? "Защищённая сеть" : "Открытая сеть")
    }

    private var networkList: some View {
        let nearby = networks.filter { $0.id != connected }
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(connected == nil ? "Доступные сети" : "Другие сети")
                    .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: scan) {
                    ZStack {
                        if busy { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)) }
                    }.frame(width: 26, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Обновить список сетей").disabled(busy)
            }.padding(.leading, 12).padding(.trailing, 5)
            if nearby.isEmpty {
                if message.isEmpty {
                    Text(busy ? "Поиск сетей…" : "Других сетей поблизости нет")
                        .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
                }
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(nearby) { networkRow($0) }
                    }.padding(.trailing, 2)
                }.frame(height: CGFloat(min(nearby.count, 5)) * 34 - 1)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            connectionSummary
            if power {
                Divider().padding(.horizontal, 8)
                if access.status != .authorizedAlways {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Для показа названий сетей macOS нужен доступ к геолокации.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if access.status == .notDetermined {
                            Button("Разрешить доступ") { access.request() }
                        } else {
                            Button("Настройки геолокации…") { openSettings("com.apple.preference.security?Privacy_LocationServices") }
                        }
                    }.padding(.horizontal, 10)
                } else if let choice = selected {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(choice.id).font(.headline).lineLimit(1)
                        if !choice.network.supportsSecurity(.none) {
                            SecureField("Пароль сети", text: $password).onSubmit { connect(choice) }
                        }
                        HStack {
                            Button("Назад") { selected = nil; password = ""; message = "" }
                            Spacer()
                            Button("Подключиться") { connect(choice) }.buttonStyle(.borderedProminent).disabled(busy)
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 4)
                } else {
                    networkList
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10) }
        }
        .onAppear { load(); scan() }
        .onReceive(updates, perform: updateConnection)
        .onChange(of: access.status) { _ in load(); scan() }
        .onDisappear { scanID = nil }
    }
}

// IOBluetooth exposes controller power preferences at runtime. Keep the
// settings link usable if a future framework omits these entry points.
private enum BluetoothPower {
    private static let framework = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
    private typealias Getter = @convention(c) () -> Int32
    typealias Setter = @convention(c) (Int32) -> Void
    private static let read = framework.flatMap { dlsym($0, "IOBluetoothPreferenceGetControllerPowerState") }
        .map { unsafeBitCast($0, to: Getter.self) }
    static let write = framework.flatMap { dlsym($0, "IOBluetoothPreferenceSetControllerPowerState") }
        .map { unsafeBitCast($0, to: Setter.self) }

    static var current: Bool? {
        switch read?() {
        case 0: return false
        case 1: return true
        default: return nil
        }
    }
}

private struct BluetoothControls: View {
    @State private var power = BluetoothPower.current
    @State private var pending: Bool?
    @State private var deadline = Date.distantPast
    @State private var message = ""
    @State private var devices: [IOBluetoothDevice] = []

    private func refresh() {
        power = BluetoothPower.current
        if let pending {
            if power == pending {
                self.pending = nil
            } else if Date() >= deadline {
                self.pending = nil
                message = "Не удалось переключить Bluetooth."
            }
        }
        if power == true && CBManager.authorization == .allowedAlways {
            devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { $0.isConnected() }
        } else {
            devices = []
        }
    }

    private func setPower(_ enabled: Bool) {
        guard let write = BluetoothPower.write, pending == nil else { return }
        message = ""
        pending = enabled
        deadline = Date().addingTimeInterval(5)
        write(enabled ? 1 : 0)
        refresh()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(power.map { $0 ? "Включено" : "Выключено" } ?? "Недоступно")
                    .foregroundStyle(.secondary)
                Spacer()
                WirelessSwitch(title: "Bluetooth", isOn: Binding(get: { pending ?? power ?? false }, set: setPower))
                    .disabled(pending != nil || power == nil || BluetoothPower.write == nil)
            }
            ForEach(devices.prefix(6), id: \.self) { device in
                Label(device.name ?? "Устройство", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }
}

private struct SoundControls: View {
    @ObservedObject private var indicator = OutputVolumeIndicator.shared
    @State private var devices: [AudioOutput] = []
    @State private var device: AudioDeviceID = 0
    @State private var volume: Float?
    @State private var message = ""
    private func load() {
        devices = ShelfAudio.outputs()
        device = ShelfAudio.current
        volume = ShelfAudio.volume(device)
    }
    private var volumeBinding: Binding<Double> {
        Binding(get: { Double(volume ?? 0) }, set: { value in
            if indicator.setVolume(Float(value), device: device) {
                volume = Float(value)
                message = ""
            } else {
                message = "Не удалось изменить громкость."
                load()
            }
        })
    }

    private func deviceRow(_ output: AudioOutput) -> some View {
        let selected = output.id == device
        return Button {
            message = ShelfAudio.select(output.id) ? "" : "Не удалось переключить устройство."
            load()
        } label: {
            HStack(spacing: 10) {
                Text(output.name).lineLimit(1).truncationMode(.middle)
                    .fontWeight(selected ? .semibold : .regular)
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor).accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(MenuRowStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(output.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: indicator.symbol + ".fill")
                    .font(.system(size: 17, weight: .medium)).frame(width: 24)
                    .accessibilityHidden(true)
                Slider(value: volumeBinding, in: 0...1)
                    .controlSize(.large).disabled(volume == nil)
                    .accessibilityLabel("Громкость")
                if let volume {
                    Text(Double(volume), format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            if !devices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Устройство вывода").font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary).padding(.horizontal, 8)
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(devices) { output in deviceRow(output) }
                        }
                    }
                    .frame(height: CGFloat(min(devices.count, 4)) * 34 - 2)
                }
            }
            if !message.isEmpty { Text(message).font(.caption).padding(.horizontal, 8) }
        }
        .padding(.top, 8)
        .onAppear(perform: load)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in load() }
    }
}

private struct WirelessTabs: View {
    @Binding var selection: TrayPage
    @State private var hovered: TrayPage?
    @FocusState private var focused: TrayPage?
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let tabs: [TrayPage] = [.wifi, .bluetooth, .airDrop]

    @ViewBuilder
    private func icon(for tab: TrayPage) -> some View {
        if tab == .airDrop {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let unit = min(size.width, size.height) / 16
                for radius: CGFloat in [3, 5.2, 7.4] {
                    var ring = Path()
                    ring.addArc(center: center, radius: radius * unit, startAngle: .degrees(124),
                                endAngle: .degrees(416), clockwise: false)
                    context.stroke(ring, with: .foreground, style: StrokeStyle(lineWidth: unit, lineCap: .round))
                }
                context.fill(Path(ellipseIn: CGRect(x: center.x - unit, y: center.y - unit,
                                                   width: 2 * unit, height: 2 * unit)), with: .foreground)
            }
        } else if tab == .bluetooth, let image = NSImage(named: NSImage.bluetoothTemplateName) {
            Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
        } else {
            Image(systemName: tab == .wifi ? "wifi" : "antenna.radiowaves.left.and.right")
                .resizable().scaledToFit()
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.tabs, id: \.self) { tab in
                let selected = selection == tab
                Button { selection = tab } label: {
                    HStack(spacing: 5) {
                        icon(for: tab).frame(width: 16, height: 16)
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).frame(height: 33)
                    .background {
                        if selected {
                            Capsule().fill(Color.primary.opacity(0.12))
                                .matchedGeometryEffect(id: "selection", in: highlight)
                        } else if hovered == tab {
                            Capsule().fill(Color.primary.opacity(0.06))
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focused($focused, equals: tab)
                .onHover { inside in
                    if inside { hovered = tab } else if hovered == tab { hovered = nil }
                }
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .onMoveCommand { direction in
            guard let focused, let index = Self.tabs.firstIndex(of: focused) else { return }
            let next: Int
            switch direction {
            case .left: next = index - 1
            case .right: next = index + 1
            default: return
            }
            guard Self.tabs.indices.contains(next) else { return }
            selection = Self.tabs[next]
            self.focused = selection
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
    }
}

struct TrayControls: View {
    let display: CGDirectDisplayID
    let initialPage: TrayPage
    let wifiUpdates: AnyPublisher<WiFiStatus, Never>
    @State private var wirelessPage: TrayPage = .wifi
    private var page: TrayPage { initialPage == .wifi ? wirelessPage : initialPage }
    let openAirDrop: () -> Void
    let openSettings: (String)->Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if initialPage == .wifi {
                WirelessTabs(selection: $wirelessPage)
                    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
            }

            Group {
                switch page {
                case .wifi: WiFiControls(updates: wifiUpdates, openSettings: openSettings)
                case .airDrop:
                    Button(action: openAirDrop) {
                        HStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(Color.blue).font(.title2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Открыть AirDrop").fontWeight(.semibold)
                                Text("Передать файлы через Finder").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(MenuRowStyle())
                case .sound: SoundControls()
                case .bluetooth: BluetoothControls().padding(.horizontal, 8)
                case .battery: BatteryControls(display: display)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)

            Divider().padding(.horizontal, 16)
            Button { openSettings(page.settings) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text(page.settingsTitle)
                    Spacer()
                    if page != .battery {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                }.foregroundStyle(.secondary)
            }.buttonStyle(MenuRowStyle()).padding(.horizontal, 10).padding(.vertical, 6)
        }
        .frame(width: 336)
        .fixedSize(horizontal: false, vertical: true)
        .background { ShelfPanelSurface() }
    }
}
