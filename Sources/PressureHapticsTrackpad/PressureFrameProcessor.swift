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
    private var filteredPressure: Float?
    private var lastTimestamp: TimeInterval?

    /// EMA weight for each new pressure sample. Set to 1 to disable filtering.
    public var smoothingFactor: Float {
        didSet {
            guard smoothingFactor.isFinite,
                  smoothingFactor > 0,
                  smoothingFactor <= 1 else {
                smoothingFactor = oldValue
                return
            }
            filteredPressure = nil
        }
    }

    /// Pressure margin around each level boundary, in normalized units.
    public var levelHysteresis: Float {
        didSet {
            guard levelHysteresis.isFinite,
                  (0...1).contains(levelHysteresis) else {
                levelHysteresis = oldValue
                return
            }
            controller.levelHysteresis = levelHysteresis
        }
    }

    public init(
        calibration: PressureCalibration,
        profile: PressureHapticProfile = .sevenStage,
        smoothingFactor: Float = 0.35,
        levelHysteresis: Float = 0.02
    ) {
        let validSmoothingFactor = smoothingFactor.isFinite
            && smoothingFactor > 0
            && smoothingFactor <= 1
            ? smoothingFactor
            : 0.35
        let validLevelHysteresis = levelHysteresis.isFinite
            && (0...1).contains(levelHysteresis)
            ? levelHysteresis
            : 0.02
        self.smoothingFactor = validSmoothingFactor
        self.levelHysteresis = validLevelHysteresis
        controller = PressureHapticController(
            calibration: calibration,
            profile: profile,
            levelHysteresis: validLevelHysteresis
        )
    }

    public mutating func reset() {
        controller.reset()
        touchOrder.removeAll(keepingCapacity: true)
        filteredPressure = nil
        lastTimestamp = nil
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
        if let lastTimestamp, timestamp < lastTimestamp {
            filteredPressure = nil
        }
        lastTimestamp = timestamp.isFinite ? timestamp : nil
        let pressureForController: Float?
        if let pressure, timestamp.isFinite {
            if let filteredPressure {
                let factor = smoothingFactor
                let next = pressure * factor + filteredPressure * (1 - factor)
                self.filteredPressure = next.isFinite ? next : pressure
            } else {
                filteredPressure = pressure
            }
            pressureForController = filteredPressure
        } else {
            filteredPressure = nil
            pressureForController = pressure
        }
        let emission = controller.consume(
            pressure: pressureForController ?? 0,
            isTouching: pressureForController != nil,
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
