import SwiftUI

// DisplayServices controls the backlight on supported displays, including Apple Silicon laptops.
// Resolve both operations at runtime so a missing entry point only disables this control.
enum DisplayBrightness {
    private typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter = library.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: Getter.self) }
    private static let setter = library.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: Setter.self) }

    static func level(on display: CGDirectDisplayID) -> Double? {
        var value: Float = 0
        guard setter != nil, getter?(display, &value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
        return Double(value)
    }

    static func set(_ value: Double, on display: CGDirectDisplayID) -> Bool {
        (0...1).contains(value) && setter?(display, Float(value)) == 0
    }
}

struct BrightnessControl: View {
    let display: CGDirectDisplayID
    @State private var level: Double?
    @State private var editing = false
    @State private var failed = false

    init(display: CGDirectDisplayID) {
        self.display = display
        _level = State(initialValue: DisplayBrightness.level(on: display))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Яркость экрана", systemImage: "sun.max")
                Spacer()
                if let level {
                    Text(level, format: .percent.precision(.fractionLength(0)))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Slider(value: Binding(get: { level ?? 0 }, set: { value in
                failed = !DisplayBrightness.set(value, on: display)
                level = failed ? DisplayBrightness.level(on: display) : value
            }), in: 0...1, onEditingChanged: { editing = $0 })
                .controlSize(.large)
                .disabled(level == nil)
                .accessibilityLabel("Яркость экрана")
            if level == nil || failed {
                Text(level == nil ? "Этот дисплей не поддерживает регулировку яркости." : "Не удалось изменить яркость.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if !editing { level = DisplayBrightness.level(on: display) }
        }
    }
}
