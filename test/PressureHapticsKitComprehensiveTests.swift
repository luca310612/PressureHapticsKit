import XCTest
import PressureHapticsCore
@testable import PressureHapticsTrackpad

final class PressureHapticsCoreComprehensiveTests: XCTestCase {
    func testCalibrationNormalizesAndClampsFiniteValues() {
        let calibration = PressureCalibration(restingPressure: 100, maximumPressure: 600)
        XCTAssertEqual(calibration.normalize(100), 0)
        XCTAssertEqual(calibration.normalize(350), 5, accuracy: 0.0001)
        XCTAssertEqual(calibration.normalize(0), 0)
        XCTAssertEqual(calibration.normalize(700), 10)
        XCTAssertEqual(calibration.normalize(.nan), 0)
        XCTAssertEqual(calibration.normalize(.infinity), 0)
    }

    func testInvalidCalibrationProducesZero() {
        XCTAssertEqual(PressureCalibration(restingPressure: 600, maximumPressure: 100).normalize(350), 0)
        XCTAssertEqual(PressureCalibration(restingPressure: .nan, maximumPressure: 600).normalize(350), 0)
    }

    func testMassCalibrationInterpolatesInGramsAndClamps() {    
        let calibration = PressureCalibration(
            restingPressure: 100,
            maximumPressure: 600,
            massPoints: [
                .init(pressure: 100, grams: 0),
                .init(pressure: 300, grams: 400),
                .init(pressure: 600, grams: 1000),
            ]
        )
        XCTAssertEqual(calibration.grams(for: 50), 0)
        XCTAssertEqual(calibration.grams(for: 200) ?? -1, 200, accuracy: 0.001)
        XCTAssertEqual(calibration.grams(for: 450) ?? -1, 700, accuracy: 0.001)
        XCTAssertEqual(calibration.grams(for: 700) ?? -1, 1000, accuracy: 0.001)
        XCTAssertNil(PressureCalibration(restingPressure: 0, maximumPressure: 1).grams(for: 0.5))
    }

    func testPressureWeightMeterUsesTareOffset() {
        var meter = PressureWeightMeter()
        XCTAssertNil(meter.grams(for: 500))
        meter.tare(rawPressure: 350)
        XCTAssertEqual(meter.grams(for: 350), 0)
        XCTAssertEqual(meter.grams(for: 420), 70)
        XCTAssertEqual(meter.grams(for: 300), 0)
        meter.resetTare()
        XCTAssertNil(meter.grams(for: 420))
    }

    func testPressureWeightMeterResetsPeakWhenObjectIsRemoved() {
        var meter = PressureWeightMeter(resetThresholdGrams: 2)
        meter.tare(rawPressure: 100)

        XCTAssertEqual(meter.update(rawPressure: 150), 50)
        XCTAssertEqual(meter.peakGrams, 50)

        XCTAssertEqual(meter.update(rawPressure: 101), 1)
        XCTAssertEqual(meter.currentGrams, 1)
        XCTAssertEqual(meter.peakGrams, 0)
    }

    func testPressureWeightMeterCanResetPeakWithoutResettingTare() {
        var meter = PressureWeightMeter()
        meter.tare(rawPressure: 100)
        _ = meter.update(rawPressure: 150)
        meter.resetPeak()

        XCTAssertEqual(meter.peakGrams, 0)
        XCTAssertEqual(meter.grams(for: 150), 50)
        XCTAssertEqual(meter.zeroOffset, 100)
    }

    func testTareResetsCurrentAndPeakWhileKeepingNewZeroOffset() {
        var meter = PressureWeightMeter()
        meter.tare(rawPressure: 100)
        _ = meter.update(rawPressure: 180)
        XCTAssertEqual(meter.peakGrams, 80)

        meter.tare(rawPressure: 180)

        XCTAssertEqual(meter.currentGrams, 0)
        XCTAssertEqual(meter.peakGrams, 0)
        XCTAssertEqual(meter.zeroOffset, 180)
        XCTAssertEqual(meter.grams(for: 200), 20)
    }

    func testProfileValidationAndSelectionBoundaries() throws {
        let command = RawHapticCommand(actuationID: 1, rawParameter1: 2, rawParameter2: 3, rawParameter3: 4)
        XCTAssertThrowsError(try PressureHapticProfile(levels: [])) { XCTAssertEqual($0 as? PressureHapticProfileError, .emptyLevels) }
        XCTAssertThrowsError(try PressureHapticProfile(levels: [.init(lowerBound: -0.1, command: command)]))
        XCTAssertThrowsError(try PressureHapticProfile(levels: [.init(lowerBound: .infinity, command: command)]))
        XCTAssertThrowsError(try PressureHapticProfile(levels: [.init(lowerBound: 10.1, command: command)]))
        XCTAssertThrowsError(try PressureHapticProfile(levels: [
            .init(lowerBound: 5, command: command), .init(lowerBound: 4, command: command)
        ]))

        let profile = try PressureHapticProfile(levels: [
            .init(lowerBound: 2, command: command),
            .init(lowerBound: 8, command: command),
        ])
        XCTAssertNil(profile.selection(for: 1.9))
        XCTAssertEqual(profile.selection(for: 2)?.index, 0)
        XCTAssertEqual(profile.selection(for: 9)?.index, 1)
        XCTAssertNil(profile.selection(for: .nan))
    }

    func testConfigurableProfilesFollowTheNormalizedScale() throws {
        let linear = try PressureHapticProfile.linear(levelCount: 5)
        let expectedThresholds: [Float] = [1.5, 3.2, 4.9, 6.6, 8.3]
        for (threshold, expected) in zip(linear.levels.map(\.lowerBound), expectedThresholds) {
            XCTAssertEqual(threshold, expected, accuracy: 0.0001)
        }
        XCTAssertEqual(linear.levels.map(\.command.actuationID), [3, 3, 4, 4, 6])
        XCTAssertEqual(linear.levels.first?.command.rawParameter2 ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(linear.levels.last?.command.rawParameter2 ?? -1, 2.0, accuracy: 0.0001)

        XCTAssertThrowsError(try PressureHapticProfile.linear(levelCount: 0)) {
            XCTAssertEqual($0 as? PressureHapticProfileError, .invalidLevelCount(0))
        }
        XCTAssertThrowsError(try PressureHapticProfile.linear(levelCount: 5, firstThreshold: 11)) {
            XCTAssertEqual($0 as? PressureHapticProfileError, .invalidLowerBound(index: 0))
        }
        XCTAssertThrowsError(try PressureHapticProfile.custom(
            thresholds: [2, 5], intensities: [0.75, 0.5]
        )) {
            XCTAssertEqual($0 as? PressureHapticProfileError, .intensitiesMustBeAscending)
        }
        XCTAssertThrowsError(try PressureHapticProfile.custom(
            thresholds: [2, 5], intensities: [0.75]
        )) {
            XCTAssertEqual($0 as? PressureHapticProfileError, .mismatchedLevelArrays)
        }
        XCTAssertThrowsError(try PressureHapticProfile.custom(
            thresholds: [5, 2], intensities: [0.75, 1.5]
        )) {
            XCTAssertEqual($0 as? PressureHapticProfileError, .levelsMustBeStrictlyAscending)
        }

        let custom = try PressureHapticProfile.custom(
            thresholds: [2, 5],
            intensities: [0.75, 1.5],
            actuationIDs: [4, 6]
        )
        XCTAssertNil(custom.selection(for: 1.9))
        XCTAssertEqual(custom.selection(for: 2)?.index, 0)
        XCTAssertEqual(custom.levels[1].command.actuationID, 6)
    }

    func testControllerEmitsOnFirstLevelChangeAndRateInterval() {
        var controller = PressureHapticController(calibration: .init(restingPressure: 0, maximumPressure: 100))
        XCTAssertNotNil(controller.consume(pressure: 20, isTouching: true, timestamp: 0, rate: 10))
        XCTAssertNil(controller.consume(pressure: 20, isTouching: true, timestamp: 0.09, rate: 10))
        XCTAssertNotNil(controller.consume(pressure: 20, isTouching: true, timestamp: 0.1, rate: 10))
        XCTAssertNotNil(controller.consume(pressure: 50, isTouching: true, timestamp: 0.11))
        XCTAssertNil(controller.consume(pressure: .nan, isTouching: true, timestamp: 0.12))
        XCTAssertNotNil(controller.consume(pressure: 50, isTouching: true, timestamp: 0.13))
        XCTAssertNil(controller.consume(pressure: 50, isTouching: false, timestamp: 0.14))
    }

    func testHysteresisSelectionRequiresMarginsOnBothSides() throws {
        let command = RawHapticCommand(actuationID: 1, rawParameter1: 0, rawParameter2: 1, rawParameter3: 2)
        let profile = try PressureHapticProfile(levels: [
            .init(lowerBound: 2, command: command),
            .init(lowerBound: 6, command: command),
        ])
        let hysteresis: Float = 0.5

        // Advancing needs the threshold plus the margin.
        XCTAssertEqual(profile.selection(for: 6.4, previousIndex: 0, hysteresis: hysteresis)?.index, 0)
        XCTAssertEqual(profile.selection(for: 6.5, previousIndex: 0, hysteresis: hysteresis)?.index, 1)
        // Descending needs to fall below the boundary minus the margin.
        XCTAssertEqual(profile.selection(for: 5.6, previousIndex: 1, hysteresis: hysteresis)?.index, 1)
        XCTAssertEqual(profile.selection(for: 5.4, previousIndex: 1, hysteresis: hysteresis)?.index, 0)
        XCTAssertNil(profile.selection(for: 1.4, previousIndex: 0, hysteresis: hysteresis))
        XCTAssertEqual(profile.selection(for: 1.5, previousIndex: 0, hysteresis: hysteresis)?.index, 0)
    }

    func testHysteresisSelectionRejectsInvalidHysteresis() throws {
        let command = RawHapticCommand(actuationID: 1, rawParameter1: 0, rawParameter2: 1, rawParameter3: 2)
        let profile = try PressureHapticProfile(levels: [.init(lowerBound: 2, command: command)])
        for hysteresis in [Float(-0.1), .nan, -.infinity, .infinity] {
            XCTAssertNil(profile.selection(for: 5, previousIndex: nil, hysteresis: hysteresis))
        }
    }

    func testHysteresisSelectionFallsBackWithoutValidPreviousIndex() throws {
        let command = RawHapticCommand(actuationID: 1, rawParameter1: 0, rawParameter2: 1, rawParameter3: 2)
        let profile = try PressureHapticProfile(levels: [
            .init(lowerBound: 2, command: command),
            .init(lowerBound: 6, command: command),
        ])
        XCTAssertEqual(profile.selection(for: 6, previousIndex: nil, hysteresis: 0.5)?.index, 1)
        XCTAssertEqual(profile.selection(for: 6, previousIndex: 9, hysteresis: 0.5)?.index, 1)
    }

    func testHysteresisSelectionClampsAdvancementToFullScale() throws {
        let command = RawHapticCommand(actuationID: 1, rawParameter1: 0, rawParameter2: 1, rawParameter3: 2)
        let profile = try PressureHapticProfile(levels: [
            .init(lowerBound: 1, command: command),
            .init(lowerBound: 9.9, command: command),
        ])
        // min(maximum, 9.9 + 0.5) clamps the entry gate to exactly 10, so the
        // top level stays reachable even when threshold plus margin exceeds it.
        XCTAssertEqual(profile.selection(for: 9.8, previousIndex: 0, hysteresis: 0.5)?.index, 0)
        XCTAssertEqual(profile.selection(for: 10, previousIndex: 0, hysteresis: 0.5)?.index, 1)
        // Out-of-range input pressure clamps onto the shared scale first.
        XCTAssertEqual(profile.selection(for: 50, previousIndex: 0, hysteresis: 0.5)?.index, 1)
    }

    func testLinearProfileSupportsExplicitRangesAndActuationIDs() throws {
        let linear = try PressureHapticProfile.linear(
            levelCount: 2,
            firstThreshold: 2,
            intensityRange: 1.0...3.0,
            actuationIDs: [4, 6]
        )
        XCTAssertEqual(linear.levels.map(\.lowerBound), [2, 6])
        XCTAssertEqual(linear.levels.map(\.command.actuationID), [4, 6])
        XCTAssertEqual(linear.levels.map(\.command.rawParameter2), [1, 3])

        XCTAssertThrowsError(try PressureHapticProfile.linear(levelCount: 2, actuationIDs: [4])) {
            XCTAssertEqual($0 as? PressureHapticProfileError, .mismatchedLevelArrays)
        }
    }

    func testCustomProfileRejectsEmptyAndNonfiniteInput() {
        XCTAssertThrowsError(try PressureHapticProfile.custom(thresholds: [], intensities: [])) {
            XCTAssertEqual($0 as? PressureHapticProfileError, .emptyLevels)
        }
        XCTAssertThrowsError(try PressureHapticProfile.custom(thresholds: [2], intensities: [.nan])) {
            XCTAssertEqual($0 as? PressureHapticProfileError, .invalidCommand(index: 0))
        }
        XCTAssertThrowsError(try PressureHapticProfile.custom(thresholds: [2], intensities: [.infinity])) {
            XCTAssertEqual($0 as? PressureHapticProfileError, .invalidCommand(index: 0))
        }
    }

    func testLevelsInitRejectsNonfiniteCommandParameters() {
        for invalidCommand in [
            RawHapticCommand(actuationID: 1, rawParameter1: 0, rawParameter2: .nan, rawParameter3: 2),
            RawHapticCommand(actuationID: 1, rawParameter1: 0, rawParameter2: 1, rawParameter3: .infinity),
        ] {
            XCTAssertThrowsError(try PressureHapticProfile(levels: [
                .init(lowerBound: 2, command: invalidCommand),
            ])) {
                XCTAssertEqual($0 as? PressureHapticProfileError, .invalidCommand(index: 0))
            }
        }
    }

    func testReplaceProfileReemitsAtTheSameLevelWithRateZero() {
        var controller = PressureHapticController(calibration: .init(restingPressure: 0, maximumPressure: 100))
        XCTAssertNotNil(controller.consume(pressure: 50, isTouching: true, timestamp: 0))
        // Same level at rate zero stays silent.
        XCTAssertNil(controller.consume(pressure: 50, isTouching: true, timestamp: 1))

        controller.replaceProfile(.sevenStage)

        // Replacement clears selection state, so the same level emits again.
        XCTAssertNotNil(controller.consume(pressure: 50, isTouching: true, timestamp: 2))
    }

    func testNonfiniteTimestampResetsEmissionState() {
        var controller = PressureHapticController(calibration: .init(restingPressure: 0, maximumPressure: 100))
        XCTAssertNotNil(controller.consume(pressure: 50, isTouching: true, timestamp: 0, rate: 10))
        XCTAssertNil(controller.consume(pressure: 50, isTouching: true, timestamp: .nan, rate: 10))
        // The invalid timestamp clears state, so the next frame emits again.
        XCTAssertNotNil(controller.consume(pressure: 50, isTouching: true, timestamp: 2))
    }

    func testInvalidRatesBehaveLikeRateZero() {
        var controller = PressureHapticController(calibration: .init(restingPressure: 0, maximumPressure: 100))
        XCTAssertNotNil(controller.consume(pressure: 50, isTouching: true, timestamp: 0))
        for rate in [Double(-5), .nan, .infinity] {
            XCTAssertNil(controller.consume(pressure: 50, isTouching: true, timestamp: 1, rate: rate))
            XCTAssertNil(controller.consume(pressure: 50, isTouching: true, timestamp: 2, rate: rate))
        }
    }
}

final class PressureHapticsTrackpadComprehensiveTests: XCTestCase {
    func testAllTouchPhasesAreClassified() {
        XCTAssertEqual(TrackpadTouchPhase.allCases.count, 8)
        XCTAssertFalse(TrackpadTouchPhase.notTouching.isTouching)
        XCTAssertFalse(TrackpadTouchPhase.leaving.isTouching)
        for phase in [TrackpadTouchPhase.starting, .hovering, .making, .touching, .breaking, .lingering] {
            XCTAssertTrue(phase.isTouching)
        }
    }

    func testTouchSampleDefaultsAndEquality() {
        let sample = TrackpadTouchSample(id: 1, position: .zero, pressure: 10, phase: .touching)
        XCTAssertEqual(sample.total, 0)
        XCTAssertEqual(sample.axis, .zero)
        XCTAssertEqual(sample.timestamp, "")
        XCTAssertEqual(sample, TrackpadTouchSample(id: 1, position: .zero, pressure: 10, phase: .touching))
    }

    func testFrameProcessorSupportsAllSelectionStrategies() throws {
        let touches = [
            TrackpadTouchSample(id: 1, position: .zero, pressure: 200, phase: .touching),
            TrackpadTouchSample(id: 2, position: .zero, pressure: 500, phase: .touching),
        ]
        let calibration = PressureCalibration(restingPressure: 100, maximumPressure: 600)
        for strategy in [PressureSelectionStrategy.maximum, .average, .touch(id: 1), .firstTouch] {
            var processor = PressureFrameProcessor(calibration: calibration)
            let result = processor.consume(touches, timestamp: 0, selectionStrategy: strategy)
            XCTAssertEqual(result.activeTouchCount, 2)
            XCTAssertNotNil(result.emission)
        }
        var processor = PressureFrameProcessor(calibration: calibration)
        XCTAssertNil(processor.consume(touches, timestamp: 0, selectionStrategy: .touch(id: 99)).emission)
        XCTAssertEqual(processor.consume([touches[0], TrackpadTouchSample(id: 3, position: .zero, pressure: 900, phase: .leaving)], timestamp: 1).maximumPressure, 200)
    }

    func testFrameResultExposesCurrentSelectedPressure() {
        var processor = PressureFrameProcessor(
            calibration: .init(restingPressure: 0, maximumPressure: 100)
        )
        let result = processor.consume([
            .init(id: 1, position: .zero, pressure: 20, phase: .touching),
            .init(id: 2, position: .zero, pressure: 80, phase: .touching),
        ], timestamp: 0, selectionStrategy: .average)
        XCTAssertEqual(result.currentPressure ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(result.maximumPressure, 80, accuracy: 0.001)
    }
}

@MainActor
final class PressureHapticsRuntimeProfileTests: XCTestCase {
    func testRuntimeProfileReplacementClearsSelectionState() {
        let haptics = TrackpadPressureHaptics(
            calibration: .init(restingPressure: 100, maximumPressure: 600),
            hapticTrigger: { _ in true }
        )
        var reportedLevels: [Int] = []
        haptics.onHapticTrigger = { reportedLevels.append($0.level) }

        haptics.consume(
            [TrackpadTouchSample(id: 1, position: .zero, pressure: 500, phase: .touching)],
            timestamp: 0
        )
        XCTAssertEqual(reportedLevels, [6])

        haptics.profile = (try? PressureHapticProfile.linear(levelCount: 3))
            ?? haptics.profile

        haptics.consume(
            [TrackpadTouchSample(id: 1, position: .zero, pressure: 500, phase: .touching)],
            timestamp: 1
        )
        XCTAssertEqual(reportedLevels, [6, 3])
    }
}
