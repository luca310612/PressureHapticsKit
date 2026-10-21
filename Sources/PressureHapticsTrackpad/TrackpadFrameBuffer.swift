import Foundation
import os

struct TrackpadInputFrame: Sendable {
    let touches: [TrackpadTouchSample]
    let timestamp: TimeInterval
    let touchOrder: [Int32]
    /// Tokens distinguish a continuing contact from a reused contact ID.
    let contactTokens: [Int32: UInt64]
}

/// Tracks contact lifetimes on the producer thread while keeping only the
/// latest pending frame. UI stalls cannot grow the queue or lose a release
/// followed by a new contact that happens to reuse the same ID.
final class TrackpadFrameBuffer: Sendable {
    let stream: AsyncStream<TrackpadInputFrame>
    private let continuation: AsyncStream<TrackpadInputFrame>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var touchOrder: [Int32] = []
        var contactTokens: [Int32: UInt64] = [:]
        var nextToken: UInt64 = 0
        var isFinished = false
    }

    init() {
        let (stream, continuation) = AsyncStream<TrackpadInputFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.stream = stream
        self.continuation = continuation
    }

    func receive(_ touches: [TrackpadTouchSample], timestamp: TimeInterval) {
        state.withLock { state in
            guard !state.isFinished else { return }
            let activeTouches = touches.filter { $0.phase.isTouching && $0.pressure.isFinite }
            let activeIDs = Set(activeTouches.map(\.id))
            state.touchOrder.removeAll { !activeIDs.contains($0) }
            state.contactTokens = state.contactTokens.filter { activeIDs.contains($0.key) }
            for touch in activeTouches where state.contactTokens[touch.id] == nil {
                state.nextToken &+= 1
                state.contactTokens[touch.id] = state.nextToken
                state.touchOrder.append(touch.id)
            }
            continuation.yield(TrackpadInputFrame(
                touches: touches,
                timestamp: timestamp,
                touchOrder: state.touchOrder,
                contactTokens: state.contactTokens
            ))
        }
    }

    func finish() {
        state.withLock { state in
            state.isFinished = true
            continuation.finish()
        }
    }
}
