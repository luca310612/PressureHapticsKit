# SandboxPressureKit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a public-AppKit pressure-input product that maps Force Touch
pressure to deterministic game intensity without raw trackpad or haptic APIs.

**Architecture:** `PressureHapticsCore` receives the pure data model and
nonlinear mapper. A new `SandboxPressureKit` target imports AppKit and adapts
only `.pressure` events into the core model. A new executable runner covers
core behavior, while an XCTest target accesses the package-internal event
extraction helper because public AppKit constructors cannot create `.pressure`
events deterministically.

**Tech Stack:** Swift 6, Swift Package Manager, Foundation, AppKit, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-23-sandbox-pressure-kit-design.md`

## Global Constraints

- Support macOS 13 and retain the package's existing platform declaration.
- `PressureHapticsCore` must not import AppKit.
- `SandboxPressureKit` must import only AppKit and `PressureHapticsCore`; it
  must not import `OpenMultitouchSupport` or `PressureHapticsTrackpad`.
- Do not call raw haptic APIs, `NSHapticFeedbackManager`, global event APIs, or
  private APIs.
- `NSEvent.stage` may be accessed only after `event.type == .pressure`.
- Preserve `PressureHapticsTrackpad` and the existing raw-input path unchanged.
- A missing pressure event maps to zero game intensity and does not cause an
  inferred input or haptic action.

---

### Task 1: Add the Pure Game-Pressure Model and Mapper

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PressureHapticsCore/GamePressureMapper.swift`
- Create: `Sources/SandboxPressureKitTestRunner/main.swift`

**Interfaces:**
- Consumes: `Foundation.TimeInterval`.
- Produces: `PublicPressureSample`, `GamePressureSample`,
  `GamePressureConfiguration`, and `GamePressureMapper` from
  `PressureHapticsCore`.
- Produces: `sandbox-pressure-tests` executable product for deterministic
  mapping tests.

- [ ] **Step 1: Add the runner product and write the failing mapper tests**

  Add the executable product and target to `Package.swift`:

  ```swift
  .executable(
      name: "sandbox-pressure-tests",
      targets: ["SandboxPressureKitTestRunner"]
  ),
  // ...
  .executableTarget(
      name: "SandboxPressureKitTestRunner",
      dependencies: ["PressureHapticsCore"]
  ),
  ```

  Create `Sources/SandboxPressureKitTestRunner/main.swift` with the package's
  existing `expect` / `expectClose` runner style. Its behavior checks are:

  ```swift
  import PressureHapticsCore

  private let mapper = GamePressureMapper()

  private func sample(_ pressure: Float, stage: Int = 1) -> GamePressureSample {
      mapper.map(.init(pressure: pressure, stage: stage, timestamp: 3))
  }

  expectClose(sample(0).intensity, 0)
  expectClose(sample(0.05).intensity, 0)
  expectClose(sample(0.5).intensity, 0.224_376_74)
  expectClose(sample(1).intensity, 1)
  expectClose(sample(-1).intensity, 0)
  expectClose(sample(2).intensity, 1)
  expectClose(sample(.nan).intensity, 0)
  expectClose(sample(.infinity).intensity, 1)
  expectClose(sample(-.infinity).intensity, 0)

  let stageOne = sample(0.5, stage: 1)
  let stageTwo = sample(0.5, stage: 2)
  expect(!stageOne.isDeepPress, "Stage 1 must not be a deep press")
  expect(stageTwo.isDeepPress, "Stage 2 must be a deep press")
  expectClose(stageOne.intensity, stageTwo.intensity)

  let neutral = mapper.map(nil, timestamp: 7)
  expectClose(neutral.intensity, 0)
  expect(!neutral.isDeepPress, "Missing input must not be a deep press")
  expect(neutral.timestamp == 7, "Neutral sample must use frame timestamp")

  let invalidMapper = GamePressureMapper(
      configuration: .init(deadZone: .nan, responseExponent: 0)
  )
  expectClose(
      invalidMapper.map(.init(pressure: 0.5, stage: 1, timestamp: 3)).intensity,
      0.224_376_74
  )
  expectClose(1 + sample(1).intensity * 3, 4)
  ```

- [ ] **Step 2: Verify that the new behavior is absent**

  Run: `swift run sandbox-pressure-tests`

  Expected: compilation fails because `GamePressureMapper` and its sample
  types do not yet exist in `PressureHapticsCore`.

- [ ] **Step 3: Implement the minimal pure mapper**

  Create `Sources/PressureHapticsCore/GamePressureMapper.swift` with this
  complete pure implementation:

  ```swift
  import Foundation

  public struct PublicPressureSample: Sendable, Equatable {
      public let pressure: Float
      public let stage: Int
      public let timestamp: TimeInterval

      public init(pressure: Float, stage: Int, timestamp: TimeInterval) {
          self.pressure = pressure
          self.stage = stage
          self.timestamp = timestamp
      }
  }

  public struct GamePressureSample: Sendable, Equatable {
      public let intensity: Float
      public let isDeepPress: Bool
      public let timestamp: TimeInterval

      public init(
          intensity: Float,
          isDeepPress: Bool,
          timestamp: TimeInterval
      ) {
          self.intensity = intensity
          self.isDeepPress = isDeepPress
          self.timestamp = timestamp
      }

      public static func neutral(timestamp: TimeInterval) -> Self {
          .init(intensity: 0, isDeepPress: false, timestamp: timestamp)
      }
  }

  public struct GamePressureConfiguration: Sendable, Equatable {
      public var deadZone: Float
      public var responseExponent: Float

      public init(deadZone: Float = 0.05, responseExponent: Float = 2.0) {
          self.deadZone = deadZone
          self.responseExponent = responseExponent
      }
  }

  public struct GamePressureMapper: Sendable {
      private let configuration: GamePressureConfiguration

      public init(configuration: GamePressureConfiguration = .init()) {
          self.configuration = configuration
      }

      public func map(_ sample: PublicPressureSample) -> GamePressureSample {
          let deadZone = validDeadZone
          let exponent = validResponseExponent
          let pressure = normalized(sample.pressure)
          let linear = min(max((pressure - deadZone) / (1 - deadZone), 0), 1)

          return .init(
              intensity: pow(linear, exponent),
              isDeepPress: sample.stage == 2,
              timestamp: sample.timestamp
          )
      }

      public func map(
          _ sample: PublicPressureSample?,
          timestamp: TimeInterval
      ) -> GamePressureSample {
          guard let sample else {
              return .neutral(timestamp: timestamp)
          }
          return map(sample)
      }

      private var validDeadZone: Float {
          guard configuration.deadZone.isFinite,
                (Float.zero..<1).contains(configuration.deadZone) else {
              return 0.05
          }
          return configuration.deadZone
      }

      private var validResponseExponent: Float {
          guard configuration.responseExponent.isFinite,
                configuration.responseExponent > 0 else {
              return 2
          }
          return configuration.responseExponent
      }

      private func normalized(_ pressure: Float) -> Float {
          if pressure.isNaN || pressure == -.infinity { return 0 }
          if pressure == .infinity { return 1 }
          return min(max(pressure, 0), 1)
      }
  }
  ```

- [ ] **Step 4: Verify the pure mapper is green**

  Run: `swift run sandbox-pressure-tests`

  Expected: the executable exits 0 and prints its success message.

- [ ] **Step 5: Commit the independently testable mapper**

  ```bash
  git add Package.swift Sources/PressureHapticsCore/GamePressureMapper.swift Sources/SandboxPressureKitTestRunner/main.swift
  git commit -m "feat: map public pressure to game intensity"
  ```

### Task 2: Add the AppKit-Only Adapter and Its Unit Tests

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SandboxPressureKit/SandboxedPressureInput.swift`
- Create: `Tests/SandboxPressureKitTests/SandboxedPressureInputTests.swift`

**Interfaces:**
- Consumes: `NSEvent` only in `SandboxPressureKit`.
- Produces: `SandboxedPressureInput.sample(from:) -> PublicPressureSample?`.
- Produces: package-internal `SandboxedPressureInput.sample(pressure:stage:timestamp:)`
  for deterministic XCTest verification of the extraction boundary.

- [ ] **Step 1: Add the target declarations and write failing adapter tests**

  Add the library product, target, and XCTest target:

  ```swift
  .library(name: "SandboxPressureKit", targets: ["SandboxPressureKit"]),
  // ...
  .target(
      name: "SandboxPressureKit",
      dependencies: ["PressureHapticsCore"],
      linkerSettings: [.linkedFramework("AppKit")]
  ),
  .testTarget(
      name: "SandboxPressureKitTests",
      dependencies: ["SandboxPressureKit", "PressureHapticsCore"]
  ),
  ```

  Create the XCTest file using `@testable import SandboxPressureKit`:

  ```swift
  import AppKit
  import XCTest
  @testable import SandboxPressureKit

  final class SandboxedPressureInputTests: XCTestCase {
      func testExtractsPublicPressureFields() {
          let sample = SandboxedPressureInput.sample(
              pressure: 0.75, stage: 2, timestamp: 12
          )
          XCTAssertEqual(sample.pressure, 0.75)
          XCTAssertEqual(sample.stage, 2)
          XCTAssertEqual(sample.timestamp, 12)
      }

      func testRejectsNonPressureEventBeforeReadingStage() {
          let event = NSEvent.mouseEvent(
              with: .leftMouseDown, location: .zero, modifierFlags: [],
              timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0,
              clickCount: 1, pressure: 0.5
          )!
          XCTAssertNil(SandboxedPressureInput.sample(from: event))
      }
  }
  ```

- [ ] **Step 2: Verify that the adapter tests fail for the missing module**

  Run: `swift test --filter SandboxedPressureInputTests`

  Expected: compilation fails because the `SandboxPressureKit` target and
  `SandboxedPressureInput` API do not yet exist.

- [ ] **Step 3: Implement the AppKit adapter**

  Create `Sources/SandboxPressureKit/SandboxedPressureInput.swift`:

  ```swift
  import AppKit
  import PressureHapticsCore

  public enum SandboxedPressureInput {
      public static func sample(from event: NSEvent) -> PublicPressureSample? {
          guard event.type == .pressure else {
              return nil
          }

          return sample(
              pressure: event.pressure,
              stage: event.stage,
              timestamp: event.timestamp
          )
      }

      static func sample(
          pressure: Float,
          stage: Int,
          timestamp: TimeInterval
      ) -> PublicPressureSample {
          .init(pressure: pressure, stage: stage, timestamp: timestamp)
      }
  }
  ```

  Add public documentation to `sample(from:)` stating that it accepts only
  `.pressure` events, never observes global input, returns the event's single
  current pressure value, and is not a per-finger physical-force reading.

- [ ] **Step 4: Verify the adapter tests are green**

  Run: `swift test --filter SandboxedPressureInputTests`

  Expected: both adapter tests pass with no uncaught AppKit exception.

- [ ] **Step 5: Commit the adapter**

  ```bash
  git add Package.swift Sources/SandboxPressureKit/SandboxedPressureInput.swift Tests/SandboxPressureKitTests/SandboxedPressureInputTests.swift
  git commit -m "feat: add sandboxed AppKit pressure input"
  ```

### Task 3: Verify Package Boundaries and Existing Products

**Files:**
- Modify: `Sources/SandboxPressureKitTestRunner/main.swift` only if a missing
  test assertion was discovered in Task 1 or Task 2.

**Interfaces:**
- Consumes: the completed Swift package manifest and source imports.
- Produces: evidence that the Store-safe target is isolated from raw input and
  that legacy products remain buildable.

- [ ] **Step 1: Verify that the new target has no raw dependencies**

  Run:

  ```bash
  rg -n "OpenMultitouchSupport|PressureHapticsTrackpad|NSHapticFeedbackManager|triggerRawHaptic|addGlobalMonitorForEvents" Sources/SandboxPressureKit
  ```

  Expected: no matches; `SandboxedPressureInput.swift` imports only AppKit and
  `PressureHapticsCore`.

- [ ] **Step 2: Run every executable test product**

  Run:

  ```bash
  swift run sandbox-pressure-tests
  swift run pressure-haptics-core-tests
  swift run pressure-haptics-trackpad-tests
  ```

  Expected: all three commands exit 0. The two legacy runners preserve their
  current output and behavior.

- [ ] **Step 3: Run the package's XCTest suite**

  Run: `swift test`

  Expected: all XCTest targets pass, including `SandboxPressureKitTests` and
  the existing `PressureHapticsTrackpadTests`.

- [ ] **Step 4: Commit only intentional test adjustment if one was required**

  ```bash
  git status --short
  git add Sources/SandboxPressureKitTestRunner/main.swift
  git commit -m "test: cover sandbox pressure boundaries"
  ```

  Do not create this commit if the runner needed no adjustment after Task 1.

### Task 4: Final Review and Delivery Evidence

**Files:**
- Review: `Package.swift`
- Review: `Sources/PressureHapticsCore/GamePressureMapper.swift`
- Review: `Sources/SandboxPressureKit/SandboxedPressureInput.swift`
- Review: `Sources/SandboxPressureKitTestRunner/main.swift`
- Review: `Tests/SandboxPressureKitTests/SandboxedPressureInputTests.swift`

**Interfaces:**
- Consumes: the full implementation and fresh verification outputs.
- Produces: a concise handoff listing API additions, preserved raw path, and
  exact validation commands.

- [ ] **Step 1: Check formatting and accidental whitespace changes**

  Run: `git diff --check main...HEAD`

  Expected: no output and exit 0.

- [ ] **Step 2: Check the final target graph**

  Run: `swift package describe --type json`

  Expected: products named `SandboxPressureKit` and `sandbox-pressure-tests`
  are present; `SandboxPressureKit` depends on `PressureHapticsCore` and has
  no package dependency on `OpenMultitouchSupport`.

- [ ] **Step 3: Re-run the full regression suite**

  Run:

  ```bash
  swift run sandbox-pressure-tests
  swift run pressure-haptics-core-tests
  swift run pressure-haptics-trackpad-tests
  swift test
  ```

  Expected: every command exits 0.

- [ ] **Step 4: Report changes with before/after consumer integration**

  Include the existing raw-target dependency and the new AppKit-only target,
  plus this consumer expression:

  ```swift
  // Before
  let forceTouchMultiplier = 1 + normalizedPressure * 1.5

  // After
  let gamePressure = mapper.map(eventSample, timestamp: frameTimestamp)
  let forceTouchMultiplier = 1 + gamePressure.intensity * 3.0
  ```
