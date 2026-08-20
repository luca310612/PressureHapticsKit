# Haptic Trigger Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the profile's haptic levels through direct one-shot and continuous APIs, configurable pressure repetition and multi-touch selection, and a result callback.

**Architecture:** Keep pressure-level and repeat eligibility in `PressureHapticsCore`. Keep touch selection, OMS invocation, direct continuous scheduling, and callback delivery in `PressureHapticsTrackpad`. Use an internal haptic-trigger closure to make OMS outcomes testable without physical trackpad hardware.

**Tech Stack:** Swift 6, Swift Package Manager, macOS 13+, OpenMultitouchSupport, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-21-haptic-trigger-controls-design.md`

## Global Constraints

- Support macOS 13 and Swift 6 as declared in `Package.swift`.
- Public levels are 1-based; `.sevenStage` accepts levels `1...7`.
- `rate` is a finite non-negative `Double`; its default is `0`.
- `rate == 0` disables only repeated vibration, not immediate level changes or `triggerHaptic(level:)`.
- Do not add a public API that accepts `RawHapticCommand` for direct triggering.
- Preserve `PressureFrameResult.maximumPressure` and `onPressureSample` as the actual maximum active pressure.

---

## File Structure

- Modify: `Sources/PressureHapticsCore/PressureHapticController.swift` — make repeated same-level pressure emissions use a caller-supplied rate.
- Modify: `Sources/PressureHapticsCoreTestRunner/main.swift` — exercise zero and fixed rates deterministically.
- Create: `Sources/PressureHapticsTrackpad/PressureSelectionStrategy.swift` — hold the public multi-touch selection enum.
- Modify: `Sources/PressureHapticsTrackpad/PressureFrameProcessor.swift` — select the pressure source and maintain first-contact order.
- Modify: `Sources/PressureHapticsTrackpad/TrackpadPressureHaptics.swift` — expose rate/direct APIs, own continuous task, call OMS through a test seam, and notify results.
- Modify: `Sources/PressureHapticsTrackpadTestRunner/main.swift` — verify every touch-selection strategy and compatibility behavior.
- Modify: `Package.swift` — add an XCTest test target that can use `@testable import` to exercise the OMS seam.
- Create: `Tests/PressureHapticsTrackpadTests/TrackpadPressureHapticsTests.swift` — verify direct one-shot, direct repeat, success, rejection, and invalid-level callbacks without OMS hardware.

## Task 1: Make pressure repetition rate configurable

**Files:**
- Modify: `Sources/PressureHapticsCore/PressureHapticController.swift:22-84`
- Modify: `Sources/PressureHapticsCoreTestRunner/main.swift:125-210`

**Interfaces:**
- Consumes: Existing `PressureCalibration`, `PressureHapticProfile`, and `HapticEmission`.
- Produces: `PressureHapticController.consume(pressure:isTouching:timestamp:rate:) -> HapticEmission?`, where `rate` defaults to `0` for source compatibility.

- [ ] **Step 1: Write failing rate tests**

  In `verifyRateLimit()`, pass `rate: 10` and assert that a same-level sample at `0.09` does not emit while one at `0.10` does. Add `verifyZeroRateOnlyEmitsOnLevelChange()`:

  ```swift
  private func verifyZeroRateOnlyEmitsOnLevelChange() {
      var controller = PressureHapticController(
          calibration: .init(restingPressure: 100, maximumPressure: 600)
      )

      expect(
          controller.consume(
              pressure: 350, isTouching: true, timestamp: 0, rate: 0
          ) != nil,
          "The first selected level must emit"
      )
      expect(
          controller.consume(
              pressure: 350, isTouching: true, timestamp: 10, rate: 0
          ) == nil,
          "Zero rate must suppress same-level repetition"
      )
      expect(
          controller.consume(
              pressure: 500, isTouching: true, timestamp: 10.01, rate: 0
          ) != nil,
          "A changed level must bypass zero rate"
      )
  }
  ```

  Call the new function with the other test functions.

- [ ] **Step 2: Run the Core runner to verify it fails**

  Run: `swift run pressure-haptics-core-tests`

  Expected: compilation failure because `consume(...rate:)` does not yet exist.

- [ ] **Step 3: Implement fixed-rate eligibility**

  Change `consume` to accept `rate: Double = 0`. Replace `minimumInterval(for:)` with a fixed rate check and remove that helper.

  ```swift
  let validRate = rate.isFinite && rate > 0 ? rate : 0
  let canEmitForRate = validRate > 0 && lastEmissionTime.map {
      timestamp - $0 >= 1 / validRate
  } ?? false

  guard changedLevel || canEmitForRate else {
      return nil
  }
  ```

  Keep the existing first-emission behavior through `changedLevel`, because `lastLevelIndex` is initially `nil`. Keep `resetEmissionState()` unchanged.

- [ ] **Step 4: Run the Core runner to verify it passes**

  Run: `swift run pressure-haptics-core-tests`

  Expected: `PressureHapticsCore tests passed`.

- [ ] **Step 5: Commit the Core rate change**

  ```bash
  git add Sources/PressureHapticsCore/PressureHapticController.swift Sources/PressureHapticsCoreTestRunner/main.swift
  git commit -m "feat: configure pressure haptic rate"
  ```

## Task 2: Select a pressure source for multi-touch frames

**Files:**
- Create: `Sources/PressureHapticsTrackpad/PressureSelectionStrategy.swift`
- Modify: `Sources/PressureHapticsTrackpad/PressureFrameProcessor.swift:3-58`
- Modify: `Sources/PressureHapticsTrackpadTestRunner/main.swift:23-97`

**Interfaces:**
- Consumes: `TrackpadTouchSample`, `TrackpadTouchPhase.isTouching`, and the rate-aware controller from Task 1.
- Produces: `PressureSelectionStrategy`, plus `PressureFrameProcessor.consume(_:timestamp:selectionStrategy:rate:) -> PressureFrameResult` with defaults `.maximum` and `0`.

- [ ] **Step 1: Write failing selection tests**

  Add samples for IDs 1, 2, and 3 with active pressures 200, 500, and 350. Verify maximum, average, ID selection, missing-ID behavior, and first-contact replacement.

  ```swift
  expect(
      processor.consume(
          touches, timestamp: 0, selectionStrategy: .average
      ).emission?.levelIndex == 3,
      "Average pressure must determine the emitted level"
  )
  expect(
      processor.consume(
          touches, timestamp: 0.01, selectionStrategy: .touch(id: 1)
      ).emission?.levelIndex == 0,
      "The selected touch ID must determine the emitted level"
  )
  expect(
      processor.consume(
          touches, timestamp: 0.02, selectionStrategy: .touch(id: 99)
      ).emission == nil,
      "A missing selected touch must not emit"
  )
  ```

  Use a separate processor for each strategy test, so rate-limiter state cannot affect the expected first emission. Add a first-touch test whose initial frame contains IDs 2 then 1, then remove ID 2 and verify ID 1 drives the next emission.

- [ ] **Step 2: Run the Trackpad runner to verify it fails**

  Run: `swift run pressure-haptics-trackpad-tests`

  Expected: compilation failure because `PressureSelectionStrategy` and the new `consume` arguments do not exist.

- [ ] **Step 3: Implement selection and contact ordering**

  Create the public enum exactly as follows:

  ```swift
  public enum PressureSelectionStrategy: Sendable, Hashable {
      case maximum
      case average
      case touch(id: Int32)
      case firstTouch
  }
  ```

  In `PressureFrameProcessor`, add `private var touchOrder: [Int32] = []`. On every frame, remove IDs not in `activeTouches`; append each active ID not already present, preserving frame order. Resolve the selected pressure with a private function:

  ```swift
  private func selectedPressure(
      from activeTouches: [TrackpadTouchSample],
      using strategy: PressureSelectionStrategy
  ) -> Float? {
      switch strategy {
      case .maximum:
          activeTouches.map(\.pressure).max()
      case .average:
          guard !activeTouches.isEmpty else { return nil }
          return activeTouches.map(\.pressure).reduce(0, +)
              / Float(activeTouches.count)
      case let .touch(id):
          activeTouches.first(where: { $0.id == id })?.pressure
      case .firstTouch:
          guard let id = touchOrder.first else { return nil }
          return activeTouches.first(where: { $0.id == id })?.pressure
      }
  }
  ```

  Pass `selectedPressure ?? 0` and `isTouching: selectedPressure != nil` to the controller. Pass `rate` to the controller. Continue assigning `maximumPressure` from `activeTouches.map(\.pressure).max() ?? 0`.

- [ ] **Step 4: Run the Trackpad runner to verify it passes**

  Run: `swift run pressure-haptics-trackpad-tests`

  Expected: `PressureHapticsTrackpad tests passed`.

- [ ] **Step 5: Commit multi-touch selection**

  ```bash
  git add Sources/PressureHapticsTrackpad/PressureSelectionStrategy.swift Sources/PressureHapticsTrackpad/PressureFrameProcessor.swift Sources/PressureHapticsTrackpadTestRunner/main.swift
  git commit -m "feat: select pressure source for multi-touch"
  ```

## Task 3: Add result notifications and directly trigger profile levels

**Files:**
- Modify: `Sources/PressureHapticsTrackpad/TrackpadPressureHaptics.swift:6-90`
- Modify: `Package.swift:4-49`
- Create: `Tests/PressureHapticsTrackpadTests/TrackpadPressureHapticsTests.swift`

**Interfaces:**
- Consumes: `PressureHapticProfile.levels`, `PressureFrameProcessor.consume(_:timestamp:selectionStrategy:rate:)`, and `RawHapticCommand` internally.
- Produces: `HapticTriggerResult`, `TrackpadPressureHaptics.rate`, `selectionStrategy`, `onHapticTrigger`, `triggerHaptic(level:)`, `startHaptic(level:)`, and `stopHaptic()`.

- [ ] **Step 1: Add an XCTest target and write failing direct-trigger tests**

  Add this target to `Package.swift` after the executable targets:

  ```swift
  .testTarget(
      name: "PressureHapticsTrackpadTests",
      dependencies: ["PressureHapticsCore", "PressureHapticsTrackpad"]
  ),
  ```

  In the XCTest file, use `@testable import PressureHapticsTrackpad` and an injected closure that delegates to a main-actor recorder. Test success, rejection, invalid levels, and direct repeat:

  ```swift
  @MainActor
  private final class HapticTriggerRecorder {
      var commands: [RawHapticCommand] = []
      var result = true

      func trigger(_ command: RawHapticCommand) -> Bool {
          commands.append(command)
          return result
      }
  }

  @MainActor
  func testDirectLevelReportsSuccess() {
      let recorder = HapticTriggerRecorder()
      let haptics = TrackpadPressureHaptics(
          calibration: .init(restingPressure: 100, maximumPressure: 600),
          hapticTrigger: recorder.trigger
      )
      var result: HapticTriggerResult?
      haptics.onHapticTrigger = { result = $0 }
      haptics.triggerHaptic(level: 4)

      XCTAssertEqual(recorder.commands.count, 1)
      XCTAssertEqual(result?.level, 4)
      XCTAssertEqual(result?.succeeded, true)
  }
  ```

  Add separate tests asserting that a false recorder result reports `succeeded == false`, and that level `8` makes no recorder call and reports `level == 8`, `succeeded == false`. Add an async `@MainActor` test that sets `rate = 20`, calls `startHaptic(level: 4)`, waits 160 milliseconds, calls `stopHaptic()`, and asserts at least three recorder commands; the immediate command plus the 50-millisecond repeats make this threshold deterministic.

- [ ] **Step 2: Run XCTest to verify it fails**

  Run: `swift test --filter TrackpadPressureHapticsTests`

  Expected: compilation failure because the test target, test-only initializer, and direct APIs do not exist.

- [ ] **Step 3: Implement result delivery, direct trigger, and direct repeat**

  Add the minimal public result type:

  ```swift
  public struct HapticTriggerResult {
      public let level: Int
      public let succeeded: Bool

      public init(level: Int, succeeded: Bool) {
          self.level = level
          self.succeeded = succeeded
      }
  }
  ```

  Store `profile` in `TrackpadPressureHaptics`. Add `rate` with a `didSet` that restores `oldValue` whenever the new value is negative or non-finite. Add `selectionStrategy = .maximum` and the optional callback.

  Add an internal initializer taking `hapticTrigger: @escaping (RawHapticCommand) -> Bool`. The public initializer passes a closure that calls the existing `OMSManager.triggerRawHaptic(actuationID:unknown1:unknown2:unknown3:)`. This keeps `RawHapticCommand` out of the new public direct API and lets XCTest control the success value.

  Implement a single private method that validates `level` against `1...profile.levels.count`, selects `profile.levels[level - 1].command`, invokes the stored closure, and calls `onHapticTrigger?(HapticTriggerResult(level:succeeded:))`. Use it from pressure emissions after converting `emission.levelIndex + 1`, and from `triggerHaptic(level:)`.

  `startHaptic(level:)` must call `stopHaptic()`, invoke the private method once immediately, then, only when `rate > 0` and the level is valid, create a `Task` that sleeps for `1 / rate` seconds and repeats the same private method until cancellation. `stopHaptic()` cancels and clears that task. Cancel it in `deinit` and `stop()` as well. Do not retain or emit the existing `print` logging.

  Pass `selectionStrategy` and `rate` when `consume(_:)` calls the frame processor.

- [ ] **Step 4: Run XCTest and executable runners to verify they pass**

  Run: `swift test`

  Expected: all XCTest tests pass, including the direct-result tests.

  Run: `swift run pressure-haptics-core-tests`

  Expected: `PressureHapticsCore tests passed`.

  Run: `swift run pressure-haptics-trackpad-tests`

  Expected: `PressureHapticsTrackpad tests passed`.

- [ ] **Step 5: Commit the public trigger API**

  ```bash
  git add Package.swift Sources/PressureHapticsTrackpad/TrackpadPressureHaptics.swift Tests/PressureHapticsTrackpadTests/TrackpadPressureHapticsTests.swift
  git commit -m "feat: expose direct haptic level triggers"
  ```

## Task 4: Verify package-wide behavior and API documentation

**Files:**
- Modify: `Sources/PressureHapticsTrackpad/TrackpadPressureHaptics.swift` only if compilation or test findings require a correction.
- Modify: `Sources/PressureHapticsTrackpad/PressureFrameProcessor.swift` only if compilation or test findings require a correction.
- Test: `Package.swift`, both executable test runners, and `Tests/PressureHapticsTrackpadTests/TrackpadPressureHapticsTests.swift`.

**Interfaces:**
- Consumes: all interfaces from Tasks 1-3.
- Produces: a clean build and behavior verified against the design specification.

- [ ] **Step 1: Build the package**

  Run: `swift build`

  Expected: build succeeds with no compiler warnings introduced by the new public API.

- [ ] **Step 2: Run all verification commands**

  Run: `swift test`

  Expected: all XCTest cases pass.

  Run: `swift run pressure-haptics-core-tests`

  Expected: `PressureHapticsCore tests passed`.

  Run: `swift run pressure-haptics-trackpad-tests`

  Expected: `PressureHapticsTrackpad tests passed`.

- [ ] **Step 3: Review the public API surface**

  Inspect the declarations in `TrackpadPressureHaptics.swift` and confirm the user-facing example compiles conceptually:

  ```swift
  haptics.rate = 10
  haptics.selectionStrategy = .average
  haptics.onHapticTrigger = { result in
      print("level=\(result.level) succeeded=\(result.succeeded)")
  }
  haptics.triggerHaptic(level: 4)
  ```

  Confirm that no new public method takes `RawHapticCommand`.

- [ ] **Step 4: Check the final diff**

  Run: `git diff --check HEAD~3..HEAD`

  Expected: no whitespace errors.

- [ ] **Step 5: Preserve a clean worktree after verification**

  Run: `git status --short`

  Expected: no output. Any source correction found during verification belongs in the task that owns that file and must be committed there with that task's commit message; do not create an empty verification commit.
