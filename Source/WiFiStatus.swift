import AppKit
import CoreWLAN

enum WiFiStatus: Equatable {
    case off, disconnected
    case connected(Signal)

    enum Signal: Equatable {
        case unknown, weak, fair, strong

        init(rssi: Int) {
            switch rssi {
            case -60 ... -1: self = .strong
            case -75 ..< -60: self = .fair
            case -126 ..< -75: self = .weak
            default: self = .unknown
            }
        }

        var value: Double {
            switch self {
            case .unknown: return 0
            case .weak: return 0.33
            case .fair: return 0.66
            case .strong: return 1
            }
        }
    }

    static func current(_ interface: CWInterface? = CWWiFiClient.shared().interface()) -> Self {
        guard let interface, interface.powerOn() else { return .off }
        let signal = Signal(rssi: interface.rssiValue())
        // A valid link measurement is available even when macOS withholds the network name.
        if signal != .unknown || interface.transmitRate() > 0 { return .connected(signal) }
        return .disconnected
    }

    var associated: Bool {
        if case .connected = self { return true }
        return false
    }

    var symbol: String {
        switch self {
        case .off: return "wifi.slash"
        case .disconnected: return "wifi.exclamationmark"
        case .connected: return "wifi"
        }
    }

    var value: Double {
        if case let .connected(signal) = self { return signal.value }
        return 1
    }

    var description: String {
        switch self {
        case .off: return "Выключено"
        case .disconnected: return "Нет подключения"
        case .connected(.unknown): return "Подключено"
        case .connected(.weak): return "Слабый сигнал"
        case .connected(.fair): return "Средний сигнал"
        case .connected(.strong): return "Сильный сигнал"
        }
    }

    var trayIcon: NSImage? {
        NSImage(systemSymbolName: symbol, variableValue: value, accessibilityDescription: description)
    }
}
