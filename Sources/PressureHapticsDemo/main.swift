import SwiftUI
import AppKit
import PressureHapticsCore
import PressureHapticsTrackpad

@MainActor
final class DemoModel: ObservableObject {
    @Published var normalizedPressure: Float = 0
    private var rawPressure: Float = 0
    @Published var currentPressureDelta: Float?
    @Published var peakPressureDelta: Float?
    @Published var touchCount = 0
    @Published var lastLevel = "なし"
    @Published var lastResult = "なし"
    @Published var automaticHapticsEnabled = true
    @Published var isListening = false

    let haptics: TrackpadPressureHaptics
    let calibration: PressureCalibration
    private var pressureMeter = PressureWeightMeter()
    private var contactLossResetTask: Task<Void, Never>?

    init() {
        calibration = .init(restingPressure: 100, maximumPressure: 600)
        haptics = TrackpadPressureHaptics(calibration: calibration)
        haptics.onPressureSample = { [weak self] pressure, touchCount in
            guard let self else { return }
            self.touchCount = touchCount
            // A non-conductive object can remain on the trackpad after the
            // capacitive touch event disappears. Keep the last valid weight
            // instead of treating the missing touch event as zero weight.
            guard touchCount > 0 else {
                self.scheduleContactLossReset()
                return
            }
            self.contactLossResetTask?.cancel()
            self.contactLossResetTask = nil
            self.rawPressure = pressure
            self.normalizedPressure = self.calibration.normalize(pressure)
            self.currentPressureDelta = self.pressureMeter.update(rawPressure: pressure)
            self.peakPressureDelta = self.pressureMeter.peakGrams
        }
        haptics.onHapticTrigger = { [weak self] result in
            self?.lastLevel = "レベル \(result.level)"
            self?.lastResult = result.succeeded ? "成功" : "失敗"
        }
    }

    private func scheduleContactLossReset() {
        guard contactLossResetTask == nil else { return }
        contactLossResetTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            guard let self, self.touchCount == 0 else { return }
            self.pressureMeter.resetPeak()
            self.currentPressureDelta = 0
            self.peakPressureDelta = 0
            self.rawPressure = 0
            self.normalizedPressure = 0
            self.contactLossResetTask = nil
        }
    }

    func tare() {
        guard touchCount > 0 else { return }
        pressureMeter.tare(rawPressure: rawPressure)
        currentPressureDelta = 0
        peakPressureDelta = 0
    }

    func start() {
        haptics.isAutomaticHapticsEnabled = automaticHapticsEnabled
        isListening = haptics.start()
    }

    func stop() {
        haptics.stop()
        contactLossResetTask?.cancel()
        contactLossResetTask = nil
        isListening = false
    }

    func trigger(level: Int) {
        haptics.triggerHaptic(level: level)
    }
}

struct ContentView: View {
    @StateObject private var model = DemoModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PressureHapticsKit 実機デモ")
                .font(.title2)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow { Text("現在の圧力（正規化）"); Text(String(format: "%.3f", model.normalizedPressure)) }
                GridRow { Text("現在の圧力差相当"); Text(model.currentPressureDelta.map { String(format: "%.1f", $0) } ?? "未接触") }
                GridRow { Text("接触中の最大圧力差相当"); Text(model.peakPressureDelta.map { String(format: "%.1f", $0) } ?? "未接触") }
                GridRow { Text("接触数"); Text("\(model.touchCount)") }
                GridRow { Text("最後のレベル"); Text(model.lastLevel) }
                GridRow { Text("最後の結果"); Text(model.lastResult) }
                GridRow { Text("状態"); Text(model.isListening ? "監視中" : "停止") }
            }

            Toggle("自動ハプティックを有効にする", isOn: $model.automaticHapticsEnabled)
                .onChange(of: model.automaticHapticsEnabled) { enabled in
                    model.haptics.isAutomaticHapticsEnabled = enabled
                }

            HStack {
                Button(model.isListening ? "停止" : "監視開始") {
                    model.isListening ? model.stop() : model.start()
                }
                Button("開始") { model.tare() }
                    .disabled(model.touchCount == 0)
                ForEach(1...7, id: \.self) { level in
                    Button("L\(level)") { model.trigger(level: level) }
                }
            }

            Text("監視開始後、トラックパッドを押してください。初回はmacOSの入力監視権限が必要な場合があります。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(WindowConfigurator())
        .frame(
            minWidth: 520,
            idealWidth: 720,
            maxWidth: .infinity,
            minHeight: 320,
            idealHeight: 420,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView.window)
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width: 520, height: 320)
    }
}

@main
struct PressureHapticsDemoApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .defaultSize(width: 720, height: 420)
    }
}
