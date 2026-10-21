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
    case invalidCommand(index: Int)
    case firstThresholdMustBeBelowMaximum
    case levelsMustBeStrictlyAscending
    case intensitiesMustBeAscending
    case invalidLevelCount(Int)
    case mismatchedLevelArrays
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
                  PressureNormalization.range.contains(level.lowerBound) else {
                throw PressureHapticProfileError.invalidLowerBound(index: index)
            }

            guard level.command.rawParameter2.isFinite,
                  level.command.rawParameter3.isFinite else {
                throw PressureHapticProfileError.invalidCommand(index: index)
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

        let pressure = PressureNormalization.clamp(normalizedPressure)
        guard let index = levels.lastIndex(where: { $0.lowerBound <= pressure }) else {
            return nil
        }

        return Selection(index: index, level: levels[index])
    }

    /// Selects a level while retaining the previous level inside its
    /// hysteresis band. Hysteresis is expressed in normalized pressure units.
    public func selection(
        for normalizedPressure: Float,
        previousIndex: Int?,
        hysteresis: Float
    ) -> Selection? {
        guard normalizedPressure.isFinite,
              hysteresis.isFinite,
              hysteresis >= 0 else {
            return nil
        }

        let pressure = PressureNormalization.clamp(normalizedPressure)
        guard let previousIndex, levels.indices.contains(previousIndex) else {
            return selection(for: pressure)
        }

        var index = previousIndex
        while index + 1 < levels.count,
              pressure >= min(
                  PressureNormalization.maximum,
                  levels[index + 1].lowerBound + hysteresis
              ) {
            index += 1
        }

        while index > 0,
              pressure < levels[index].lowerBound - hysteresis {
            index -= 1
        }

        guard pressure >= levels[0].lowerBound - hysteresis else {
            return nil
        }
        return Selection(index: index, level: levels[index])
    }

    // MARK: - Configurable profiles

    /// Builds a profile with `levelCount` evenly spaced thresholds running
    /// from `firstThreshold` toward full pressure on the 0–10 scale, with
    /// linearly interpolated command intensities inside `intensityRange`.
    ///
    /// Provide `actuationIDs` (one per level) to choose the device actuation
    /// pattern explicitly; otherwise each intensity is mapped onto the
    /// nearest built-in actuation strength used by `.sevenStage`.
    ///
    /// Example: `try PressureHapticProfile.linear(levelCount: 5)` produces
    /// thresholds `1.5, 3.2, 4.9, 6.6, 8.3` with intensities from `0.5`
    /// through `2.0`.
    public static func linear(
        levelCount: Int,
        firstThreshold: Float = 1.5,
        intensityRange: ClosedRange<Float> = 0.5...2.0,
        actuationIDs: [Int32]? = nil
    ) throws -> PressureHapticProfile {
        guard levelCount >= 1 else {
            throw PressureHapticProfileError.invalidLevelCount(levelCount)
        }

        guard firstThreshold.isFinite,
              PressureNormalization.range.contains(firstThreshold) else {
            throw PressureHapticProfileError.invalidLowerBound(index: 0)
        }

        // With even spacing toward the maximum, a first threshold at the
        // maximum duplicates every threshold. A single level tolerates it.
        if levelCount >= 2, firstThreshold == PressureNormalization.maximum {
            throw PressureHapticProfileError
                .firstThresholdMustBeBelowMaximum
        }

        let thresholdStep = (PressureNormalization.maximum - firstThreshold)
            / Float(levelCount)
        let thresholds = (0..<levelCount).map {
            firstThreshold + Float($0) * thresholdStep
        }

        return try buildProfile(
            thresholds: thresholds,
            intensities: intensityValues(
                count: levelCount,
                range: intensityRange
            ),
            actuationIDs: actuationIDs
        )
    }

    /// Builds a profile from explicit thresholds with nondecreasing
    /// intensities, all on the 0–10 normalized scale. Omit `actuationIDs`
    /// to map each intensity onto the nearest built-in actuation strength.
    ///
    /// For full control over the sent commands, including `rawParameter1`/3,
    /// construct `PressureHapticLevel` values yourself and use
    /// `init(levels:)`.
    public static func custom(
        thresholds: [Float],
        intensities: [Float],
        actuationIDs: [Int32]? = nil
    ) throws -> PressureHapticProfile {
        guard !thresholds.isEmpty else {
            throw PressureHapticProfileError.emptyLevels
        }

        return try buildProfile(
            thresholds: thresholds,
            intensities: intensities,
            actuationIDs: actuationIDs
        )
    }

    private static func intensityValues(
        count: Int,
        range: ClosedRange<Float>
    ) -> [Float] {
        guard count > 1 else { return [range.upperBound] }
        let step = (range.upperBound - range.lowerBound) / Float(count - 1)
        return (0..<count).map { range.lowerBound + Float($0) * step }
    }

    private static func buildProfile(
        thresholds: [Float],
        intensities: [Float],
        actuationIDs: [Int32]?
    ) throws -> PressureHapticProfile {
        guard thresholds.count == intensities.count,
              actuationIDs == nil || actuationIDs?.count == thresholds.count
        else {
            throw PressureHapticProfileError.mismatchedLevelArrays
        }

        var previousIntensity: Float?
        for intensity in intensities {
            if let previousIntensity, intensity < previousIntensity {
                throw PressureHapticProfileError.intensitiesMustBeAscending
            }
            previousIntensity = intensity
        }

        let levels = zip(thresholds, intensities).enumerated().map {
            index, pair -> PressureHapticLevel in
            let actuationID = actuationIDs?[index]
                ?? actuationID(forIntensity: pair.1)
            return PressureHapticLevel(
                lowerBound: pair.0,
                command: RawHapticCommand(
                    actuationID: actuationID,
                    rawParameter1: 0,
                    rawParameter2: pair.1,
                    rawParameter3: 2
                )
            )
        }

        return try PressureHapticProfile(levels: levels)
    }

    /// Actuation pattern and strength of the built-in seven levels, from the
    /// weakest to the strongest command the trackpad accepts per level.
    private static let builtInActuationStrengths: [
        (intensity: Float, actuationID: Int32)
    ] = [
        (intensity: 0.50, actuationID: 3),
        (intensity: 0.75, actuationID: 3),
        (intensity: 1.00, actuationID: 4),
        (intensity: 1.25, actuationID: 4),
        (intensity: 1.50, actuationID: 4),
        (intensity: 1.75, actuationID: 6),
        (intensity: 2.00, actuationID: 6),
    ]

    private static func actuationID(forIntensity intensity: Float) -> Int32 {
        let strengths = builtInActuationStrengths
        if intensity <= strengths[0].intensity {
            return strengths[0].actuationID
        }
        if intensity >= strengths[strengths.count - 1].intensity {
            return strengths[strengths.count - 1].actuationID
        }

        var bestIndex = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for (index, entry) in strengths.enumerated() {
            let distance = abs(entry.intensity - intensity)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return strengths[bestIndex].actuationID
    }

    /// The historical default: seven evenly spaced levels from 1.5 toward
    /// full pressure, equivalent to `linear(levelCount: 7)`.
    public static let sevenStage: PressureHapticProfile = {
        let levelCount = 7
        do {
            return try linear(levelCount: levelCount)
        } catch {
            fatalError(
                "The built-in \(levelCount)-level profile must always be "
                    + "constructible: \(error)"
            )
        }
    }()
}
