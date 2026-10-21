# Local OpenMultitouchSupport wrapper

Copied from OpenMultitouchSupport 1.0.12, commit
`1a4aeff416773ae04bfce515f94b872cfa2c47ba`:
https://github.com/KrishKrosh/OpenMultitouchSupport

Only the Swift wrapper, package manifest, and upstream MIT license are vendored.
The native XCFramework still uses the original 1.0.12 URL and SHA-256 checksum
in `Package.swift`; no native binary or build cache is copied here.

Local changes in `OMSManager.swift`:

- `observeTouchFrames` exposes synchronous input-thread delivery and captures
  monotonic arrival time before conversion. PressureHapticsKit can therefore
  coalesce frames without first creating the upstream unbounded AsyncStream.
- `startListening()` returns false when native listener creation returns nil.
  Checking the existing listener and installing the new one happen under one
  lock, and `stopListening()` removes the listener and clears it under one
  lock, so concurrent start/stop calls can no longer leak or remove a listener
  more than once.

PressureHapticsKit owns the bounded buffer, contact tracking, and freshness
checks. Its tests run with injected input and haptic implementations.
