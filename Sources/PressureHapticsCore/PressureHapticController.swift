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
    private let profile: PressureHapticProfile
    private var lastEmissionTime: TimeInterval?
    private var lastLevelIndex: Int?
    public var levelHysteresis: Float {
        didSet {
            guard levelHysteresis.isFinite,
                  (0...1).contains(levelHysteresis) else {
                levelHysteresis = oldValue
                return
            }
        }
    }

    public init(
        calibration: PressureCalibration,
        profile: PressureHapticProfile = .sevenStage,
        levelHysteresis: Float = 0.02
    ) {
        self.calibration = calibration
        self.profile = profile
        self.levelHysteresis = levelHysteresis.isFinite && (0...1).contains(levelHysteresis)
            ? levelHysteresis
            : 0.02
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
        guard timestamp.isFinite else {
            resetEmissionState()
            return nil
        }

        guard isTouching else {
            resetEmissionState()
            return nil
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

        if let lastEmissionTime, timestamp < lastEmissionTime {
            resetEmissionState()
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
            intensity: 0.1 + normalizedPressure * 2.9,
            levelIndex: selection.index,
            command: selection.level.command
        )
    }

    private mutating func resetEmissionState() {
        lastEmissionTime = nil
        lastLevelIndex = nil
    }
}
