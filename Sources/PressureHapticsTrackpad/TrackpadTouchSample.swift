import OpenMultitouchSupport

public enum TrackpadTouchPhase: String, Sendable, Hashable, CaseIterable {
    case notTouching
    case starting
    case hovering
    case making
    case touching
    case breaking
    case lingering
    case leaving

    public var isTouching: Bool {
        switch self {
        case .notTouching, .leaving:
            false
        case .starting, .hovering, .making, .touching, .breaking, .lingering:
            true
        }
    }

    init(_ state: OMSState) {
        switch state {
        case .notTouching: self = .notTouching
        case .starting: self = .starting
        case .hovering: self = .hovering
        case .making: self = .making
        case .touching: self = .touching
        case .breaking: self = .breaking
        case .lingering: self = .lingering
        case .leaving: self = .leaving
        }
    }
}

public struct TrackpadTouchSample: Sendable, Hashable {
    public let id: Int32
    public let position: SIMD2<Float>
    public let pressure: Float
    public let phase: TrackpadTouchPhase

    public init(
        id: Int32,
        position: SIMD2<Float>,
        pressure: Float,
        phase: TrackpadTouchPhase
    ) {
        self.id = id
        self.position = position
        self.pressure = pressure
        self.phase = phase
    }

    init(_ touch: OMSTouchData) {
        self.init(
            id: touch.id,
            position: SIMD2(touch.position.x, touch.position.y),
            pressure: touch.pressure,
            phase: TrackpadTouchPhase(touch.state)
        )
    }
}
