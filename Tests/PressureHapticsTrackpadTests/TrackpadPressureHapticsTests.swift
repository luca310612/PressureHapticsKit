import PressureHapticsCore
import XCTest
@testable import PressureHapticsTrackpad

@MainActor
private final class HapticTriggerRecorder {
    var commands: [RawHapticCommand] = []
    var result = true

    func trigger(_ command: RawHapticCommand) -> Bool {
        commands.append(command)
        return result
    }
}

@MainActor
final class TrackpadPressureHapticsTests: XCTestCase {
    func testDirectLevelReportsSuccess() {
        let recorder = HapticTriggerRecorder()
        let haptics = makeHaptics(recorder: recorder)
        var result: HapticTriggerResult?
        haptics.onHapticTrigger = { result = $0 }

        haptics.triggerHaptic(level: 4)

        XCTAssertEqual(recorder.commands.count, 1)
        XCTAssertEqual(result?.level, 4)
        XCTAssertEqual(result?.succeeded, true)
    }

    func testDirectLevelReportsRejection() {
        let recorder = HapticTriggerRecorder()
        recorder.result = false
        let haptics = makeHaptics(recorder: recorder)
        var result: HapticTriggerResult?
        haptics.onHapticTrigger = { result = $0 }

        haptics.triggerHaptic(level: 4)

        XCTAssertEqual(recorder.commands.count, 1)
        XCTAssertEqual(result?.level, 4)
        XCTAssertEqual(result?.succeeded, false)
    }

    func testInvalidDirectLevelReportsFailureWithoutTriggering() {
        let recorder = HapticTriggerRecorder()
        let haptics = makeHaptics(recorder: recorder)
        var result: HapticTriggerResult?
        haptics.onHapticTrigger = { result = $0 }

        haptics.triggerHaptic(level: 8)

        XCTAssertTrue(recorder.commands.isEmpty)
        XCTAssertEqual(result?.level, 8)
        XCTAssertEqual(result?.succeeded, false)
    }

    func testStartHapticTriggersImmediatelyAndRepeatsAtConfiguredRate() async {
        let recorder = HapticTriggerRecorder()
        let haptics = makeHaptics(recorder: recorder)
        haptics.rate = 20

        haptics.startHaptic(level: 4)
        try? await Task.sleep(for: .milliseconds(160))
        haptics.stopHaptic()

        XCTAssertGreaterThanOrEqual(recorder.commands.count, 3)
    }

    func testRateRejectsNegativeAndNonfiniteAssignments() {
        let recorder = HapticTriggerRecorder()
        let haptics = makeHaptics(recorder: recorder)
        haptics.rate = 20

        haptics.rate = -1
        XCTAssertEqual(haptics.rate, 20)

        haptics.rate = .infinity
        XCTAssertEqual(haptics.rate, 20)

        haptics.rate = .nan
        XCTAssertEqual(haptics.rate, 20)
    }

    private func makeHaptics(
        recorder: HapticTriggerRecorder
    ) -> TrackpadPressureHaptics {
        TrackpadPressureHaptics(
            calibration: .init(restingPressure: 100, maximumPressure: 600),
            hapticTrigger: recorder.trigger
        )
    }
}
