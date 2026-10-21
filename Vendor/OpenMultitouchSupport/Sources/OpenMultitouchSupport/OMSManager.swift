/*
 OMSManager.swift

 Created by Takuto Nakamura on 2024/03/02.
*/

import Combine
@preconcurrency import OpenMultitouchSupportXCF
import os

public struct OMSDeviceInfo: Sendable, Hashable {
    public let deviceName: String
    public let deviceID: String
    public let isBuiltIn: Bool
    internal nonisolated(unsafe) let deviceInfo: OpenMTDeviceInfo
    
    internal init(_ deviceInfo: OpenMTDeviceInfo) {
        self.deviceInfo = deviceInfo
        self.deviceName = deviceInfo.deviceName
        self.deviceID = deviceInfo.deviceID
        self.isBuiltIn = deviceInfo.isBuiltIn
    }
}

public enum OMSHapticIntensity: Int32, CaseIterable, Sendable {
    case weak = 3
    case medium = 4
    case strong = 6
}

public enum OMSHapticPattern: Int32, CaseIterable, Sendable {
    case generic = 15
    case alignment = 16
    case level = 5  // Changed from 17 to 5 (valid ID)
}

public final class OMSManager: Sendable {
    public static let shared = OMSManager()

    private let protectedManager: OSAllocatedUnfairLock<OpenMTManager?>
    private let protectedListener = OSAllocatedUnfairLock<OpenMTListener?>(uncheckedState: nil)
    private let dateFormatter = DateFormatter()

    private let touchDataSubject = PassthroughSubject<[OMSTouchData], Never>()
    private let touchFrameSubject = PassthroughSubject<TimedTouchFrame, Never>()

    private struct TimedTouchFrame: Sendable {
        let touches: [OMSTouchData]
        let timestamp: TimeInterval
    }

    /// Receives frames synchronously on the input thread, without an intervening
    /// queue. Subscribers must return promptly and bound their own buffering.
    public func observeTouchFrames(
        _ receive: @escaping @Sendable ([OMSTouchData], TimeInterval) -> Void
    ) -> AnyCancellable {
        touchFrameSubject.sink { frame in
            receive(frame.touches, frame.timestamp)
        }
    }
    public var touchDataStream: AsyncStream<[OMSTouchData]> {
        AsyncStream { continuation in
            let cancellable = touchDataSubject.sink { value in
                continuation.yield(value)
            }
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }

    public var isListening: Bool {
        protectedListener.withLockUnchecked { $0 != nil }
    }
    
    public var availableDevices: [OMSDeviceInfo] {
        guard let xcfManager = protectedManager.withLockUnchecked(\.self) else { return [] }
        return xcfManager.availableDevices().map { OMSDeviceInfo($0) }
    }
    
    public var currentDevice: OMSDeviceInfo? {
        guard let xcfManager = protectedManager.withLockUnchecked(\.self),
              let current = xcfManager.currentDevice() else { return nil }
        return OMSDeviceInfo(current)
    }

    private init() {
        protectedManager = .init(uncheckedState: OpenMTManager.shared())
        dateFormatter.dateFormat = "HH:mm:ss.SSSS"
    }

    @discardableResult
    public func startListening() -> Bool {
        guard let xcfManager = protectedManager.withLockUnchecked(\.self) else {
            return false
        }
        // The nil check and the listener installation must happen under one
        // lock. Concurrent callers would otherwise each create a listener and
        // leak all but the last one.
        return protectedListener.withLockUnchecked { listener -> Bool in
            guard listener == nil,
                  let newListener = xcfManager.addListener(
                      withTarget: self,
                      selector: #selector(listen)
                  ) else {
                return false
            }
            listener = newListener
            return true
        }
    }

    @discardableResult
    public func stopListening() -> Bool {
        guard let xcfManager = protectedManager.withLockUnchecked(\.self) else {
            return false
        }
        // Removal and the teardown assignment are atomic for the same reason:
        // a split check-then-remove could remove the same listener twice.
        return protectedListener.withLockUnchecked { listener -> Bool in
            guard let existingListener = listener else { return false }
            xcfManager.remove(existingListener)
            listener = nil
            return true
        }
    }
    
    @discardableResult
    public func selectDevice(_ device: OMSDeviceInfo) -> Bool {
        guard let xcfManager = protectedManager.withLockUnchecked(\.self) else { return false }
        return xcfManager.selectDevice(device.deviceInfo)
    }
    
    public var isHapticEnabled: Bool {
        guard let xcfManager = protectedManager.withLockUnchecked(\.self) else { return false }
        return xcfManager.isHapticEnabled()
    }
    
    @discardableResult
    public func setHapticEnabled(_ enabled: Bool) -> Bool {
        guard let xcfManager = protectedManager.withLockUnchecked(\.self) else { return false }
        return xcfManager.setHapticEnabled(enabled)
    }
    
    @discardableResult
    public func triggerRawHaptic(actuationID: Int32, unknown1: UInt32, unknown2: Float, unknown3: Float) -> Bool {
        guard let xcfManager = protectedManager.withLockUnchecked(\.self) else { return false }
        return xcfManager.triggerRawHaptic(actuationID, unknown1: unknown1, unknown2: unknown2, unknown3: unknown3)
    }

    @objc func listen(_ event: OpenMTEvent) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let touches = (event.touches as NSArray) as? [OpenMTTouch] else { return }
        if touches.isEmpty {
            touchFrameSubject.send(TimedTouchFrame(touches: [], timestamp: timestamp))
            touchDataSubject.send([])
        } else {
            let array = touches.compactMap { touch -> OMSTouchData? in
                guard let state = OMSState(touch.state) else { return nil }
                return OMSTouchData(
                    id: touch.identifier,
                    position: OMSPosition(x: touch.posX, y: touch.posY),
                    total: touch.total,
                    pressure: touch.pressure,
                    axis: OMSAxis(major: touch.majorAxis, minor: touch.minorAxis),
                    angle: touch.angle,
                    density: touch.density,
                    state: state,
                    timestamp: dateFormatter.string(from: Date.now)
                )
            }
            touchFrameSubject.send(TimedTouchFrame(touches: array, timestamp: timestamp))
            touchDataSubject.send(array)
        }
    }
}

extension AnyCancellable: @retroactive @unchecked Sendable {}
extension PassthroughSubject: @retroactive @unchecked Sendable {}
