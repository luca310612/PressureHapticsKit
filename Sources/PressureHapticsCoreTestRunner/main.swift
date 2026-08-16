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
    expectClose(calibration.normalize(350), 0.5)
    expectClose(calibration.normalize(600), 1)
    expectClose(calibration.normalize(700), 1)
    expectClose(calibration.normalize(.nan), 0)
}

private func verifySevenStageProfile() {
    let profile = PressureHapticProfile.sevenStage
    let samples: [(Float, Int, Int32, Float)] = [
        (0.15, 0, 3, 0.50),
        (0.28, 1, 3, 0.75),
        (0.40, 2, 4, 1.00),
        (0.52, 3, 4, 1.25),
        (0.64, 4, 4, 1.50),
        (0.76, 5, 6, 1.75),
        (0.88, 6, 6, 2.00),
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
        profile.selection(for: 0.149) == nil,
        "Pressure below the first boundary must not select a level"
    )
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
        controller.consume(pressure: 350, isTouching: true, timestamp: 0),
        "Expected initial emission"
    )
    expectClose(first.normalizedPressure, 0.5)
    expectClose(first.intensity, 1.55)
    expect(first.levelIndex == 2, "Expected the third pressure level")
    expect(
        controller.consume(
            pressure: 350,
            isTouching: true,
            timestamp: 0.10
        ) == nil,
        "Expected rate limiting within the same level"
    )
    expect(
        controller.consume(
            pressure: 350,
            isTouching: true,
            timestamp: 0.18
        ) != nil,
        "Expected emission after the pressure-based interval"
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
        controller.consume(pressure: 240, isTouching: true, timestamp: 0.01),
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
verifyProfileValidation()
verifyRateLimit()
verifyImmediateLevelChange()
verifyReleaseReset()
print("PressureHapticsCore tests passed")
