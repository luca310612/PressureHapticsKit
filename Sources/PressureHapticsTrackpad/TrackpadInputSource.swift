import Combine
import Foundation
import OpenMultitouchSupport

/// Internal boundary so listener failure and queued input are testable without
/// opening a device or sending a native haptic command.
protocol TrackpadInputSource: Sendable {
    var isListening: Bool { get }
    func startListening() -> Bool
    func stopListening()
    func observe(
        _ receive: @escaping @Sendable ([TrackpadTouchSample], TimeInterval) -> Void
    ) -> AnyCancellable
}

struct OMSTrackpadInputSource: TrackpadInputSource {
    let manager: OMSManager

    var isListening: Bool { manager.isListening }

    func startListening() -> Bool { manager.startListening() }

    func stopListening() { manager.stopListening() }

    func observe(
        _ receive: @escaping @Sendable ([TrackpadTouchSample], TimeInterval) -> Void
    ) -> AnyCancellable {
        manager.observeTouchFrames { touches, timestamp in
            receive(touches.map(TrackpadTouchSample.init), timestamp)
        }
    }
}
