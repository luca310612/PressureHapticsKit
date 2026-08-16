public struct RawHapticCommand: Sendable, Hashable {
    public let actuationID: Int32
    public let rawParameter1: UInt32
    public let rawParameter2: Float
    public let rawParameter3: Float

    public init(
        actuationID: Int32,
        rawParameter1: UInt32,
        rawParameter2: Float,
        rawParameter3: Float
    ) {
        self.actuationID = actuationID
        self.rawParameter1 = rawParameter1
        self.rawParameter2 = rawParameter2
        self.rawParameter3 = rawParameter3
    }
}

public struct PressureHapticLevel: Sendable, Hashable {
    public let lowerBound: Float
    public let command: RawHapticCommand

    public init(lowerBound: Float, command: RawHapticCommand) {
        self.lowerBound = lowerBound
        self.command = command
    }
}

public enum PressureHapticProfileError: Error, Sendable, Equatable {
    case emptyLevels
    case invalidLowerBound(index: Int)
    case levelsMustBeStrictlyAscending
}

public struct PressureHapticProfile: Sendable, Hashable {
    public struct Selection: Sendable, Hashable {
        public let index: Int
        public let level: PressureHapticLevel

        public init(index: Int, level: PressureHapticLevel) {
            self.index = index
            self.level = level
        }
    }

    public let levels: [PressureHapticLevel]

    public init(levels: [PressureHapticLevel]) throws {
        guard !levels.isEmpty else {
            throw PressureHapticProfileError.emptyLevels
        }

        for (index, level) in levels.enumerated() {
            guard level.lowerBound.isFinite,
                  (0...1).contains(level.lowerBound) else {
                throw PressureHapticProfileError.invalidLowerBound(index: index)
            }

            if index > 0, levels[index - 1].lowerBound >= level.lowerBound {
                throw PressureHapticProfileError.levelsMustBeStrictlyAscending
            }
        }

        self.levels = levels
    }

    public func selection(for normalizedPressure: Float) -> Selection? {
        guard normalizedPressure.isFinite else {
            return nil
        }

        let pressure = min(max(normalizedPressure, 0), 1)
        guard let index = levels.lastIndex(where: { $0.lowerBound <= pressure }) else {
            return nil
        }

        return Selection(index: index, level: levels[index])
    }

    public static let sevenStage: PressureHapticProfile = {
        let thresholds: [Float] = [
            0.15,
            0.271_428_58,
            0.392_857_16,
            0.514_285_74,
            0.635_714_3,
            0.757_142_9,
            0.878_571_45,
        ]
        let actuationIDs: [Int32] = [3, 3, 4, 4, 4, 6, 6]
        let rawParameter2Values: [Float] = [
            0.50, 0.75, 1.00, 1.25, 1.50, 1.75, 2.00,
        ]
        let levels = zip(
            thresholds,
            zip(actuationIDs, rawParameter2Values)
        ).map { threshold, commandValues in
            PressureHapticLevel(
                lowerBound: threshold,
                command: RawHapticCommand(
                    actuationID: commandValues.0,
                    rawParameter1: 0,
                    rawParameter2: commandValues.1,
                    rawParameter3: 2
                )
            )
        }

        return try! PressureHapticProfile(levels: levels)
    }()
}
