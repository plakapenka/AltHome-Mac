import SwiftUI
import CoreWLAN
import CoreBluetooth
import IOBluetooth
import IOKit.ps

enum TrayPage: String {
    case wifi = "Wi-Fi", sound = "Звук", bluetooth = "Bluetooth", battery = "Аккумулятор"
    var icon: String {
        switch self {
        case .wifi: return "wifi"
        case .sound: return "speaker.wave.2.fill"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        case .battery: return "battery.75percent"
        }
    }
    var settingsTitle: String {
        switch self {
        case .wifi: return "Настройки Wi-Fi…"
        case .sound: return "Настройки звука…"
        case .bluetooth: return "Настройки Bluetooth…"
        case .battery: return "Настройки аккумулятора…"
        }
    }
    var settings: String {
        switch self {
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

private struct WiFiControls: View {
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
        networks = power ? networkChoices(interface?.cachedScanResults() ?? []) : []
    }
    private func scan() {
        guard let device = interface, power, !busy else { return }
        let id = UUID()
        scanID = id
        message = ""
        DispatchQueue.global(qos:.utility).async {
            let discovered = Result { try device.scanForNetworks(withSSID:nil) }
            DispatchQueue.main.async {
                guard scanID == id else { return }
                scanID = nil
                load()
                guard power else { return }
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
            HStack {
                Text(associated ? (connected ?? "Подключено") : (power ? "Нет подключения" : "Выключено"))
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Toggle("Wi-Fi", isOn: Binding(get: { power }, set: setPower))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.blue)
                    .environment(\.controlActiveState, .active)
                    .disabled(connecting || interface == nil)
            }
            if power {
                Divider()
                if let choice = selected {
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
                                        Image(systemName:"wifi").frame(width:22)
                                        Text(choice.id).lineLimit(1)
                                        Spacer()
                                        if choice.id == connected { Image(systemName:"checkmark") }
                                        else if !choice.network.supportsSecurity(.none) { Image(systemName:"lock.fill").font(.caption).foregroundStyle(.secondary) }
                                    }.padding(.vertical,5).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            if networks.isEmpty { Text(busy ? "Поиск сетей…" : "Нет доступных названий сетей").foregroundStyle(.secondary) }
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }.frame(height:140)
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.onAppear { load(); if power && networks.isEmpty { scan() } }
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
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height:min(128,CGFloat(max(1,devices.count))*32))
            if !message.isEmpty { Text(message).font(.caption) }
        }.onAppear(perform:load)
         .onReceive(Timer.publish(every:1,on:.main,in:.common).autoconnect()) { _ in load() }
    }
}

struct TrayControls: View {
    let page: TrayPage
    let openSettings: (String)->Void
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Image(systemName:page.icon).foregroundStyle(Color.accentColor)
                Text(page.rawValue).font(.headline)
                Spacer()
            }
            switch page {
            case .wifi: WiFiControls()
            case .sound: SoundControls()
            case .bluetooth:
                Text(IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON ? "Включено" : "Выключено")
                if CBManager.authorization == .allowedAlways {
                    let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { $0.isConnected() }
                    ForEach(0..<min(devices.count,6),id:\.self) { i in
                        Label(devices[i].name ?? "Устройство",systemImage:"checkmark.circle").foregroundStyle(.secondary)
                    }
                }
            case .battery:
                if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                   let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
                   let battery = sources.compactMap({ IOPSGetPowerSourceDescription(info,$0)?.takeUnretainedValue() as? [String:Any] }).first(where:{ $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }),
                   let charge = battery[kIOPSCurrentCapacityKey] as? Int, let max = battery[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    ProgressView(value:Double(charge),total:Double(max))
                    Text("\(charge*100/max)% · " + (battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue ? "Питание от сети" : "Питание от аккумулятора"))
                }
            }
            Divider()
            Button(page.settingsTitle) { openSettings(page.settings) }.buttonStyle(.link)
        }.padding(16).frame(width:310).fixedSize(horizontal:false,vertical:true)
    }
}
