import Foundation

public struct PublicPressureSample: Sendable, Equatable {
    public let pressure: Float
    public let stage: Int
    public let timestamp: TimeInterval

    public init(pressure: Float, stage: Int, timestamp: TimeInterval) {
        self.pressure = pressure
        self.stage = stage
        self.timestamp = timestamp
    }
}

public struct GamePressureSample: Sendable, Equatable {
    public let intensity: Float
    public let isDeepPress: Bool
    public let timestamp: TimeInterval

    public init(
        intensity: Float,
        isDeepPress: Bool,
        timestamp: TimeInterval
    ) {
        self.intensity = intensity
        self.isDeepPress = isDeepPress
        self.timestamp = timestamp
    }

    public static func neutral(timestamp: TimeInterval) -> Self {
        .init(intensity: 0, isDeepPress: false, timestamp: timestamp)
    }
}

public struct GamePressureConfiguration: Sendable, Equatable {
    public var deadZone: Float
    public var responseExponent: Float

    public init(deadZone: Float = 0.05, responseExponent: Float = 2.0) {
        self.deadZone = deadZone
        self.responseExponent = responseExponent
    }
}

public struct GamePressureMapper: Sendable {
    private let configuration: GamePressureConfiguration

    public init(configuration: GamePressureConfiguration = .init()) {
        self.configuration = configuration
    }

    public func map(_ sample: PublicPressureSample) -> GamePressureSample {
        let pressure = normalized(sample.pressure)
        let deadZone = validDeadZone
        let linearIntensity = min(
            max((pressure - deadZone) / (1 - deadZone), 0),
            1
        )

        return .init(
            intensity: pow(linearIntensity, validResponseExponent),
            isDeepPress: sample.stage == 2,
            timestamp: sample.timestamp
        )
    }

    public func map(
        _ sample: PublicPressureSample?,
        timestamp: TimeInterval
    ) -> GamePressureSample {
        guard let sample else {
            return .neutral(timestamp: timestamp)
        }

        return map(sample)
    }

    private var validDeadZone: Float {
        guard configuration.deadZone.isFinite,
              (Float.zero..<1).contains(configuration.deadZone) else {
            return 0.05
        }

        return configuration.deadZone
    }

    private var validResponseExponent: Float {
        guard configuration.responseExponent.isFinite,
              configuration.responseExponent > 0 else {
            return 2
        }

        return configuration.responseExponent
    }

    private func normalized(_ pressure: Float) -> Float {
        guard !pressure.isNaN else {
            return 0
        }

        guard pressure.isFinite else {
            return pressure > 0 ? 1 : 0
        }

        return min(max(pressure, 0), 1)
    }
}
