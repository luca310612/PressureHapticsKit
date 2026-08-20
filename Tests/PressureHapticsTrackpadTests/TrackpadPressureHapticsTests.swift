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

        XCTAssertEqual(recorder.commands, [
            RawHapticCommand(
                actuationID: 4,
                rawParameter1: 0,
                rawParameter2: 1.25,
                rawParameter3: 2
            ),
        ])
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
        let didRepeat = await waitForCommandCount(3, recorder: recorder)
        haptics.stopHaptic()

        XCTAssertTrue(didRepeat)
    }

    func testStopHapticPreventsFurtherRepeats() async {
        let recorder = HapticTriggerRecorder()
        let haptics = makeHaptics(recorder: recorder)
        haptics.rate = 100
        haptics.startHaptic(level: 4)
        let didRepeat = await waitForCommandCount(2, recorder: recorder)
        XCTAssertTrue(didRepeat)

        haptics.stopHaptic()
        let countAfterStop = recorder.commands.count
        // Five 10-millisecond intervals prove the stopped task stays silent.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(recorder.commands.count, countAfterStop)
    }

    func testStopPreventsFurtherDirectRepeats() async {
        let recorder = HapticTriggerRecorder()
        let haptics = makeHaptics(recorder: recorder)
        haptics.rate = 100
        haptics.startHaptic(level: 4)
        let didRepeat = await waitForCommandCount(2, recorder: recorder)
        XCTAssertTrue(didRepeat)

        haptics.stop()
        let countAfterStop = recorder.commands.count
        // Five 10-millisecond intervals prove stop() also cancels direct repeat.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(recorder.commands.count, countAfterStop)
    }

    func testDeinitPreventsFurtherDirectRepeats() async {
        let recorder = HapticTriggerRecorder()
        var haptics: TrackpadPressureHaptics? = makeHaptics(recorder: recorder)
        weak let weakHaptics = haptics
        haptics?.rate = 100
        haptics?.startHaptic(level: 4)
        let didRepeat = await waitForCommandCount(2, recorder: recorder)
        XCTAssertTrue(didRepeat)

        haptics = nil
        let countAfterDeinit = recorder.commands.count
        // Five 10-millisecond intervals prove deinit cancels the owned task.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(weakHaptics)
        XCTAssertEqual(recorder.commands.count, countAfterDeinit)
    }

    func testSynchronousTriggerCallbackCanStopBeforeRepeatStarts() async {
        let recorder = HapticTriggerRecorder()
        let haptics = makeHaptics(recorder: recorder)
        haptics.rate = 100
        haptics.onHapticTrigger = { [weak haptics] _ in
            haptics?.stopHaptic()
        }

        haptics.startHaptic(level: 4)
        // Five 10-millisecond intervals expose a task created after the callback.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(recorder.commands.count, 1)
    }

    func testNestedStartOwnsTheOnlyRepeatingTask() async {
        let recorder = HapticTriggerRecorder()
        let haptics = makeHaptics(recorder: recorder)
        haptics.rate = 100
        var didStartNestedHaptic = false
        haptics.onHapticTrigger = { [weak haptics] _ in
            guard !didStartNestedHaptic else { return }
            didStartNestedHaptic = true
            haptics?.startHaptic(level: 2)
        }

        haptics.startHaptic(level: 4)
        let didRepeat = await waitForCommandCount(4, recorder: recorder)
        XCTAssertTrue(didRepeat)
        haptics.stopHaptic()
        let countAfterStop = recorder.commands.count
        // Five 10-millisecond intervals expose an unowned nested repeat task.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(recorder.commands.count, countAfterStop)
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

    func testLeastPositiveFiniteRateSaturatesRepeatDelay() {
        XCTAssertEqual(
            TrackpadPressureHaptics.repeatDelayNanoseconds(
                for: Double.leastNonzeroMagnitude
            ),
            UInt64.max
        )
    }

    func testGreatestPositiveFiniteRateKeepsRepeatDelayNonzero() {
        XCTAssertEqual(
            TrackpadPressureHaptics.repeatDelayNanoseconds(
                for: Double.greatestFiniteMagnitude
            ),
            1
        )
    }

    func testPressureAttemptForwardsSelectionAndNotifiesResult() {
        let recorder = HapticTriggerRecorder()
        let haptics = makeHaptics(recorder: recorder)
        haptics.selectionStrategy = .average
        var results: [HapticTriggerResult] = []
        var sampledMaximumPressure: Float?
        var sampledActiveTouchCount: Int?
        haptics.onHapticTrigger = { results.append($0) }
        haptics.onPressureSample = { maximumPressure, activeTouchCount in
            sampledMaximumPressure = maximumPressure
            sampledActiveTouchCount = activeTouchCount
        }

        haptics.consume([
            makeTouch(id: 1, pressure: 200),
            makeTouch(id: 2, pressure: 500),
        ], timestamp: 0)

        XCTAssertEqual(recorder.commands, [
            RawHapticCommand(
                actuationID: 4,
                rawParameter1: 0,
                rawParameter2: 1,
                rawParameter3: 2
            ),
        ])
        XCTAssertEqual(results.map(\.level), [3])
        XCTAssertEqual(results.map(\.succeeded), [true])
        XCTAssertEqual(sampledMaximumPressure, 500)
        XCTAssertEqual(sampledActiveTouchCount, 2)
    }

    func testPressureAttemptReportsTriggerFailure() {
        let recorder = HapticTriggerRecorder()
        recorder.result = false
        let haptics = makeHaptics(recorder: recorder)
        var result: HapticTriggerResult?
        haptics.onHapticTrigger = { result = $0 }

        haptics.consume([
            makeTouch(id: 1, pressure: 350),
        ], timestamp: 0)

        XCTAssertEqual(recorder.commands.count, 1)
        XCTAssertEqual(result?.level, 3)
        XCTAssertEqual(result?.succeeded, false)
    }

    func testPressureAttemptForwardsRateToFrameProcessor() {
        let recorder = HapticTriggerRecorder()
        let haptics = makeHaptics(recorder: recorder)
        haptics.rate = 20
        var reportedLevels: [Int] = []
        haptics.onHapticTrigger = { reportedLevels.append($0.level) }
        let touch = makeTouch(id: 1, pressure: 350)

        haptics.consume([touch], timestamp: 0)
        haptics.consume([touch], timestamp: 0.01)
        haptics.consume([touch], timestamp: 0.06)

        XCTAssertEqual(recorder.commands.count, 2)
        XCTAssertEqual(reportedLevels, [3, 3])
    }

    private func makeHaptics(
        recorder: HapticTriggerRecorder
    ) -> TrackpadPressureHaptics {
        TrackpadPressureHaptics(
            calibration: .init(restingPressure: 100, maximumPressure: 600),
            hapticTrigger: recorder.trigger
        )
    }

    private func makeTouch(
        id: Int32,
        pressure: Float
    ) -> TrackpadTouchSample {
        TrackpadTouchSample(
            id: id,
            position: SIMD2(0.5, 0.5),
            pressure: pressure,
            phase: .touching
        )
    }

    private func waitForCommandCount(
        _ count: Int,
        recorder: HapticTriggerRecorder
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))

        while recorder.commands.count < count, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        return recorder.commands.count >= count
    }
}
