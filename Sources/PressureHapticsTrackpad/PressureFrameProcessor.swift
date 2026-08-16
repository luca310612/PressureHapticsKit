import Foundation
import PressureHapticsCore

public struct PressureFrameResult: Sendable, Hashable {
    public let maximumPressure: Float
    public let activeTouchCount: Int
    public let emission: HapticEmission?

    public init(
        maximumPressure: Float,
        activeTouchCount: Int,
        emission: HapticEmission?
    ) {
        self.maximumPressure = maximumPressure
        self.activeTouchCount = activeTouchCount
        self.emission = emission
    }
}

public struct PressureFrameProcessor: Sendable {
    private var controller: PressureHapticController

    public init(
        calibration: PressureCalibration,
        profile: PressureHapticProfile = .sevenStage
    ) {
        controller = PressureHapticController(
            calibration: calibration,
            profile: profile
        )
    }

    public mutating func consume(
        _ touches: [TrackpadTouchSample],
        timestamp: TimeInterval
    ) -> PressureFrameResult {
        let activeTouches = touches.filter(\.phase.isTouching)
        let maximumPressure = activeTouches.map(\.pressure).max() ?? 0
        let emission = controller.consume(
            pressure: maximumPressure,
            isTouching: !activeTouches.isEmpty,
            timestamp: timestamp
        )

        return PressureFrameResult(
            maximumPressure: maximumPressure,
            activeTouchCount: activeTouches.count,
            emission: emission
        )
    }
}
