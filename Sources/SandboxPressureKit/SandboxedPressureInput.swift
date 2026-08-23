import AppKit
import PressureHapticsCore

public enum SandboxedPressureInput {
    /// Reads one current public pressure event.
    ///
    /// The result is an AppKit event value, not a calibrated physical-force
    /// measurement and not an independent pressure reading for every touch.
    /// Callers that process multiple touches in one frame should apply the same
    /// returned sample to that frame's touches while retaining their own input
    /// histories and geometry. This method does not observe global input.
    public static func sample(from event: NSEvent) -> PublicPressureSample? {
        guard event.type == .pressure else {
            return nil
        }

        return makeSample(
            pressure: event.pressure,
            stage: event.stage,
            timestamp: event.timestamp
        )
    }

    @_spi(Testing)
    public static func makeSample(
        pressure: Float,
        stage: Int,
        timestamp: TimeInterval
    ) -> PublicPressureSample {
        .init(pressure: pressure, stage: stage, timestamp: timestamp)
    }
}
