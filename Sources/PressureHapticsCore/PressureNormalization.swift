/// The inclusive normalized-pressure range shared by the whole kit.
///
/// Raw pressure is mapped from the calibration range onto
/// `minimum...maximum` so callers can think in intuitive 0–10 units
/// instead of fractions. Profile thresholds, hysteresis, and every
/// normalized pressure callback use the same scale.
public enum PressureNormalization: Sendable, Hashable {
    public static let minimum: Float = 0
    public static let maximum: Float = 10
    public static var range: ClosedRange<Float> { minimum...maximum }

    public static func clamp(_ value: Float) -> Float {
        min(max(value, minimum), maximum)
    }
}
