import XCTest
import PressureHapticsCore
import PressureHapticsTrackpad

final class PressureHapticsCoreComprehensiveTests: XCTestCase {
    func testCalibrationNormalizesAndClampsFiniteValues() {
        let calibration = PressureCalibration(restingPressure: 100, maximumPressure: 600)
        XCTAssertEqual(calibration.normalize(100), 0)
        XCTAssertEqual(calibration.normalize(350), 0.5, accuracy: 0.0001)
        XCTAssertEqual(calibration.normalize(0), 0)
        XCTAssertEqual(calibration.normalize(700), 1)
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
        XCTAssertThrowsError(try PressureHapticProfile(levels: [
            .init(lowerBound: 0.5, command: command), .init(lowerBound: 0.4, command: command)
        ]))

        let profile = try PressureHapticProfile(levels: [
            .init(lowerBound: 0.2, command: command),
            .init(lowerBound: 0.8, command: command),
        ])
        XCTAssertNil(profile.selection(for: 0.19))
        XCTAssertEqual(profile.selection(for: 0.2)?.index, 0)
        XCTAssertEqual(profile.selection(for: 1.5)?.index, 1)
        XCTAssertNil(profile.selection(for: .nan))
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
