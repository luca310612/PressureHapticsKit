import XCTest
import PressureHapticsCore

final class PressureHapticsCoreRegressionTests: XCTestCase {
    private let command = RawHapticCommand(
        actuationID: 3, rawParameter1: 0, rawParameter2: 1, rawParameter3: 2
    )

    func testInvalidPressureNeverEmitsWithZeroThreshold() throws {
        let profile = try PressureHapticProfile(levels: [.init(lowerBound: 0, command: command)])
        var controller = PressureHapticController(
            calibration: .init(restingPressure: 0, maximumPressure: 100), profile: profile
        )
        for pressure in [Float.nan, .infinity, -.infinity] {
            XCTAssertNil(controller.consume(pressure: pressure, isTouching: true, timestamp: 0))
        }
        XCTAssertNotNil(controller.consume(pressure: 0, isTouching: true, timestamp: 1))
    }

    func testInvalidPressureResetsWideHysteresisState() {
        var controller = PressureHapticController(
            calibration: .init(restingPressure: 0, maximumPressure: 100), levelHysteresis: 0.2
        )
        XCTAssertNotNil(controller.consume(pressure: 20, isTouching: true, timestamp: 0, rate: 10))
        XCTAssertNil(controller.consume(pressure: .nan, isTouching: true, timestamp: 1, rate: 10))
        XCTAssertNotNil(controller.consume(pressure: 20, isTouching: true, timestamp: 1.01))
    }

    func testInvalidCalibrationCannotEmitAtZeroThreshold() throws {
        let profile = try PressureHapticProfile(levels: [.init(lowerBound: 0, command: command)])
        for calibration in [
            PressureCalibration(restingPressure: 100, maximumPressure: 0),
            PressureCalibration(restingPressure: 100, maximumPressure: 100),
            PressureCalibration(restingPressure: .nan, maximumPressure: 100),
            PressureCalibration(restingPressure: 0, maximumPressure: .infinity),
        ] {
            var controller = PressureHapticController(calibration: calibration, profile: profile)
            XCTAssertNil(controller.consume(pressure: 50, isTouching: true, timestamp: 0))
        }
    }

    func testFullScaleLevelRemainsReachableWithHysteresis() throws {
        let profile = try PressureHapticProfile(levels: [
            .init(lowerBound: 2, command: command),
            .init(lowerBound: 10, command: command),
        ])
        var controller = PressureHapticController(
            calibration: .init(restingPressure: 0, maximumPressure: 100), profile: profile
        )
        XCTAssertEqual(controller.consume(pressure: 30, isTouching: true, timestamp: 0)?.levelIndex, 0)
        XCTAssertNil(controller.consume(pressure: 99, isTouching: true, timestamp: 1))
        XCTAssertEqual(controller.consume(pressure: 100, isTouching: true, timestamp: 2)?.levelIndex, 1)
        XCTAssertNil(controller.consume(pressure: 99, isTouching: true, timestamp: 3))
        XCTAssertEqual(controller.consume(pressure: 97, isTouching: true, timestamp: 4)?.levelIndex, 0)
    }

    func testClockRollbackSelectsWithoutOldHysteresis() {
        var controller = PressureHapticController(calibration: .init(restingPressure: 0, maximumPressure: 100))
        XCTAssertEqual(controller.consume(pressure: 40, isTouching: true, timestamp: 100)?.levelIndex, 2)
        XCTAssertEqual(controller.consume(pressure: 38, isTouching: true, timestamp: 0)?.levelIndex, 1)
    }

    func testExtremeFiniteCalibrationDoesNotOverflow() throws {
        let maximum = Float.greatestFiniteMagnitude
        let calibration = try PressureCalibration(
            validatingRestingPressure: -maximum,
            maximumPressure: maximum,
            massPoints: [.init(pressure: -maximum, grams: 0), .init(pressure: maximum, grams: 100)]
        )
        XCTAssertEqual(calibration.normalize(-maximum), 0)
        XCTAssertEqual(calibration.normalize(0), 5)
        XCTAssertEqual(calibration.normalize(maximum), 10)
        XCTAssertEqual(calibration.grams(for: 0), 50)
        let expected = Float((Double(1e38 as Float) + Double(maximum)) / (2 * Double(maximum)) * 100)
        XCTAssertEqual(try XCTUnwrap(calibration.grams(for: 1e38)), expected, accuracy: 0.001)
    }

    func testUnrepresentablePressureDeltaReturnsNil() {
        var meter = PressureWeightMeter(zeroOffset: -Float.greatestFiniteMagnitude)
        XCTAssertNil(meter.update(rawPressure: .greatestFiniteMagnitude))
        XCTAssertNil(meter.currentGrams)
        XCTAssertEqual(meter.peakGrams, 0)
        XCTAssertEqual(meter.update(rawPressure: 0), Float.greatestFiniteMagnitude)
    }

    func testValidatingCalibrationRejectsInvalidInputs() {
        XCTAssertThrowsError(
            try PressureCalibration(validatingRestingPressure: 100, maximumPressure: 100)
        ) { XCTAssertEqual($0 as? PressureCalibrationError, .invalidRange) }
        XCTAssertThrowsError(
            try PressureCalibration(validatingRestingPressure: 200, maximumPressure: 100)
        ) { XCTAssertEqual($0 as? PressureCalibrationError, .invalidRange) }
        XCTAssertThrowsError(
            try PressureCalibration(validatingRestingPressure: .nan, maximumPressure: 100)
        ) { XCTAssertEqual($0 as? PressureCalibrationError, .invalidRange) }
        XCTAssertThrowsError(
            try PressureCalibration(
                validatingRestingPressure: 0,
                maximumPressure: 100,
                massPoints: [.init(pressure: 10, grams: 5)]
            )
        ) { XCTAssertEqual($0 as? PressureCalibrationError, .insufficientMassPoints) }
        XCTAssertThrowsError(
            try PressureCalibration(
                validatingRestingPressure: 0,
                maximumPressure: 100,
                massPoints: [.init(pressure: 10, grams: -1), .init(pressure: 20, grams: 5)]
            )
        ) { XCTAssertEqual($0 as? PressureCalibrationError, .invalidMassPoint(index: 0)) }
        XCTAssertThrowsError(
            try PressureCalibration(
                validatingRestingPressure: 0,
                maximumPressure: 100,
                massPoints: [.init(pressure: 10, grams: .nan), .init(pressure: 20, grams: 5)]
            )
        ) { XCTAssertEqual($0 as? PressureCalibrationError, .invalidMassPoint(index: 0)) }
        XCTAssertThrowsError(
            try PressureCalibration(
                validatingRestingPressure: 0,
                maximumPressure: 100,
                massPoints: [.init(pressure: 20, grams: 5), .init(pressure: 10, grams: 5)]
            )
        ) { XCTAssertEqual($0 as? PressureCalibrationError, .massPointsMustBeAscending) }
        XCTAssertThrowsError(
            try PressureCalibration(
                validatingRestingPressure: 0,
                maximumPressure: 100,
                massPoints: [.init(pressure: 10, grams: 5), .init(pressure: 20, grams: 4)]
            )
        ) { XCTAssertEqual($0 as? PressureCalibrationError, .massPointsMustBeAscending) }
    }

    func testUnsortedMassPointsStillInterpolateMonotonically() {
        let calibration = PressureCalibration(
            restingPressure: 0,
            maximumPressure: 100,
            massPoints: [
                .init(pressure: 50, grams: 50),
                .init(pressure: 10, grams: 10),
            ]
        )
        XCTAssertEqual(calibration.grams(for: 10) ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(calibration.grams(for: 30) ?? -1, 30, accuracy: 0.001)
        XCTAssertEqual(calibration.grams(for: 50) ?? -1, 50, accuracy: 0.001)
        XCTAssertNil(
            PressureCalibration(
                restingPressure: 0,
                maximumPressure: 100,
                massPoints: [
                    .init(pressure: 10, grams: 10),
                    .init(pressure: 20, grams: .nan),
                ]
            ).grams(for: 15)
        )
    }
}
