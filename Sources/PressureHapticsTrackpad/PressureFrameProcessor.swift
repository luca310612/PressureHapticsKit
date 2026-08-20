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
    private var touchOrder: [Int32] = []

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
        timestamp: TimeInterval,
        selectionStrategy: PressureSelectionStrategy = .maximum,
        rate: Double = 0
    ) -> PressureFrameResult {
        let activeTouches = touches.filter(\.phase.isTouching)
        let maximumPressure = activeTouches.map(\.pressure).max() ?? 0
        updateTouchOrder(for: activeTouches)
        let pressure = selectedPressure(
            from: activeTouches,
            using: selectionStrategy
        )
        let emission = controller.consume(
            pressure: pressure ?? 0,
            isTouching: pressure != nil,
            timestamp: timestamp,
            rate: rate
        )

        return PressureFrameResult(
            maximumPressure: maximumPressure,
            activeTouchCount: activeTouches.count,
            emission: emission
        )
    }

    private mutating func updateTouchOrder(
        for activeTouches: [TrackpadTouchSample]
    ) {
        let activeIDs = Set(activeTouches.map(\.id))
        touchOrder.removeAll { !activeIDs.contains($0) }

        for touch in activeTouches where !touchOrder.contains(touch.id) {
            touchOrder.append(touch.id)
        }
    }

    private func selectedPressure(
        from activeTouches: [TrackpadTouchSample],
        using strategy: PressureSelectionStrategy
    ) -> Float? {
        switch strategy {
        case .maximum:
            return activeTouches.map(\.pressure).max()
        case .average:
            guard !activeTouches.isEmpty else { return nil }
            return activeTouches.map(\.pressure).reduce(0, +)
                / Float(activeTouches.count)
        case let .touch(id):
            return activeTouches.first(where: { $0.id == id })?.pressure
        case .firstTouch:
            guard let id = touchOrder.first else { return nil }
            return activeTouches.first(where: { $0.id == id })?.pressure
        }
    }
}
