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

private let selectionTouches: [TrackpadTouchSample] = [
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
        pressure: 350,
        phase: .touching
    ),
]

private func makeSelectionProcessor() -> PressureFrameProcessor {
    PressureFrameProcessor(
        calibration: .init(restingPressure: 40, maximumPressure: 640),
        profile: .sevenStage
    )
}

private func verifyPressureSelectionStrategies() {
    var maximumProcessor = makeSelectionProcessor()
    let maximum = maximumProcessor.consume(
        selectionTouches, timestamp: 0, selectionStrategy: .maximum
    )
    expectClose(maximum.maximumPressure, 500)
    expect(
        maximum.emission?.levelIndex == 5,
        "Maximum pressure must determine the emitted level"
    )

    var averageProcessor = makeSelectionProcessor()
    let average = averageProcessor.consume(
        selectionTouches, timestamp: 0, selectionStrategy: .average
    )
    expectClose(average.maximumPressure, 500)
    expect(
        average.emission?.levelIndex == 3,
        "Average pressure must determine the emitted level"
    )

    var touchProcessor = makeSelectionProcessor()
    expect(
        touchProcessor.consume(
            selectionTouches, timestamp: 0.01, selectionStrategy: .touch(id: 1)
        ).emission?.levelIndex == 0,
        "The selected touch ID must determine the emitted level"
    )

    var missingTouchProcessor = makeSelectionProcessor()
    expect(
        missingTouchProcessor.consume(
            selectionTouches, timestamp: 0.02, selectionStrategy: .touch(id: 99)
        ).emission == nil,
        "A missing selected touch must not emit"
    )
}

private func verifyFirstTouchSelectionTracksContactOrder() {
    var processor = makeSelectionProcessor()
    let initialTouches = [selectionTouches[1], selectionTouches[0]]
    expect(
        processor.consume(
            initialTouches, timestamp: 0, selectionStrategy: .firstTouch
        ).emission?.levelIndex == 5,
        "The first active touch in the initial frame must be selected"
    )

    expect(
        processor.consume(
            [selectionTouches[0]], timestamp: 0.01, selectionStrategy: .firstTouch
        ).emission?.levelIndex == 0,
        "The next contact must drive emission after the first touch ends"
    )
}

private func verifyFirstTouchSelectionResetsAfterEmptyFrame() {
    var processor = makeSelectionProcessor()
    expect(
        processor.consume(
            [selectionTouches[1], selectionTouches[0]],
            timestamp: 0,
            selectionStrategy: .firstTouch
        ).emission?.levelIndex == 5,
        "The initial contact session must select its first touch"
    )

    expect(
        processor.consume(
            [], timestamp: 0.01, selectionStrategy: .firstTouch
        ).emission == nil,
        "An empty frame must end the current contact session"
    )

    expect(
        processor.consume(
            [selectionTouches[0], selectionTouches[1]],
            timestamp: 0.02,
            selectionStrategy: .firstTouch
        ).emission?.levelIndex == 0,
        "A new contact session must use its new first touch"
    )
}

verifyMaximumActivePressureIsSelected()
verifyEmptyFrameResetsController()
verifyTouchPhaseSemantics()
verifyPressureSelectionStrategies()
verifyFirstTouchSelectionTracksContactOrder()
verifyFirstTouchSelectionResetsAfterEmptyFrame()
print("PressureHapticsTrackpad tests passed")
