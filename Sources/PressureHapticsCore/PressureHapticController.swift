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

    public init(
        calibration: PressureCalibration,
        profile: PressureHapticProfile = .sevenStage
    ) {
        self.calibration = calibration
        self.profile = profile
    }

    public mutating func consume(
        pressure: Float,
        isTouching: Bool,
        timestamp: TimeInterval,
        rate: Double = 0
    ) -> HapticEmission? {
        guard isTouching else {
            resetEmissionState()
            return nil
        }

        let normalizedPressure = calibration.normalize(pressure)
        guard let selection = profile.selection(for: normalizedPressure) else {
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
