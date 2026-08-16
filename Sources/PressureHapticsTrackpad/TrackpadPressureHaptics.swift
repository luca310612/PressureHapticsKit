import Foundation
import OpenMultitouchSupport
import PressureHapticsCore

@MainActor
public final class TrackpadPressureHaptics {
    private let manager: OMSManager
    private var frameProcessor: PressureFrameProcessor
    private var listeningTask: Task<Void, Never>?

    public var onPressureSample: ((Float, Int) -> Void)?
    public var onTouchFrame: (([TrackpadTouchSample]) -> Void)?

    public init(
        calibration: PressureCalibration,
        profile: PressureHapticProfile = .sevenStage
    ) {
        manager = OMSManager.shared
        frameProcessor = PressureFrameProcessor(
            calibration: calibration,
            profile: profile
        )
    }

    deinit {
        listeningTask?.cancel()
        manager.stopListening()
    }

    public func start() {
        guard listeningTask == nil else {
            return
        }

        manager.startListening()
        listeningTask = Task { [weak self, manager] in
            for await touches in manager.touchDataStream {
                guard !Task.isCancelled else {
                    return
                }

                self?.consume(touches)
            }
        }
    }

    public func stop() {
        listeningTask?.cancel()
        listeningTask = nil
        manager.stopListening()
    }

    private func consume(_ rawTouches: [OMSTouchData]) {
        let touches = rawTouches.map(TrackpadTouchSample.init)
        onTouchFrame?(touches)

        let result = frameProcessor.consume(
            touches,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        onPressureSample?(result.maximumPressure, result.activeTouchCount)

        guard let emission = result.emission else {
            return
        }

        let command = emission.command
        let wasTriggered = manager.triggerRawHaptic(
            actuationID: command.actuationID,
            unknown1: command.rawParameter1,
            unknown2: command.rawParameter2,
            unknown3: command.rawParameter3
        )

        print(
            String(
                format: "trackweight pressure=%.3f normalized=%.3f intensity=%.3f level=%d actuation=%d result=%@",
                result.maximumPressure,
                emission.normalizedPressure,
                emission.intensity,
                emission.levelIndex + 1,
                command.actuationID,
                wasTriggered ? "true" : "false"
            )
        )
    }
}

@available(*, deprecated, renamed: "TrackpadPressureHaptics")
public typealias TrackWeightPressureHaptics = TrackpadPressureHaptics
