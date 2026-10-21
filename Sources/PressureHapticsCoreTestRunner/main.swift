import PressureHapticsCore

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

private func expectClose(
    _ actual: Float,
    _ expected: Float,
    accuracy: Float = 0.000_1
) {
    expect(
        abs(actual - expected) <= accuracy,
        "Expected \(expected), got \(actual)"
    )
}

private func unwrap<T>(_ value: T?, _ message: String) -> T {
    guard let value else {
        fatalError(message)
    }
    return value
}

private func verifyCalibration() {
    let calibration = PressureCalibration(
        restingPressure: 100,
        maximumPressure: 600
    )

    expectClose(calibration.normalize(0), 0)
    expectClose(calibration.normalize(100), 0)
    expectClose(calibration.normalize(350), 5)
    expectClose(calibration.normalize(600), 10)
    expectClose(calibration.normalize(700), 10)
    expectClose(calibration.normalize(.nan), 0)
}

private func verifySevenStageProfile() {
    let profile = PressureHapticProfile.sevenStage
    let samples: [(Float, Int, Int32, Float)] = [
        (1.5, 0, 3, 0.50),
        (2.8, 1, 3, 0.75),
        (4.0, 2, 4, 1.00),
        (5.2, 3, 4, 1.25),
        (6.4, 4, 4, 1.50),
        (7.6, 5, 6, 1.75),
        (8.8, 6, 6, 2.00),
    ]

    for (pressure, expectedIndex, expectedID, expectedParameter2) in samples {
        let selection = unwrap(
            profile.selection(for: pressure),
            "Expected level for pressure \(pressure)"
        )
        expect(selection.index == expectedIndex, "Unexpected level index")
        expect(
            selection.level.command.actuationID == expectedID,
            "Unexpected actuation ID"
        )
        expect(
            selection.level.command.rawParameter1 == 0,
            "Unexpected raw parameter 1"
        )
        expectClose(
            selection.level.command.rawParameter2,
            expectedParameter2
        )
        expectClose(selection.level.command.rawParameter3, 2)
    }

    expect(
        profile.selection(for: 1.49) == nil,
        "Pressure below the first boundary must not select a level"
    )
}

private func verifyConfigurableProfiles() {
    do {
        let linear = try PressureHapticProfile.linear(levelCount: 5)
        let thresholds = linear.levels.map(\.lowerBound)
        let expectedThresholds: [Float] = [1.5, 3.2, 4.9, 6.6, 8.3]
        for (threshold, expected) in zip(thresholds, expectedThresholds) {
            expectClose(threshold, expected)
        }
        expectClose(
            linear.levels.map(\.command.rawParameter2).first ?? 0,
            0.5
        )
        expectClose(
            linear.levels.map(\.command.rawParameter2).last ?? 0,
            2.0
        )
        expect(
            linear.levels.map(\.command.actuationID) == [3, 3, 4, 4, 6],
            "Intensities must map onto built-in actuation strengths"
        )

        let single = try PressureHapticProfile.linear(levelCount: 1)
        expect(single.levels.count == 1, "Expected a single level")
        expectClose(single.levels[0].lowerBound, 1.5)
        expectClose(single.levels[0].command.rawParameter2, 2.0)

        let configured = try PressureHapticProfile.linear(
            levelCount: 3,
            intensityRange: 0.5...1.0,
            actuationIDs: [3, 4, 6]
        )
        expect(
            configured.levels.map(\.command.actuationID) == [3, 4, 6],
            "Explicit actuation IDs must be applied verbatim"
        )
        expectClose(
            configured.levels[2].command.rawParameter2,
            1.0
        )

        let borders = try PressureHapticProfile.custom(
            thresholds: [2, 5],
            intensities: [0.75, 1.5]
        )
        expect(
            borders.selection(for: 1.9) == nil
                && borders.selection(for: 2)?.index == 0
                && borders.selection(for: 5)?.index == 1,
            "Custom thresholds must follow the 0–10 scale"
        )

        do {
            _ = try PressureHapticProfile.linear(levelCount: 0)
            fatalError("Expected a non-positive level count to be rejected")
        } catch let error as PressureHapticProfileError {
            expect(
                error == .invalidLevelCount(0),
                "Unexpected level count error"
            )
        }

        do {
            _ = try PressureHapticProfile.linear(
                levelCount: 5,
                firstThreshold: 11
            )
            fatalError("Expected an out-of-range first threshold to be rejected")
        } catch let error as PressureHapticProfileError {
            expect(
                error == .invalidLowerBound(index: 0),
                "Unexpected first threshold error"
            )
        }

        do {
            _ = try PressureHapticProfile.linear(
                levelCount: 2,
                firstThreshold: PressureNormalization.maximum
            )
            fatalError(
                "Expected a first threshold at full pressure to be rejected"
            )
        } catch let error as PressureHapticProfileError {
            expect(
                error == .firstThresholdMustBeBelowMaximum,
                "Unexpected first threshold at maximum error"
            )
        }

        let singleAtMaximum = try PressureHapticProfile.linear(
            levelCount: 1,
            firstThreshold: PressureNormalization.maximum
        )
        expectClose(
            singleAtMaximum.levels[0].lowerBound,
            PressureNormalization.maximum
        )

        do {
            _ = try PressureHapticProfile.custom(
                thresholds: [2, 5],
                intensities: [0.75, 0.5]
            )
            fatalError("Expected descending intensities to be rejected")
        } catch let error as PressureHapticProfileError {
            expect(
                error == .intensitiesMustBeAscending,
                "Unexpected intensity ordering error"
            )
        }

        do {
            _ = try PressureHapticProfile.custom(
                thresholds: [2, 5],
                intensities: [0.75]
            )
            fatalError("Expected mismatched arrays to be rejected")
        } catch let error as PressureHapticProfileError {
            expect(
                error == .mismatchedLevelArrays,
                "Unexpected array mismatch error"
            )
        }
    } catch {
        fatalError("Unexpected profile construction failure: \(error)")
    }
}

private func verifyProfileValidation() {
    let command = RawHapticCommand(
        actuationID: 3,
        rawParameter1: 0,
        rawParameter2: 1,
        rawParameter3: 2
    )

    do {
        _ = try PressureHapticProfile(levels: [])
        fatalError("Expected an empty profile to be rejected")
    } catch let error as PressureHapticProfileError {
        expect(error == .emptyLevels, "Unexpected empty profile error")
    } catch {
        fatalError("Unexpected error: \(error)")
    }

    do {
        _ = try PressureHapticProfile(levels: [
            .init(lowerBound: 0.5, command: command),
            .init(lowerBound: 0.5, command: command),
        ])
        fatalError("Expected duplicate boundaries to be rejected")
    } catch let error as PressureHapticProfileError {
        expect(
            error == .levelsMustBeStrictlyAscending,
            "Unexpected ordering error"
        )
    } catch {
        fatalError("Unexpected error: \(error)")
    }

    do {
        _ = try PressureHapticProfile(levels: [
            .init(lowerBound: .nan, command: command),
        ])
        fatalError("Expected a non-finite boundary to be rejected")
    } catch let error as PressureHapticProfileError {
        expect(
            error == .invalidLowerBound(index: 0),
            "Unexpected invalid boundary error"
        )
    } catch {
        fatalError("Unexpected error: \(error)")
    }
}

private func verifyRateLimit() {
    var controller = PressureHapticController(
        calibration: .init(restingPressure: 100, maximumPressure: 600),
        profile: .sevenStage
    )

    let first = unwrap(
        controller.consume(
            pressure: 350,
            isTouching: true,
            timestamp: 0,
            rate: 10
        ),
        "Expected initial emission"
    )
    expectClose(first.normalizedPressure, 5)
    expectClose(first.intensity, 1.55)
    expect(first.levelIndex == 2, "Expected the third pressure level")
    expect(
        controller.consume(
            pressure: 350,
            isTouching: true,
            timestamp: 0.09,
            rate: 10
        ) == nil,
        "Expected rate limiting within the same level"
    )
    expect(
        controller.consume(
            pressure: 350,
            isTouching: true,
            timestamp: 0.10,
            rate: 10
        ) != nil,
        "Expected emission after the configured rate interval"
    )
}

private func verifyZeroRateOnlyEmitsOnLevelChange() {
    var controller = PressureHapticController(
        calibration: .init(restingPressure: 100, maximumPressure: 600)
    )

    expect(
        controller.consume(
            pressure: 350, isTouching: true, timestamp: 0, rate: 0
        ) != nil,
        "The first selected level must emit"
    )
    expect(
        controller.consume(
            pressure: 350, isTouching: true, timestamp: 10, rate: 0
        ) == nil,
        "Zero rate must suppress same-level repetition"
    )
    expect(
        controller.consume(
            pressure: 500, isTouching: true, timestamp: 10.01, rate: 0
        ) != nil,
        "A changed level must bypass zero rate"
    )
}

private func verifyImmediateLevelChange() {
    var controller = PressureHapticController(
        calibration: .init(restingPressure: 100, maximumPressure: 600),
        profile: .sevenStage
    )

    let first = unwrap(
        controller.consume(pressure: 200, isTouching: true, timestamp: 0),
        "Expected initial level"
    )
    let second = unwrap(
        controller.consume(pressure: 250, isTouching: true, timestamp: 0.01),
        "Expected immediate emission after a level change"
    )
    expect(first.levelIndex == 0, "Expected first pressure level")
    expect(second.levelIndex == 1, "Expected second pressure level")
}

private func verifyReleaseReset() {
    var controller = PressureHapticController(
        calibration: .init(restingPressure: 100, maximumPressure: 600),
        profile: .sevenStage
    )

    expect(
        controller.consume(pressure: 350, isTouching: true, timestamp: 0) != nil,
        "Expected initial emission"
    )
    expect(
        controller.consume(pressure: 0, isTouching: false, timestamp: 0.01) == nil,
        "Release must not emit"
    )
    expect(
        controller.consume(pressure: 350, isTouching: true, timestamp: 0.02) != nil,
        "Release must reset the rate limiter"
    )
    expect(
        controller.consume(pressure: 120, isTouching: true, timestamp: 0.03) == nil,
        "Below-threshold pressure must not emit"
    )
    expect(
        controller.consume(pressure: 350, isTouching: true, timestamp: 0.04) != nil,
        "Below-threshold pressure must reset the rate limiter"
    )
}

verifyCalibration()
verifySevenStageProfile()
verifyConfigurableProfiles()
verifyProfileValidation()
verifyRateLimit()
verifyZeroRateOnlyEmitsOnLevelChange()
verifyImmediateLevelChange()
verifyReleaseReset()
print("PressureHapticsCore tests passed")
