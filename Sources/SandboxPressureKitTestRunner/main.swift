import PressureHapticsCore

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
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

private let mapper = GamePressureMapper()

private func sample(
    _ pressure: Float,
    stage: Int = 1
) -> GamePressureSample {
    mapper.map(.init(pressure: pressure, stage: stage, timestamp: 3))
}

private func verifyDefaultCurve() {
    expectClose(sample(0).intensity, 0)
    expectClose(sample(0.05).intensity, 0)
    expectClose(sample(0.5).intensity, 0.224_376_74)
    expectClose(sample(1).intensity, 1)
}

private func verifyInputClamping() {
    expectClose(sample(-1).intensity, 0)
    expectClose(sample(2).intensity, 1)
    expectClose(sample(.nan).intensity, 0)
    expectClose(sample(.infinity).intensity, 1)
    expectClose(sample(-.infinity).intensity, 0)
}

private func verifyStageHandling() {
    let stageOne = sample(0.5, stage: 1)
    let stageTwo = sample(0.5, stage: 2)

    expect(!stageOne.isDeepPress, "Stage 1 must not be a deep press")
    expect(stageTwo.isDeepPress, "Stage 2 must be a deep press")
    expectClose(stageOne.intensity, stageTwo.intensity)
}

private func verifyMissingInput() {
    let neutral = mapper.map(nil, timestamp: 7)

    expectClose(neutral.intensity, 0)
    expect(!neutral.isDeepPress, "Missing input must not be a deep press")
    expect(neutral.timestamp == 7, "Neutral sample must use frame timestamp")
}

private func verifyInvalidConfigurationFallsBackToDefaults() {
    let invalidMapper = GamePressureMapper(
        configuration: .init(deadZone: .nan, responseExponent: 0)
    )
    let intensity = invalidMapper.map(
        .init(pressure: 0.5, stage: 1, timestamp: 3)
    ).intensity

    expectClose(intensity, 0.224_376_74)
}

private func verifyFullIntensityConsumerMultiplier() {
    let forceTouchMultiplier = 1 + sample(1).intensity * 3
    expectClose(forceTouchMultiplier, 4)
}

verifyDefaultCurve()
verifyInputClamping()
verifyStageHandling()
verifyMissingInput()
verifyInvalidConfigurationFallsBackToDefaults()
verifyFullIntensityConsumerMultiplier()
print("SandboxPressureKit tests passed")
