import Foundation

public struct HapticEmission: Sendable, Hashable {
    public let normalizedPressure: Float
    public let intensity: Float
    public let levelIndex: Int
    public let command: RawHapticCommand

    public init(
        normalizedPressure: Float,
        intensity: Float,
        levelIndex: Int,
        command: RawHapticCommand
    ) {
        self.normalizedPressure = normalizedPressure
        self.intensity = intensity
        self.levelIndex = levelIndex
        self.command = command
    }
}

public struct PressureHapticController: Sendable {
    private let calibration: PressureCalibration
    private var lastEmissionTime: TimeInterval?
    private var lastLevelIndex: Int?
    /// Replaces via `replaceProfile(_:)` so stale level state clears too.
    public private(set) var profile: PressureHapticProfile
    public var levelHysteresis: Float {
        didSet {
            guard levelHysteresis.isFinite,
                  PressureNormalization.range.contains(levelHysteresis) else {
                levelHysteresis = oldValue
                return
            }
        }
    }

    public init(
        calibration: PressureCalibration,
        profile: PressureHapticProfile = .sevenStage,
        levelHysteresis: Float = 0.2
    ) {
        self.calibration = calibration
        self.profile = profile
        self.levelHysteresis = levelHysteresis.isFinite
            && PressureNormalization.range.contains(levelHysteresis)
            ? levelHysteresis
            : 0.2
    }

    /// Replaces the profile and clears emission state, so the next selected
    /// level starts from a fresh hysteresis band.
    public mutating func replaceProfile(
        _ newProfile: PressureHapticProfile
    ) {
        profile = newProfile
        resetEmissionState()
    }

    public mutating func reset() {
        resetEmissionState()
    }

    public mutating func consume(
        pressure: Float,
        isTouching: Bool,
        timestamp: TimeInterval,
        rate: Double = 0
    ) -> HapticEmission? {
        guard timestamp.isFinite,
              pressure.isFinite,
              calibration.restingPressure.isFinite,
              calibration.maximumPressure.isFinite,
              calibration.maximumPressure > calibration.restingPressure else {
            resetEmissionState()
            return nil
        }

        guard isTouching else {
            resetEmissionState()
            return nil
        }

        // A restarted clock starts a new selection, including its hysteresis.
        if let lastEmissionTime, timestamp < lastEmissionTime {
            resetEmissionState()
        }

        let normalizedPressure = calibration.normalize(pressure)
        guard let selection = profile.selection(
            for: normalizedPressure,
            previousIndex: lastLevelIndex,
            hysteresis: levelHysteresis
        ) else {
            resetEmissionState()
            return nil
        }

        let changedLevel = lastLevelIndex != selection.index
        let validRate = rate.isFinite && rate > 0 ? rate : 0
        let canEmitForRate = validRate > 0 && lastEmissionTime.map {
            timestamp - $0 >= 1 / validRate
        } ?? false

        guard changedLevel || canEmitForRate else {
            return nil
        }

        lastEmissionTime = timestamp
        lastLevelIndex = selection.index

        return HapticEmission(
            normalizedPressure: normalizedPressure,
            intensity: 0.1 + normalizedPressure * 0.29,
            levelIndex: selection.index,
            command: selection.level.command
        )
    }

    private mutating func resetEmissionState() {
        lastEmissionTime = nil
        lastLevelIndex = nil
    }
}
