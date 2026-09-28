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

public enum TrackpadPressureHapticsStartError: Error, Sendable, Equatable {
    case alreadyListening
    case listenerUnavailable
}

@MainActor
public final class TrackpadPressureHaptics {
    private let manager: OMSManager
    private let profile: PressureHapticProfile
    private let hapticTrigger: (RawHapticCommand) -> Bool
    private var frameProcessor: PressureFrameProcessor
    private var listeningTask: Task<Void, Never>?
    private var repeatingHapticTask: Task<Void, Never>?
    private var repeatingHapticLevel: Int?
    private var repeatingHapticGeneration: UInt64 = 0
    private var ownsListening = false
    private static weak var activeInstance: TrackpadPressureHaptics?

    /// Receives the maximum pressure among active contacts.
    public var onPressureSample: ((Float, Int) -> Void)?
    /// Receives the pressure selected by `selectionStrategy`.
    public var onSelectedPressureSample: ((Float?, Int) -> Void)?
    public var onTouchFrame: (([TrackpadTouchSample]) -> Void)?
    public var onHapticTrigger: ((HapticTriggerResult) -> Void)?
    public private(set) var lastStartError: TrackpadPressureHapticsStartError?
    public var selectionStrategy: PressureSelectionStrategy = .maximum
    /// EMA weight for each new pressure sample. Values must be in (0, 1]; 1 disables filtering.
    public var pressureSmoothingFactor: Float = 0.35 {
        didSet {
            guard pressureSmoothingFactor.isFinite,
                  pressureSmoothingFactor > 0,
                  pressureSmoothingFactor <= 1 else {
                pressureSmoothingFactor = oldValue
                return
            }
            frameProcessor.smoothingFactor = pressureSmoothingFactor
        }
    }
    /// Normalized pressure margin on either side of a level boundary.
    public var levelHysteresis: Float = 0.02 {
        didSet {
            guard levelHysteresis.isFinite,
                  (0...1).contains(levelHysteresis) else {
                levelHysteresis = oldValue
                return
            }
            frameProcessor.levelHysteresis = levelHysteresis
        }
    }
    /// Disables only automatic pressure-to-haptic emissions. Touch frames and
    /// explicit `triggerHaptic(level:)` calls remain available to game code.
    public var isAutomaticHapticsEnabled = true {
        didSet {
            guard oldValue != isAutomaticHapticsEnabled else { return }
            frameProcessor.reset()
        }
    }
    public var rate: Double = 0 {
        didSet {
            if rate < 0 || !rate.isFinite {
                rate = oldValue
                return
            }

            guard oldValue != rate,
                  let level = repeatingHapticLevel else {
                return
            }

            stopHaptic()

            guard rate > 0 else { return }
            scheduleRepeatingHaptic(
                level: level,
                generation: repeatingHapticGeneration
            )
        }
    }

    public var isListening: Bool {
        ownsListening && manager.isListening && listeningTask != nil
    }

    private func scheduleRepeatingHaptic(
        level: Int,
        generation: UInt64
    ) {
        let repeatDelayNanoseconds = Self.repeatDelayNanoseconds(for: rate)
        repeatingHapticLevel = level
        let task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: repeatDelayNanoseconds
                    )
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
        if ownsListening {
            _ = manager.stopListening()
        }
    }

    @discardableResult
    public func start() -> Bool {
        if listeningTask != nil {
            guard ownsListening && manager.isListening else {
                listeningTask?.cancel()
                listeningTask = nil
                ownsListening = false
                frameProcessor.reset()
                if Self.activeInstance === self {
                    Self.activeInstance = nil
                }
                lastStartError = .listenerUnavailable
                return false
            }
            return true
        }

        guard Self.activeInstance == nil || Self.activeInstance === self else {
            lastStartError = .alreadyListening
            return false
        }

        guard !manager.isListening else {
            lastStartError = .alreadyListening
            return false
        }

        guard manager.startListening() else {
            lastStartError = .listenerUnavailable
            return false
        }
        ownsListening = true
        Self.activeInstance = self
        lastStartError = nil
        frameProcessor.reset()
        listeningTask = Task { [weak self, manager] in
            for await touches in manager.touchDataStream {
                guard !Task.isCancelled else {
                    return
                }

                self?.consume(touches)
            }
        }
        return true
    }

    public func stop() {
        listeningTask?.cancel()
        listeningTask = nil
        stopHaptic()
        frameProcessor.reset()
        if ownsListening {
            _ = manager.stopListening()
            ownsListening = false
        }
        if Self.activeInstance === self {
            Self.activeInstance = nil
        }
    }

    /// Stops all activity and releases callbacks so captured objects can be
    /// deallocated even if a callback captured this instance strongly.
    public func shutdown() {
        stop()
        onPressureSample = nil
        onSelectedPressureSample = nil
        onTouchFrame = nil
        onHapticTrigger = nil
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

        scheduleRepeatingHaptic(level: level, generation: generation)
    }

    static func repeatDelayNanoseconds(for rate: Double) -> UInt64 {
        guard rate.isFinite, rate > 0 else {
            return .max
        }

        let nanoseconds = 1_000_000_000 / rate
        guard nanoseconds.isFinite,
              nanoseconds < Double(UInt64.max) else {
            return .max
        }

        return max(UInt64(nanoseconds), 1)
    }

    public func stopHaptic() {
        repeatingHapticGeneration &+= 1
        repeatingHapticLevel = nil
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
        let callbackTouches = touches.filter {
            !$0.phase.isTouching || $0.pressure.isFinite
        }
        onTouchFrame?(callbackTouches)

        let result = frameProcessor.consume(
            touches,
            timestamp: timestamp,
            selectionStrategy: selectionStrategy,
            rate: rate
        )
        onPressureSample?(result.maximumPressure, result.activeTouchCount)
        onSelectedPressureSample?(
            result.selectedPressure,
            result.activeTouchCount
        )

        guard isAutomaticHapticsEnabled,
              let emission = result.emission else {
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
