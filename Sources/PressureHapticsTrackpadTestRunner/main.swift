import PressureHapticsCore
import PressureHapticsTrackpad

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

private func verifyMaximumActivePressureIsSelected() {
    var processor = PressureFrameProcessor(
        calibration: .init(restingPressure: 100, maximumPressure: 600),
        profile: .sevenStage
    )
    let result = processor.consume([
        .init(
            id: 1,
            position: SIMD2(0.2, 0.3),
            pressure: 200,
            phase: .touching
        ),
        .init(
            id: 2,
            position: SIMD2(0.8, 0.7),
            pressure: 500,
            phase: .touching
        ),
        .init(
            id: 3,
            position: SIMD2(0.5, 0.5),
            pressure: 900,
            phase: .leaving
        ),
    ], timestamp: 0)

    expect(result.activeTouchCount == 2, "Expected two active touches")
    expectClose(result.maximumPressure, 500)
    expect(result.emission?.levelIndex == 5, "Expected the sixth pressure level")
    expect(
        result.emission?.command.actuationID == 6,
        "Expected the strongest active touch to choose actuation ID 6"
    )
}

private func verifyEmptyFrameResetsController() {
    var processor = PressureFrameProcessor(
        calibration: .init(restingPressure: 100, maximumPressure: 600),
        profile: .sevenStage
    )
    let touch = TrackpadTouchSample(
        id: 7,
        position: SIMD2(0.5, 0.5),
        pressure: 350,
        phase: .touching
    )

    expect(
        processor.consume([touch], timestamp: 0).emission != nil,
        "Expected initial emission"
    )
    let empty = processor.consume([], timestamp: 0.01)
    expect(empty.activeTouchCount == 0, "Expected no active touches")
    expectClose(empty.maximumPressure, 0)
    expect(empty.emission == nil, "An empty frame must not emit")
    expect(
        processor.consume([touch], timestamp: 0.02).emission != nil,
        "An empty frame must reset the controller rate limiter"
    )
}

private func verifyTouchPhaseSemantics() {
    let active: [TrackpadTouchPhase] = [
        .starting, .hovering, .making, .touching,
        .breaking, .lingering,
    ]
    for phase in active {
        expect(phase.isTouching, "Expected \(phase) to be active")
    }
    expect(!TrackpadTouchPhase.notTouching.isTouching, "notTouching is inactive")
    expect(!TrackpadTouchPhase.leaving.isTouching, "leaving is inactive")
}

verifyMaximumActivePressureIsSelected()
verifyEmptyFrameResetsController()
verifyTouchPhaseSemantics()
print("PressureHapticsTrackpad tests passed")
