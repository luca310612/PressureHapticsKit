import Foundation
import PressureHapticsCore

public struct PressureFrameResult: Sendable, Hashable {
    /// Current pressure selected from the active contacts for this frame.
    public let currentPressure: Float?
    /// Maximum pressure among active contacts, independent of the selection strategy.
    public let maximumPressure: Float
    /// Pressure selected by the configured selection strategy.
    public let selectedPressure: Float?
    public let activeTouchCount: Int
    public let emission: HapticEmission?

    public init(
        maximumPressure: Float,
        selectedPressure: Float?,
        activeTouchCount: Int,
        emission: HapticEmission?
    ) {
        self.currentPressure = selectedPressure
        self.maximumPressure = maximumPressure
        self.selectedPressure = selectedPressure
        self.activeTouchCount = activeTouchCount
        self.emission = emission
    }
}

public struct PressureFrameProcessor: Sendable {
    private var controller: PressureHapticController
    private var touchOrder: [Int32] = []

    /// Pressure margin around each level boundary, in normalized units on
    /// the 0–10 scale.
    public var levelHysteresis: Float {
        didSet {
            guard levelHysteresis.isFinite,
                  PressureNormalization.range.contains(levelHysteresis) else {
                levelHysteresis = oldValue
                return
            }
            controller.levelHysteresis = levelHysteresis
        }
    }

    /// Replacing the profile also clears level selection state, so the next
    /// frame starts a fresh hysteresis band.
    public var profile: PressureHapticProfile {
        didSet {
            guard oldValue != profile else { return }
            controller.replaceProfile(profile)
        }
    }

    public init(
        calibration: PressureCalibration,
        profile: PressureHapticProfile = .sevenStage,
        levelHysteresis: Float = 0.2
    ) {
        let validLevelHysteresis = levelHysteresis.isFinite
            && PressureNormalization.range.contains(levelHysteresis)
            ? levelHysteresis
            : 0.2
        self.levelHysteresis = validLevelHysteresis
        self.profile = profile
        controller = PressureHapticController(
            calibration: calibration,
            profile: profile,
            levelHysteresis: validLevelHysteresis
        )
    }

    public mutating func reset() {
        resetHaptics()
        touchOrder.removeAll(keepingCapacity: true)
    }

    /// Clears emission state without changing which contact was first.
    mutating func resetHaptics() {
        controller.reset()
    }

    /// Restores producer-side contact order after intermediate frames coalesce.
    mutating func restoreTouchOrder(_ order: [Int32]) {
        touchOrder = order
    }

    public mutating func consume(
        _ touches: [TrackpadTouchSample],
        timestamp: TimeInterval,
        selectionStrategy: PressureSelectionStrategy = .maximum,
        rate: Double = 0
    ) -> PressureFrameResult {
        let activeTouches = touches.filter {
            $0.phase.isTouching && $0.pressure.isFinite
        }
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
            selectedPressure: pressure,
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
            let sum = activeTouches.reduce(0.0) {
                $0 + Double($1.pressure)
            }
            let average = sum / Double(activeTouches.count)
            guard average.isFinite else { return nil }
            return Float(average)
        case let .touch(id):
            return activeTouches.first(where: { $0.id == id })?.pressure
        case .firstTouch:
            guard let id = touchOrder.first else { return nil }
            return activeTouches.first(where: { $0.id == id })?.pressure
        }
    }
}
