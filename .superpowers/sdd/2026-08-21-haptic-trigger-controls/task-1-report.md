# Task 1 Report: Configurable Pressure Repetition Rate

## Files changed

- `Sources/PressureHapticsCore/PressureHapticController.swift`
  - Added `rate: Double = 0` to `PressureHapticController.consume(...)` for source compatibility.
  - Added finite-positive rate validation and fixed interval eligibility (`1 / rate`).
  - Preserved level-change emissions and reset behavior.
  - Removed the pressure-dependent `minimumInterval(for:)` helper.
- `Sources/PressureHapticsCoreTestRunner/main.swift`
  - Updated `verifyRateLimit()` to validate rate 10 at timestamps 0.09 and 0.10.
  - Added and invoked `verifyZeroRateOnlyEmitsOnLevelChange()`.

## Tests and results

- `swift run pressure-haptics-core-tests` (before implementation): blocked by the environment before compilation; Swift could not write `/Users/oomuraruka/.cache/clang/.../SwiftShims-...pcm` (`Operation not permitted`).
- `swift run pressure-haptics-core-tests` (after implementation, with required elevated execution because of the same sandbox restriction): passed with `PressureHapticsCore tests passed`.
- `git diff --check`: passed.

The successful build emitted existing linker search-path warnings for CommandLineTools framework/library paths; the test runner still completed successfully.

## Commit

`feat: configure pressure haptic rate` (this report is included in the commit)

## Concerns

- The default `rate: 0` intentionally disables same-level repetition and emits only on the first selected level or a level change, as specified.
- The unprivileged test invocation remains unavailable in this environment due to Swift compiler cache/sandbox permissions; the same required command passed with elevated execution.
