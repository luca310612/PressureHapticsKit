import Foundation
import OpenMultitouchSupport
import PressureHapticsCore

public struct HapticTriggerResult {
    public let level: Int
    public let succeeded: Bool

    public init(level: Int, succeeded: Bool) {
        self.level = level
        self.succeeded = succeeded
    }
}

@MainActor
public final class TrackpadPressureHaptics {
    private let manager: OMSManager
    private let profile: PressureHapticProfile
    private let hapticTrigger: (RawHapticCommand) -> Bool
    private var frameProcessor: PressureFrameProcessor
    private var listeningTask: Task<Void, Never>?
    private var repeatingHapticTask: Task<Void, Never>?
    private var repeatingHapticGeneration: UInt64 = 0

    public var onPressureSample: ((Float, Int) -> Void)?
    public var onTouchFrame: (([TrackpadTouchSample]) -> Void)?
    public var onHapticTrigger: ((HapticTriggerResult) -> Void)?
    public var selectionStrategy: PressureSelectionStrategy = .maximum
    public var rate: Double = 0 {
        didSet {
            if rate < 0 || !rate.isFinite {
                rate = oldValue
            }
        }
    }

    public init(
        calibration: PressureCalibration,
        profile: PressureHapticProfile = .sevenStage
    ) {
        let manager = OMSManager.shared
        self.manager = manager
        self.profile = profile
        hapticTrigger = { command in
            manager.triggerRawHaptic(
                actuationID: command.actuationID,
                unknown1: command.rawParameter1,
                unknown2: command.rawParameter2,
                unknown3: command.rawParameter3
            )
        }
        frameProcessor = PressureFrameProcessor(
            calibration: calibration,
            profile: profile
        )
    }

    init(
        calibration: PressureCalibration,
        profile: PressureHapticProfile = .sevenStage,
        hapticTrigger: @escaping (RawHapticCommand) -> Bool
    ) {
        manager = OMSManager.shared
        self.profile = profile
        self.hapticTrigger = hapticTrigger
        frameProcessor = PressureFrameProcessor(
            calibration: calibration,
            profile: profile
        )
    }

    deinit {
        listeningTask?.cancel()
        repeatingHapticTask?.cancel()
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
        stopHaptic()
        manager.stopListening()
    }

    public func triggerHaptic(level: Int) {
        performHapticTrigger(level: level)
    }

    public func startHaptic(level: Int) {
        stopHaptic()
        let generation = repeatingHapticGeneration
        performHapticTrigger(level: level)

        guard repeatingHapticGeneration == generation,
              rate > 0,
              (1...profile.levels.count).contains(level) else {
            return
        }

        let interval = 1 / rate
        let task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }

                guard !Task.isCancelled else {
                    return
                }
                guard let self,
                      self.repeatingHapticGeneration == generation else {
                    return
                }
                self.performHapticTrigger(level: level)
            }
        }
        replaceRepeatingHapticTask(with: task)
    }

    public func stopHaptic() {
        repeatingHapticGeneration &+= 1
        replaceRepeatingHapticTask(with: nil)
    }

    private func consume(_ rawTouches: [OMSTouchData]) {
        let touches = rawTouches.map(TrackpadTouchSample.init)
        consume(
            touches,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
    }

    func consume(
        _ touches: [TrackpadTouchSample],
        timestamp: TimeInterval
    ) {
        onTouchFrame?(touches)

        let result = frameProcessor.consume(
            touches,
            timestamp: timestamp,
            selectionStrategy: selectionStrategy,
            rate: rate
        )
        onPressureSample?(result.maximumPressure, result.activeTouchCount)

        guard let emission = result.emission else {
            return
        }

        performHapticTrigger(level: emission.levelIndex + 1)
    }

    private func performHapticTrigger(level: Int) {
        guard (1...profile.levels.count).contains(level) else {
            onHapticTrigger?(.init(level: level, succeeded: false))
            return
        }

        let command = profile.levels[level - 1].command
        let succeeded = hapticTrigger(command)
        onHapticTrigger?(.init(level: level, succeeded: succeeded))
    }

    private func replaceRepeatingHapticTask(
        with task: Task<Void, Never>?
    ) {
        repeatingHapticTask?.cancel()
        repeatingHapticTask = task
    }
}

@available(*, deprecated, renamed: "TrackpadPressureHaptics")
public typealias TrackWeightPressureHaptics = TrackpadPressureHaptics
