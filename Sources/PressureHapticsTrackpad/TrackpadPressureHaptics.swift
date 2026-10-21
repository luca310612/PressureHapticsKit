import Combine
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
    private let inputSource: any TrackpadInputSource
    private let hapticTrigger: (RawHapticCommand) -> Bool
    private let uptime: @Sendable () -> TimeInterval
    private var frameProcessor: PressureFrameProcessor
    private var listeningTask: Task<Void, Never>?
    private var inputObservation: AnyCancellable?
    private var frameBuffer: TrackpadFrameBuffer?
    private var listeningGeneration: UInt64 = 0
    private var lastContactTokens: [Int32: UInt64] = [:]
    private var repeatingHapticTask: Task<Void, Never>?
    private var repeatingHapticLevel: Int?
    private var repeatingHapticGeneration: UInt64 = 0
    private var ownsListening = false
    private static weak var activeInstance: TrackpadPressureHaptics?
    /// Old pressure must never be replayed as current tactile feedback.
    static let maximumFrameAge: TimeInterval = 0.1

    /// Receives the maximum pressure among active contacts.
    public var onPressureSample: ((Float, Int) -> Void)?
    /// Receives the pressure selected by `selectionStrategy`.
    public var onSelectedPressureSample: ((Float?, Int) -> Void)?
    public var onTouchFrame: (([TrackpadTouchSample]) -> Void)?
    public var onHapticTrigger: ((HapticTriggerResult) -> Void)?
    public private(set) var lastStartError: TrackpadPressureHapticsStartError?
    public var selectionStrategy: PressureSelectionStrategy = .maximum
    /// Pressure margin on either side of a level boundary, on the 0–10
    /// normalized scale.
    public var levelHysteresis: Float = 0.2 {
        didSet {
            guard levelHysteresis.isFinite,
                  PressureNormalization.range.contains(levelHysteresis) else {
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
            frameProcessor.resetHaptics()
        }
    }
    /// Replacing the profile is possible at any time, including while
    /// listening. Level selection state clears so thresholds are applied
    /// from the next frame, and a repeating haptic stops when its level no
    /// longer exists.
    public var profile: PressureHapticProfile {
        didSet {
            guard oldValue != profile else { return }
            frameProcessor.profile = profile
            if let level = repeatingHapticLevel,
               !profile.levels.indices.contains(level - 1) {
                stopHaptic()
            }
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
        ownsListening && inputSource.isListening && listeningTask != nil
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

    public convenience init(
        calibration: PressureCalibration,
        profile: PressureHapticProfile = .sevenStage
    ) {
        let manager = OMSManager.shared
        self.init(
            calibration: calibration,
            profile: profile,
            inputSource: OMSTrackpadInputSource(manager: manager),
            hapticTrigger: { command in
                manager.triggerRawHaptic(
                    actuationID: command.actuationID,
                    unknown1: command.rawParameter1,
                    unknown2: command.rawParameter2,
                    unknown3: command.rawParameter3
                )
            }
        )
    }

    init(
        calibration: PressureCalibration,
        profile: PressureHapticProfile = .sevenStage,
        inputSource: any TrackpadInputSource = OMSTrackpadInputSource(manager: .shared),
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        hapticTrigger: @escaping (RawHapticCommand) -> Bool
    ) {
        self.inputSource = inputSource
        self.profile = profile
        self.uptime = uptime
        self.hapticTrigger = hapticTrigger
        frameProcessor = PressureFrameProcessor(
            calibration: calibration,
            profile: profile
        )
    }

    deinit {
        listeningTask?.cancel()
        inputObservation?.cancel()
        frameBuffer?.finish()
        repeatingHapticTask?.cancel()
        if ownsListening {
            inputSource.stopListening()
        }
    }

    @discardableResult
    public func start() -> Bool {
        if listeningTask != nil {
            guard ownsListening && inputSource.isListening else {
                stop()
                lastStartError = .listenerUnavailable
                return false
            }
            return true
        }

        guard Self.activeInstance == nil || Self.activeInstance === self else {
            lastStartError = .alreadyListening
            return false
        }

        guard !inputSource.isListening else {
            lastStartError = .alreadyListening
            return false
        }

        // Subscribe before opening the device so its first frame cannot be lost.
        let buffer = TrackpadFrameBuffer()
        let observation = inputSource.observe { touches, timestamp in
            buffer.receive(touches, timestamp: timestamp)
        }
        let started = inputSource.startListening()
        guard started && inputSource.isListening else {
            observation.cancel()
            buffer.finish()
            if started { inputSource.stopListening() }
            lastStartError = .listenerUnavailable
            return false
        }
        listeningGeneration &+= 1
        let generation = listeningGeneration
        inputObservation = observation
        frameBuffer = buffer
        lastContactTokens = [:]
        ownsListening = true
        Self.activeInstance = self
        lastStartError = nil
        frameProcessor.reset()
        listeningTask = Task { [weak self] in
            for await frame in buffer.stream {
                guard !Task.isCancelled,
                      let self,
                      self.listeningGeneration == generation else {
                    return
                }

                self.consume(frame)
            }
        }
        return true
    }

    public func stop() {
        listeningGeneration &+= 1
        listeningTask?.cancel()
        listeningTask = nil
        inputObservation?.cancel()
        inputObservation = nil
        frameBuffer?.finish()
        frameBuffer = nil
        lastContactTokens = [:]
        stopHaptic()
        frameProcessor.reset()
        if ownsListening {
            inputSource.stopListening()
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

    private func consume(_ frame: TrackpadInputFrame) {
        let continuingContacts = frame.contactTokens.filter {
            lastContactTokens[$0.key] == $0.value
        }
        let selectedContactEnded: Bool
        if case let .touch(id) = selectionStrategy {
            selectedContactEnded = lastContactTokens[id] != nil
                && lastContactTokens[id] != frame.contactTokens[id]
        } else {
            selectedContactEnded = !lastContactTokens.isEmpty && continuingContacts.isEmpty
        }
        if selectedContactEnded { frameProcessor.resetHaptics() }
        lastContactTokens = frame.contactTokens
        frameProcessor.restoreTouchOrder(frame.touchOrder)

        let uptime = self.uptime
        consume(
            frame.touches,
            timestamp: frame.timestamp,
            isFresh: {
                let age = uptime() - frame.timestamp
                return age.isFinite && age >= 0 && age <= Self.maximumFrameAge
            }
        )
    }

    func consume(
        _ touches: [TrackpadTouchSample],
        timestamp: TimeInterval,
        isFresh: () -> Bool = { true }
    ) {
        let generation = listeningGeneration
        let callbackTouches = touches.filter {
            !$0.phase.isTouching || $0.pressure.isFinite
        }
        onTouchFrame?(callbackTouches)
        guard listeningGeneration == generation else { return }

        let result = frameProcessor.consume(
            touches,
            timestamp: timestamp,
            selectionStrategy: selectionStrategy,
            rate: rate
        )
        onPressureSample?(result.maximumPressure, result.activeTouchCount)
        guard listeningGeneration == generation else { return }
        onSelectedPressureSample?(
            result.selectedPressure,
            result.activeTouchCount
        )

        guard listeningGeneration == generation else { return }
        guard isFresh() else {
            frameProcessor.resetHaptics()
            return
        }

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
