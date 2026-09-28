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
    /// Total capacitance reported by the trackpad for this contact.
    public let total: Float
    /// Contact ellipse axes in major/minor order.
    public let axis: SIMD2<Float>
    /// Finger angle reported by the trackpad, in the device's native units.
    public let angle: Float
    /// Capacitance density for this contact.
    public let density: Float
    /// Human-readable source timestamp retained by OpenMultitouchSupport.
    public let timestamp: String

    public init(
        id: Int32,
        position: SIMD2<Float>,
        pressure: Float,
        phase: TrackpadTouchPhase,
        total: Float = 0,
        axis: SIMD2<Float> = .zero,
        angle: Float = 0,
        density: Float = 0,
        timestamp: String = ""
    ) {
        self.id = id
        self.position = position
        self.pressure = pressure
        self.phase = phase
        self.total = total
        self.axis = axis
        self.angle = angle
        self.density = density
        self.timestamp = timestamp
    }

    init(_ touch: OMSTouchData) {
        self.init(
            id: touch.id,
            position: SIMD2(touch.position.x, touch.position.y),
            pressure: touch.pressure,
            phase: TrackpadTouchPhase(touch.state),
            total: touch.total,
            axis: SIMD2(touch.axis.major, touch.axis.minor),
            angle: touch.angle,
            density: touch.density,
            timestamp: touch.timestamp
        )
    }
}
