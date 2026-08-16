public struct PressureCalibration: Sendable, Hashable {
    public let restingPressure: Float
    public let maximumPressure: Float

    public init(restingPressure: Float, maximumPressure: Float) {
        self.restingPressure = restingPressure
        self.maximumPressure = maximumPressure
    }

    public func normalize(_ pressure: Float) -> Float {
        let range = maximumPressure - restingPressure

        guard range > 0, pressure.isFinite else {
            return 0
        }

        return min(max((pressure - restingPressure) / range, 0), 1)
    }
}
