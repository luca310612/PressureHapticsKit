# SandboxPressureKit Design

## Goal

Add an AppKit-only, sandbox-compatible pressure-input product to
PressureHapticsKit. It converts documented `NSEvent` pressure information into
deterministic, game-defined intensity. It does not measure physical force,
access raw trackpad data, or produce haptic feedback.

## Existing Package Context

`PressureHapticsCore` is the package's existing pure Swift target and is the
equivalent of the proposed `TerrainCore` layer. `PressureHapticsTrackpad` is a
separate development-oriented target that imports `OpenMultitouchSupport` and
can send raw haptic commands. The new product must not depend on that target
or package.

## Architecture

Add a new `SandboxPressureKit` library target with this dependency direction:

```text
SandboxPressureKit (AppKit) -> PressureHapticsCore (Foundation / pure Swift)
PressureHapticsTrackpad (raw development path) -> PressureHapticsCore
```

`PressureHapticsCore` must never import AppKit. `SandboxPressureKit` is the
only target that imports AppKit and is responsible only for reading public
event data. Neither new target calls `NSHapticFeedbackManager`, raw haptic
commands, `OpenMultitouchSupport`, private APIs, or global event monitors.

The macOS 13 package platform remains unchanged. The target is usable by an
App Sandbox application without Accessibility or Input Monitoring permission.

## Public Core API

Create the following types in `PressureHapticsCore`:

```swift
public struct PublicPressureSample: Sendable, Equatable {
    public let pressure: Float
    public let stage: Int
    public let timestamp: TimeInterval

    public init(pressure: Float, stage: Int, timestamp: TimeInterval)
}

public struct GamePressureSample: Sendable, Equatable {
    public let intensity: Float
    public let isDeepPress: Bool
    public let timestamp: TimeInterval

    public init(intensity: Float, isDeepPress: Bool, timestamp: TimeInterval)
    public static func neutral(timestamp: TimeInterval) -> Self
}

public struct GamePressureConfiguration: Sendable, Equatable {
    public var deadZone: Float
    public var responseExponent: Float

    public init(deadZone: Float = 0.05, responseExponent: Float = 2.0)
}

public struct GamePressureMapper: Sendable {
    public init(configuration: GamePressureConfiguration = .init())

    public func map(_ sample: PublicPressureSample) -> GamePressureSample

    public func map(
        _ sample: PublicPressureSample?,
        timestamp: TimeInterval
    ) -> GamePressureSample
}
```

`GamePressureConfiguration` defaults to `deadZone = 0.05` and
`responseExponent = 2.0`. The mapper applies:

```text
p0 = clamp((pressure - deadZone) / (1 - deadZone), 0, 1)
intensity = p0 ^ responseExponent
```

The mapper defensively clamps a non-finite or out-of-range sample pressure to
`0...1`. It also uses default configuration values if a configuration cannot
form a valid curve: the dead zone must be finite in `0..<1`, and the exponent
must be finite and greater than `0`.

`stage == 2` sets `isDeepPress` to `true`. It never expands the numerical
pressure range or adds a stage-specific multiplier. "Ignoring stage 2 for
terrain depth" means that this Boolean does not modify `intensity`; it does
not mean that a stage-2 event is converted to a zero-intensity sample.

`map(nil, timestamp:)` produces `GamePressureSample.neutral(timestamp:)` with
zero intensity and `isDeepPress == false`. The caller supplies the timestamp
because no absent event has one.

## Public AppKit API

Create this API in `SandboxPressureKit`:

```swift
public enum SandboxedPressureInput {
    public static func sample(
        from event: NSEvent
    ) -> PublicPressureSample?
}
```

The adapter reads only `NSEvent.pressure`, `NSEvent.stage`, and
`NSEvent.timestamp`, and returns `nil` unless `event.type == .pressure`.
The event-type check happens before accessing `stage`: AppKit can raise an
`NSInternalInconsistencyException` when `stage` is sent to a non-pressure
event. It does not attempt to infer missing force from mouse motion or from a
raw touch stream.

AppKit reports pressure for the current input event, not calibrated force per
contact. A multi-touch consumer should therefore apply one mapped game sample
to all contacts observed in the same frame while retaining its own positions,
brush geometry, movement histories, edit commands, speed calculation, and
edit caps.

## Consumer Integration Contract

This repository has no `TerrainDragBuilder`, `TerrainTouchSample`, or
DigitalSandbox target. It therefore exports only the pressure input and does
not add terrain logic. A consumer can combine its own capped terrain edit
logic with the intensity as follows:

```swift
let gamePressure = mapper.map(eventSample, timestamp: frameTimestamp)
let forceTouchMultiplier = 1 + gamePressure.intensity * 3.0
```

The consumer retains its existing speed and excavation-rate caps. Haptic
decisions remain owned by that consumer's terrain/material layer.

## Package Changes

`Package.swift` gains:

- the `SandboxPressureKit` library product;
- the `SandboxPressureKit` target, depending only on `PressureHapticsCore`;
- the `sandbox-pressure-tests` executable product and
  `SandboxPressureKitTestRunner` executable target.

The existing `PressureHapticsTrackpad` product, its raw input dependency, and
its haptic behavior remain source-compatible and unchanged.

## Testing and Verification

The executable runner verifies deterministic behavior:

1. The package-internal AppKit extraction helper converts pressure, stage, and
   timestamp without any raw-input import; the runner imports that helper with
   `@_spi(Testing) import SandboxPressureKit` because public AppKit
   constructors do not create synthetic `.pressure` events.
2. The public AppKit adapter rejects a synthetic non-pressure event before
   reading `stage`.
3. Default dead-zone behavior for values `0`, `0.05`, `0.5`, and `1.0`.
4. Clamp behavior for negative, above-one, non-finite pressure values.
5. Stage 1 reporting without range expansion.
6. Stage 2 reporting through `isDeepPress` without pressure addition.
7. Missing events producing the neutral sample.
8. A consumer-equivalent full-intensity multiplier of `4.0`, while leaving
   capping to the consuming terrain code.

Verification runs the new executable, both existing executable runners, and
`swift build`. `swift test` remains an additional check in environments with
the complete Xcode developer directory; the current Command Line Tools-only
environment cannot resolve XCTest before compiling any package test source.
