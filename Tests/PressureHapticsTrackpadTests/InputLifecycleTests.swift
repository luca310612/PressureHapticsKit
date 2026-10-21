import Combine
import Foundation
import os
import PressureHapticsCore
import XCTest
@testable import PressureHapticsTrackpad

private final class TestInputSource: TrackpadInputSource {
    typealias Receiver = @Sendable ([TrackpadTouchSample], TimeInterval) -> Void
    private struct State {
        var listening = false
        var observers: [UUID: Receiver] = [:]
        var starts = 0
        var stops = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let startResult: Bool
    private let createsListener: Bool

    init(startResult: Bool = true, createsListener: Bool = true) {
        self.startResult = startResult
        self.createsListener = createsListener
    }

    var isListening: Bool { state.withLock { $0.listening } }
    var observerCount: Int { state.withLock { $0.observers.count } }
    var startCount: Int { state.withLock { $0.starts } }
    var stopCount: Int { state.withLock { $0.stops } }

    func startListening() -> Bool {
        state.withLock {
            $0.starts += 1
            $0.listening = startResult && createsListener
        }
        return startResult
    }

    func stopListening() {
        state.withLock {
            $0.stops += 1
            $0.listening = false
        }
    }

    func observe(_ receive: @escaping Receiver) -> AnyCancellable {
        let id = UUID()
        state.withLock { $0.observers[id] = receive }
        return AnyCancellable { [weak self] in
            self?.state.withLock { $0.observers[id] = nil }
        }
    }

    func send(_ touches: [TrackpadTouchSample], timestamp: TimeInterval) {
        let observers = state.withLock { Array($0.observers.values) }
        for observer in observers { observer(touches, timestamp) }
    }
}

@MainActor
final class InputLifecycleTests: XCTestCase {
    private func touch(_ id: Int32, _ pressure: Float) -> TrackpadTouchSample {
        .init(id: id, position: .zero, pressure: pressure, phase: .touching)
    }

    private func makeHaptics(
        input: TestInputSource = TestInputSource(),
        uptime: @escaping @Sendable () -> TimeInterval = { 10 },
        trigger: @escaping (RawHapticCommand) -> Bool = { _ in true }
    ) -> TrackpadPressureHaptics {
        TrackpadPressureHaptics(
            calibration: .init(restingPressure: 100, maximumPressure: 600),
            inputSource: input, uptime: uptime, hapticTrigger: trigger
        )
    }

    func testEveryInputCallbackCanStopOrShutdownWithoutTrailingHaptic() {
        for callbackIndex in 0..<3 {
            for shutsDown in [false, true] {
                var commands = 0
                var callbacks: [Int] = []
                let haptics = makeHaptics(trigger: { _ in commands += 1; return true })
                XCTAssertTrue(haptics.start())
                let callback: (Int) -> Void = { [weak haptics] index in
                    callbacks.append(index)
                    if index == callbackIndex {
                        if shutsDown { haptics?.shutdown() } else { haptics?.stop() }
                    }
                }
                haptics.onTouchFrame = { _ in callback(0) }
                haptics.onPressureSample = { _, _ in callback(1) }
                haptics.onSelectedPressureSample = { _, _ in callback(2) }
                haptics.consume([touch(1, 500)], timestamp: 0)
                XCTAssertEqual(commands, 0)
                XCTAssertEqual(callbacks, Array(0...callbackIndex))
                XCTAssertFalse(haptics.isListening)
                haptics.shutdown()
            }
        }
    }

    func testCallbackRestartCannotEmitTheOldFrame() {
        var commands = 0
        let haptics = makeHaptics(trigger: { _ in commands += 1; return true })
        XCTAssertTrue(haptics.start())
        defer { haptics.shutdown() }
        haptics.onTouchFrame = { [weak haptics] _ in
            haptics?.stop()
            XCTAssertEqual(haptics?.start(), true)
        }
        haptics.consume([touch(1, 500)], timestamp: 0)
        XCTAssertEqual(commands, 0)
        XCTAssertTrue(haptics.isListening)
        haptics.onTouchFrame = nil
        haptics.consume([touch(1, 500)], timestamp: 1)
        XCTAssertEqual(commands, 1)
    }

    func testStartRejectsSuccessWithoutListenerAndReleasesOwnership() {
        for result in [true, false] {
            let input = TestInputSource(startResult: result, createsListener: false)
            let haptics = makeHaptics(input: input)
            XCTAssertFalse(haptics.start())
            XCTAssertFalse(haptics.isListening)
            XCTAssertEqual(haptics.lastStartError, .listenerUnavailable)
            XCTAssertEqual(input.observerCount, 0)
            let next = makeHaptics()
            XCTAssertTrue(next.start())
            next.shutdown()
        }
    }

    func testListeningDeinitReleasesSubscriptionAndListener() async {
        let input = TestInputSource()
        var haptics: TrackpadPressureHaptics? = makeHaptics(input: input)
        weak let weakHaptics = haptics
        XCTAssertEqual(haptics?.start(), true)
        await Task.yield()
        haptics = nil
        XCTAssertNil(weakHaptics)
        XCTAssertFalse(input.isListening)
        XCTAssertEqual(input.observerCount, 0)
        XCTAssertEqual(input.stopCount, 1)
    }

    func testAutomaticTogglePreservesFirstTouchInBothDirections() {
        let haptics = makeHaptics()
        haptics.selectionStrategy = .firstTouch
        var selected: [Float?] = []
        haptics.onSelectedPressureSample = { pressure, _ in selected.append(pressure) }
        haptics.consume([touch(2, 500)], timestamp: 0)
        let touches = [touch(1, 200), touch(2, 500)]
        haptics.consume(touches, timestamp: 1)
        haptics.isAutomaticHapticsEnabled = false
        haptics.consume(touches, timestamp: 2)
        haptics.isAutomaticHapticsEnabled = true
        haptics.consume(touches, timestamp: 3)
        XCTAssertEqual(selected, [500, 500, 500, 500])
    }

    func testFirstTouchHandoffUsesNewPressureWithDefaultHysteresis() {
        var processor = PressureFrameProcessor(
            calibration: .init(restingPressure: 40, maximumPressure: 640)
        )
        _ = processor.consume([touch(2, 500), touch(1, 200)], timestamp: 0, selectionStrategy: .firstTouch)
        let result = processor.consume([touch(1, 200)], timestamp: 1, selectionStrategy: .firstTouch)
        XCTAssertEqual(result.selectedPressure, 200)
        // 160 / 600 is below L2's entry threshold but above its exit threshold.
        XCTAssertEqual(result.emission?.levelIndex, 1)
    }

    func testSlowConsumerReceivesOnlyLatestPendingFrame() async {
        let buffer = TrackpadFrameBuffer()
        for index in 0..<10_000 {
            buffer.receive([touch(1, Float(index))], timestamp: Double(index))
        }
        buffer.finish()
        var frames: [TrackpadInputFrame] = []
        for await frame in buffer.stream { frames.append(frame) }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.timestamp, 9_999)
        XCTAssertEqual(frames.first?.touches.first?.pressure, 9_999)
    }

    func testCoalescingPreservesContactOrderAndReusedIDs() async {
        let buffer = TrackpadFrameBuffer()
        var iterator = buffer.stream.makeAsyncIterator()
        buffer.receive([touch(2, 500)], timestamp: 0)
        let first = await iterator.next()
        buffer.receive([touch(1, 200), touch(2, 500)], timestamp: 1)
        let second = await iterator.next()
        XCTAssertEqual(second?.touchOrder, [2, 1])
        buffer.receive([], timestamp: 2)
        buffer.receive([touch(1, 200), touch(2, 500)], timestamp: 3)
        let third = await iterator.next()
        XCTAssertEqual(third?.touchOrder, [1, 2])
        XCTAssertNotEqual(first?.contactTokens[2], third?.contactTokens[2])
        buffer.finish()
    }

    func testInputBurstDoesNotReplayBacklogAndKeepsFirstTouch() async {
        let input = TestInputSource()
        var commands = 0
        var selected: [Float?] = []
        let haptics = makeHaptics(input: input, trigger: { _ in commands += 1; return true })
        haptics.selectionStrategy = .firstTouch
        haptics.onSelectedPressureSample = { pressure, _ in selected.append(pressure) }
        XCTAssertTrue(haptics.start())
        defer { haptics.shutdown() }
        // No actor suspension until the entire burst has arrived.
        input.send([touch(2, 500)], timestamp: 10)
        for _ in 0..<1_000 { input.send([touch(1, 200), touch(2, 500)], timestamp: 10) }
        await waitUntil { !selected.isEmpty }
        XCTAssertEqual(selected, [500])
        XCTAssertEqual(commands, 1)
    }

    func testCoalescedReleaseResetsEmissionAndNewFirstTouch() async {
        let input = TestInputSource()
        var commands = 0
        var selected: [Float?] = []
        let haptics = makeHaptics(input: input, trigger: { _ in commands += 1; return true })
        haptics.selectionStrategy = .firstTouch
        haptics.onSelectedPressureSample = { pressure, _ in selected.append(pressure) }
        let nextSession = [touch(1, 480), touch(2, 500)]
        haptics.onHapticTrigger = { _ in
            guard commands == 1 else { return }
            // Publish while the consumer is still processing its first frame,
            // so the intermediate release is definitely coalesced.
            input.send([], timestamp: 10)
            input.send(nextSession, timestamp: 10)
        }
        XCTAssertTrue(haptics.start())
        defer { haptics.shutdown() }
        input.send([touch(2, 500), touch(1, 480)], timestamp: 10)
        await waitUntil { selected.count == 2 }
        XCTAssertEqual(selected, [500, 480])
        XCTAssertEqual(commands, 2, "The new session must emit even at the same level and rate zero")
    }

    func testStaleInputUpdatesReleaseStateButCannotEmit() async {
        let input = TestInputSource()
        var commands = 0
        var counts: [Int] = []
        let haptics = makeHaptics(input: input, trigger: { _ in commands += 1; return true })
        haptics.onPressureSample = { _, count in counts.append(count) }
        XCTAssertTrue(haptics.start())
        defer { haptics.shutdown() }
        input.send([touch(1, 500)], timestamp: 8)
        await waitUntil { counts.count == 1 }
        XCTAssertEqual(commands, 0)
        input.send([touch(1, 500)], timestamp: 10)
        await waitUntil { counts.count == 2 }
        XCTAssertEqual(commands, 1)
        input.send([], timestamp: 8)
        await waitUntil { counts.count == 3 }
        XCTAssertEqual(counts.last, 0)
        XCTAssertEqual(commands, 1)
    }

    func testFrameThatBecomesStaleInsideCallbackDoesNotEmit() async {
        let input = TestInputSource()
        let clock = OSAllocatedUnfairLock(initialState: TimeInterval(10))
        var commands = 0
        var samples = 0
        let haptics = makeHaptics(input: input, uptime: { clock.withLock { $0 } }) { _ in
            commands += 1
            return true
        }
        haptics.onPressureSample = { _, _ in
            samples += 1
            clock.withLock { $0 += 1 }
        }
        XCTAssertTrue(haptics.start())
        defer { haptics.shutdown() }
        input.send([touch(1, 500)], timestamp: 10)
        await waitUntil { samples == 1 }
        XCTAssertEqual(commands, 0)
        haptics.onPressureSample = nil
        input.send([touch(1, 500)], timestamp: 11)
        await waitUntil { commands == 1 }
        XCTAssertEqual(commands, 1)
    }

    func testSecondInstanceCannotStartWhileTheFirstOwnsTheListener() {
        let first = makeHaptics(input: TestInputSource())
        let secondInput = TestInputSource()
        let second = makeHaptics(input: secondInput)

        XCTAssertTrue(first.start())
        defer { first.shutdown() }
        XCTAssertFalse(second.start())
        XCTAssertEqual(second.lastStartError, .alreadyListening)
        XCTAssertFalse(second.isListening)
        XCTAssertEqual(secondInput.startCount, 0)
    }

    func testStopReleasesTheListenerForTheNextInstance() {
        let input = TestInputSource()
        let first = makeHaptics(input: input)
        XCTAssertTrue(first.start())
        first.stop()

        let second = makeHaptics(input: input)
        XCTAssertTrue(second.start())
        XCTAssertEqual(second.lastStartError, nil)
        second.shutdown()
    }

    func testStartFailsWhenTheInputIsAlreadyListeningExternally() {
        let input = TestInputSource()
        _ = input.startListening()
        let haptics = makeHaptics(input: input)

        XCTAssertFalse(haptics.start())
        XCTAssertEqual(haptics.lastStartError, .alreadyListening)
        XCTAssertEqual(input.observerCount, 0)

        input.stopListening()
    }

    func testBufferFinishRejectsLateInput() async {
        let buffer = TrackpadFrameBuffer()
        var iterator = buffer.stream.makeAsyncIterator()
        buffer.receive([touch(1, 500)], timestamp: 1)
        let delivered = await iterator.next()
        XCTAssertEqual(delivered?.timestamp, 1)

        buffer.finish()
        buffer.receive([touch(1, 900)], timestamp: 2)

        let late = await iterator.next()
        XCTAssertNil(late)
    }

    func testBufferTracksOnlyTouchingFiniteContacts() async {
        let buffer = TrackpadFrameBuffer()
        var iterator = buffer.stream.makeAsyncIterator()
        buffer.receive([
            touch(1, 500),
            .init(id: 2, position: .zero, pressure: 300, phase: .leaving),
            .init(id: 3, position: .zero, pressure: .nan, phase: .touching),
        ], timestamp: 0)
        let frame = await iterator.next()
        buffer.finish()

        XCTAssertEqual(frame?.touchOrder, [1])
        XCTAssertEqual(frame?.contactTokens.count, 1)
        XCTAssertEqual(frame?.contactTokens[1], 1)
    }

    func testReusedWatchedContactIDDistinguishesSessionsInTheSameFrame() async {
        let input = TestInputSource()
        var commands = 0
        var levels: [Int] = []
        let haptics = makeHaptics(input: input, trigger: { _ in commands += 1; return true })
        haptics.selectionStrategy = .touch(id: 1)
        haptics.onHapticTrigger = { levels.append($0.level) }
        XCTAssertTrue(haptics.start())
        defer { haptics.shutdown() }

        input.send([touch(1, 350)], timestamp: 10)
        await waitUntil { levels == [3] }

        // Release and a new contact reusing ID 1 coalesce into one frame.
        // The lifetime token must tell the sessions apart so the same level
        // and pressure still emit again at rate zero.
        input.send([], timestamp: 10)
        input.send([touch(1, 350)], timestamp: 10)
        await waitUntil { levels.count == 2 }

        XCTAssertEqual(levels, [3, 3], "A reused contact ID starts a new session")
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !predicate(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(predicate(), "Input task did not make progress before the deadline")
    }
}
