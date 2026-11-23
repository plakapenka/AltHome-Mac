import SwiftUI

final class LowPowerControl: ObservableObject {
    static let shared = LowPowerControl()
    @Published private(set) var changing = false
    @Published private(set) var message: String?

    static func modeKey(in settings: String, onAC: Bool) -> String? {
        let heading = onAC ? "AC Power:" : "Battery Power:"
        var inProfile = false
        var keys = Set<String>()
        for line in settings.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix(":") {
                inProfile = text == heading
            } else if inProfile, let key = text.split(whereSeparator: { $0.isWhitespace }).first {
                keys.insert(String(key))
            }
        }
        return ["powermode", "lowpowermode"].first(where: keys.contains)
    }

    private static func output(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
        return String(decoding: data, as: UTF8.self)
    }

    func set(_ enabled: Bool, onAC: Bool) {
        guard !changing else { return }
        changing = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                let settings = try Self.output("/usr/bin/pmset", ["-g", "custom"])
                if let key = Self.modeKey(in: settings, onAC: onAC) {
                    let command = "/usr/bin/pmset \(onAC ? "-c" : "-b") \(key) \(enabled ? 1 : 0)"
                    let script = """
                    try
                        do shell script "\(command)" with prompt "TaskShelf меняет режим энергосбережения." with administrator privileges
                    on error number -128
                        return
                    end try
                    """
                    _ = try Self.output("/usr/bin/osascript", ["-e", script])
                } else {
                    failure = "Для этого источника питания режим недоступен."
                }
            } catch {
                failure = "Не удалось изменить режим. Проверьте настройки аккумулятора."
            }
            DispatchQueue.main.async {
                self.message = failure
                self.changing = false
            }
        }
    }
}

struct BatteryControls: View {
    let display: CGDirectDisplayID
    @ObservedObject private var control = LowPowerControl.shared
    @State private var status = BatteryStatus.current()
    @State private var energySaving = ProcessInfo.processInfo.isLowPowerModeEnabled

    private func refresh() {
        status = BatteryStatus.current()
        energySaving = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(status.fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 28, weight: .semibold)).monospacedDigit()
                        Spacer()
                        Text(status.onACPower ? "Питание от сети" : "От аккумулятора")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    ProgressView(value: status.fraction)
                        .tint(energySaving ? .yellow : .green)
                        .accessibilityHidden(true)
                }
                Divider()
                BrightnessControl(display: display)
                Toggle(isOn: Binding(
                    get: { energySaving },
                    set: { control.set($0, onAC: status.onACPower) }
                )) {
                    Label("Энергосбережение", systemImage: "leaf")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch).tint(.green)
                .environment(\.controlActiveState, .active)
                .disabled(control.changing)
                if let message = control.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Нет данных об аккумуляторе").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in refresh() }
    }
}
