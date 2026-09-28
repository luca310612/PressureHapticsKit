public struct PressureWeightMeter: Sendable, Hashable {
    /// Optional pressure-to-mass calibration. Without calibration points,
    /// the meter preserves the legacy tare-relative pressure behavior.
    public let calibration: PressureCalibration?
    public private(set) var zeroOffset: Float?
    public private(set) var currentGrams: Float?
    public private(set) var peakGrams: Float = 0
    public let resetThresholdGrams: Float

    public var isMassCalibrated: Bool {
        calibration?.massPoints.count ?? 0 >= 2
    }

    public init(
        calibration: PressureCalibration? = nil,
        zeroOffset: Float? = nil,
        resetThresholdGrams: Float = 1
    ) {
        self.calibration = calibration
        self.zeroOffset = zeroOffset
        self.resetThresholdGrams = max(0, resetThresholdGrams)
    }

    public mutating func tare(rawPressure: Float) {
        guard rawPressure.isFinite else { return }
        zeroOffset = rawPressure
        currentGrams = 0
        peakGrams = 0
    }

    public mutating func resetTare() {
        zeroOffset = nil
        currentGrams = nil
        peakGrams = 0
    }

    public mutating func resetPeak() {
        peakGrams = 0
    }

    /// Updates the live and peak measurements. Returning to the tare range
    /// means the object was removed while the finger remains in contact.
    @discardableResult
    public mutating func update(rawPressure: Float) -> Float? {
        guard let grams = grams(for: rawPressure) else {
            currentGrams = nil
            return nil
        }
        currentGrams = grams
        if grams <= resetThresholdGrams {
            peakGrams = 0
        } else {
            peakGrams = max(peakGrams, grams)
        }
        return grams
    }

    /// Converts pressure above the tare point to mass when calibration points
    /// are available, or to legacy tare-relative pressure units otherwise.
    public func grams(for rawPressure: Float) -> Float? {
        guard rawPressure.isFinite, let zeroOffset, zeroOffset.isFinite else { return nil }

        if isMassCalibrated, let calibration {
            guard let value = calibration.grams(for: rawPressure),
                  let tareValue = calibration.grams(for: zeroOffset) else {
                return nil
            }
            return max(0, value - tareValue)
        }

        return pressureDelta(for: rawPressure)
    }

    /// Returns tare-relative pressure units without interpreting them as grams.
    public func pressureDelta(for rawPressure: Float) -> Float? {
        guard rawPressure.isFinite, let zeroOffset, zeroOffset.isFinite else {
            return nil
        }
        return max(0, rawPressure - zeroOffset)
    }
}
