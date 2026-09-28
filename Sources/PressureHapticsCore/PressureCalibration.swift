public struct PressureCalibrationPoint: Sendable, Hashable {
    public let pressure: Float
    public let grams: Float

    public init(pressure: Float, grams: Float) {
        self.pressure = pressure
        self.grams = grams
    }
}

public enum PressureCalibrationError: Error, Sendable, Equatable {
    case invalidRange
    case insufficientMassPoints
    case invalidMassPoint(index: Int)
    case massPointsMustBeAscending
}

public struct PressureCalibration: Sendable, Hashable {
    public let restingPressure: Float
    public let maximumPressure: Float
    public let massPoints: [PressureCalibrationPoint]

    public init(
        restingPressure: Float,
        maximumPressure: Float,
        massPoints: [PressureCalibrationPoint] = []
    ) {
        self.restingPressure = restingPressure
        self.maximumPressure = maximumPressure
        self.massPoints = massPoints
    }

    public init(
        validatingRestingPressure restingPressure: Float,
        maximumPressure: Float,
        massPoints: [PressureCalibrationPoint] = []
    ) throws {
        self.init(
            restingPressure: restingPressure,
            maximumPressure: maximumPressure,
            massPoints: massPoints
        )
        try validate()
    }

    public func validate() throws {
        guard restingPressure.isFinite,
              maximumPressure.isFinite,
              maximumPressure > restingPressure else {
            throw PressureCalibrationError.invalidRange
        }

        guard massPoints.isEmpty || massPoints.count >= 2 else {
            throw PressureCalibrationError.insufficientMassPoints
        }

        for (index, point) in massPoints.enumerated() {
            guard point.pressure.isFinite,
                  point.grams.isFinite,
                  point.grams >= 0 else {
                throw PressureCalibrationError.invalidMassPoint(index: index)
            }

            if index > 0 {
                let previous = massPoints[index - 1]
                guard previous.pressure < point.pressure,
                      previous.grams <= point.grams else {
                    throw PressureCalibrationError.massPointsMustBeAscending
                }
            }
        }
    }

    public func normalize(_ pressure: Float) -> Float {
        let range = maximumPressure - restingPressure

        guard restingPressure.isFinite,
              maximumPressure.isFinite,
              range > 0,
              pressure.isFinite else {
            return 0
        }

        return min(max((pressure - restingPressure) / range, 0), 1)
    }

    public func grams(for pressure: Float) -> Float? {
        guard pressure.isFinite, massPoints.count >= 2 else { return nil }
        let points = massPoints.sorted { $0.pressure < $1.pressure }
        guard points.allSatisfy({
                  $0.pressure.isFinite && $0.grams.isFinite && $0.grams >= 0
              }),
              zip(points, points.dropFirst()).allSatisfy({
                  $0.0.pressure < $0.1.pressure && $0.0.grams <= $0.1.grams
              }) else {
            return nil
        }
        if pressure <= points[0].pressure { return points[0].grams }
        if pressure >= points[points.count - 1].pressure { return points[points.count - 1].grams }
        for pair in zip(points, points.dropFirst()) where pressure <= pair.1.pressure {
            let fraction = (pressure - pair.0.pressure) / (pair.1.pressure - pair.0.pressure)
            return pair.0.grams + fraction * (pair.1.grams - pair.0.grams)
        }
        return nil
    }
}
