import SwiftUI
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
        case .battery: return "Настройки аккумулятора…"
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
    let openSettings: (String) -> Void
    @ObservedObject private var access = WiFiLocationAccess.shared
    @State private var power = false
    @State private var connected: String?
    @State private var associated = false
    @State private var networks: [NetworkChoice] = []
    @State private var scanID: UUID?
    @State private var connecting = false
    private var busy: Bool { scanID != nil || connecting }
    @State private var message = ""
    @State private var selected: NetworkChoice?
    @State private var password = ""
    private var interface: CWInterface? { CWWiFiClient.shared().interface() }

    private func load() {
        power = interface?.powerOn() == true
        connected = interface?.ssid()
        associated = power && (connected != nil || (interface?.transmitRate() ?? 0) > 0)
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

    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing: 10) {
                Image(systemName: power ? "wifi" : "wifi.slash")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(power ? Color.blue : Color.secondary, in: Circle())
                    .accessibilityHidden(true)
                Text(associated ? (connected ?? "Подключено") : (power ? "Нет подключения" : "Wi-Fi выключен"))
                    .font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                WirelessSwitch(title: "Wi-Fi", isOn: Binding(get: { power }, set: setPower))
                    .disabled(connecting || interface == nil)
            }
            if power {
                Divider()
                if access.status != .authorizedAlways {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Доступные сети").font(.subheadline.weight(.semibold))
                        Text("Для показа названий сетей macOS нужен доступ к геолокации.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if access.status == .notDetermined {
                            Button("Разрешить доступ") { access.request() }
                        } else {
                            Button("Настройки геолокации…") { openSettings("com.apple.preference.security?Privacy_LocationServices") }
                        }
                    }
                } else if let choice = selected {
                    Text(choice.id).fontWeight(.semibold)
                    if !choice.network.supportsSecurity(.none) {
                        SecureField("Пароль сети",text:$password).onSubmit { connect(choice) }
                    }
                    HStack {
                        Button("Назад") { selected = nil; password = ""; message = "" }
                        Spacer()
                        Button("Подключиться") { connect(choice) }.disabled(busy)
                    }
                } else {
                    HStack {
                        Text("Доступные сети").font(.subheadline.weight(.semibold))
                        Spacer()
                        if busy { ProgressView().controlSize(.small) }
                        Button(action:scan) { Image(systemName:"arrow.clockwise") }
                            .buttonStyle(.borderless).accessibilityLabel("Обновить список сетей").disabled(busy)
                    }
                    ScrollView {
                        VStack(spacing:1) {
                            ForEach(networks) { choice in
                                Button {
                                    if choice.id != connected { selected = choice; password = ""; message = "" }
                                } label: {
                                    HStack {
                                        Image(systemName: "wifi", variableValue: choice.network.rssiValue >= -60 ? 1 : (choice.network.rssiValue >= -75 ? 0.66 : 0.33))
                                            .foregroundStyle(choice.id == connected ? Color.accentColor : .secondary)
                                            .frame(width: 22)
                                        Text(choice.id).lineLimit(1)
                                        Spacer()
                                        if choice.id == connected { Image(systemName:"checkmark").foregroundStyle(Color.accentColor) }
                                        else if !choice.network.supportsSecurity(.none) { Image(systemName:"lock.fill").font(.caption).foregroundStyle(.secondary) }
                                    }.padding(.vertical,5).contentShape(Rectangle())
                                }.buttonStyle(MenuRowStyle(selected: choice.id == connected))
                            }
                            if networks.isEmpty && message.isEmpty { Text(busy ? "Поиск сетей…" : "Сети поблизости не найдены").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8) }
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }.frame(height: min(168, CGFloat(max(networks.count, 1)) * 34))
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { load(); scan() }
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
    @State private var devices: [AudioOutput] = []
    @State private var device: AudioDeviceID = 0
    @State private var volume: Float?
    @State private var message = ""
    private func load() {
        devices = ShelfAudio.outputs()
        device = ShelfAudio.current
        volume = ShelfAudio.volume(device)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Image(systemName:(volume ?? 0) > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill").foregroundStyle(.secondary)
                Slider(value:Binding(get:{ Double(volume ?? 0) },set:{ value in
                    if ShelfAudio.setVolume(Float(value),device:device) { volume = Float(value); message = "" }
                    else { message = "Не удалось изменить громкость."; load() }
                }),in:0...1).disabled(volume == nil).accessibilityLabel("Громкость")
                if let volume { Text("\(Int((volume*100).rounded()))%").monospacedDigit().frame(width:36,alignment:.trailing) }
            }
            Divider()
            Text("Устройство вывода").font(.subheadline.weight(.semibold))
            ScrollView {
                VStack(spacing:2) {
                    ForEach(devices) { output in
                        Button {
                            if !ShelfAudio.select(output.id) { message = "Не удалось переключить устройство." }
                            else { message = "" }
                            load()
                        } label: {
                            HStack {
                                Image(systemName:"hifispeaker").frame(width:22)
                                Text(output.name).lineLimit(1)
                                Spacer()
                                if output.id == device { Image(systemName:"checkmark").foregroundStyle(Color.accentColor) }
                            }.padding(.vertical,6).contentShape(Rectangle())
                        }.buttonStyle(MenuRowStyle(selected: output.id == device))
                    }
                }
            }.frame(height:min(128,CGFloat(max(1,devices.count))*32))
            if !message.isEmpty { Text(message).font(.caption) }
        }.onAppear(perform:load)
         .onReceive(Timer.publish(every:1,on:.main,in:.common).autoconnect()) { _ in load() }
    }
}

struct TrayControls: View {
    let display: CGDirectDisplayID
    let initialPage: TrayPage
    @State private var wirelessPage: TrayPage = .wifi
    private var page: TrayPage { initialPage == .wifi ? wirelessPage : initialPage }
    let openAirDrop: () -> Void
    let openSettings: (String)->Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if initialPage == .wifi {
                Picker("Беспроводные подключения", selection: $wirelessPage) {
                    Text(TrayPage.wifi.rawValue).tag(TrayPage.wifi)
                    Text(TrayPage.bluetooth.rawValue).tag(TrayPage.bluetooth)
                    Text(TrayPage.airDrop.rawValue).tag(TrayPage.airDrop)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10).padding(.top, 10)
            }

            Group {
                switch page {
                case .wifi: WiFiControls(openSettings: openSettings)
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
                case .bluetooth: BluetoothControls()
                case .battery: BatteryControls(display: display)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 10).padding(.vertical, 8)

            Divider()
            Button { openSettings(page.settings) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text(page.settingsTitle)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }.foregroundStyle(.secondary)
            }.buttonStyle(MenuRowStyle()).padding(.horizontal, 7).padding(.vertical, 4)
        }.frame(width: initialPage == .wifi ? 332 : 310).fixedSize(horizontal: false, vertical: true)
    }
}
