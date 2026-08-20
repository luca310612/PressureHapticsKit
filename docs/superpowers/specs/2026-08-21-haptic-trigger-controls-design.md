# Haptic Trigger Controls Design

## Goal

PressureHapticsKit の中心である 1 始まりの触覚段階を、圧力入力と無関係な任意のタイミングでも使えるようにする。圧力連動時の連続発火頻度と、マルチタッチにおける圧力選択も設定可能にする。

## Public API

`TrackpadPressureHaptics` に以下を追加する。

```swift
public var rate: Double = 0
public var selectionStrategy: PressureSelectionStrategy = .maximum
public var onHapticTrigger: ((HapticTriggerResult) -> Void)?

public func triggerHaptic(level: Int)
public func startHaptic(level: Int)
public func stopHaptic()
```

- `level` は 1 始まりであり、既定の `.sevenStage` プロファイルでは `1...7` を受け入れる。
- `triggerHaptic(level:)` は 1 回だけ即時に振動を試みる。圧力入力と `rate` は参照しない。
- `startHaptic(level:)` は指定段階の連続振動を開始する。開始時に 1 回発火を試み、その後は `rate` 回/秒で発火を試みる。`rate == 0` では開始時の 1 回だけを発火する。
- `stopHaptic()` は直接連続振動を停止する。
- `rate` は `0` 以上の有限値とする。不正な値（負数、無限大、NaN）を代入した場合は、直前の有効値を維持する。`0` は連続振動を無効にする。正数では、発火間隔を `1 / rate` 秒とする。ライブラリ固有の上限は設けない。
- `rate` の既定値は `0`。圧力連動は段階変化時だけ発火し、通常のトラックパッドクリックはこの設定の影響を受けない。

## Trigger Results

振動を試行するたび、設定済みの場合だけ `onHapticTrigger` を呼ぶ。

```swift
public struct HapticTriggerResult {
    public let level: Int
    public let succeeded: Bool
}

public var onHapticTrigger: ((HapticTriggerResult) -> Void)?
```

- クロージャは `HapticTriggerResult` を受け取り、値を返さない。
- `level` は公開 API と同じ 1 始まりで通知する。
- 有効範囲外の段階指定では OMS を呼ばず、`succeeded == false` を通知する。
- OMS の `triggerRawHaptic(...)` が `false` を返した場合も、`succeeded == false` を通知する。
- 既存の標準出力だけに依存する通知を、コールバックへ置き換える。

## Pressure Timing

`PressureHapticController` は圧力から選択した段階が変化したとき、常に即時に発火候補を返す。同一段階を保持中の追加発火は `rate` に従う。

- `rate == 0`: 同一段階の追加発火はしない。
- `rate > 0`: 最後の発火から `1 / rate` 秒以上経過していれば追加発火する。
- 現在の圧力依存の内部式 `0.24 - 0.12 * normalizedPressure` は削除する。

## Multi-touch Selection

`PressureSelectionStrategy` を `PressureHapticsTrackpad` に追加する。

```swift
public enum PressureSelectionStrategy: Sendable, Hashable {
    case maximum
    case average
    case touch(id: Int32)
    case firstTouch
}
```

- `.maximum` は接触中の最大圧力を選ぶ。既定値であり、現行動作と互換にする。
- `.average` は接触中の全指の平均圧力を選ぶ。
- `.touch(id:)` は指定 ID の指が接触中の場合だけその圧力を選ぶ。対象がいなければ圧力連動発火をしない。
- `.firstTouch` は現在の接触セッションで最初に接触した指を選ぶ。選択中の指が離れた場合は、残っている接触指のうち最も早く接触した指へ切り替える。
- `PressureFrameProcessor` が接触 ID の順序を保持する。接触が完全になくなったとき、順序をリセットする。

`PressureFrameResult.maximumPressure` と `TrackpadPressureHaptics.onPressureSample` は、選択方式にかかわらず、従来どおり実際の最大圧力を提供する。圧力連動で段階を選ぶ入力だけが選択方式に従う。

## Internal Boundaries

- `PressureHapticsCore` はプロファイル選択と圧力連動の発火時刻判定を担う。OMS には依存しない。
- `PressureHapticsTrackpad` はタッチ選択、OMS の実行、結果コールバック、直接連続振動タスクを担う。
- `RawHapticCommand` を引数に取る新しい公開 API は追加しない。呼び出し側は段階番号だけを扱う。

## Verification

既存の実行可能テストへ、少なくとも以下を追加する。

1. `rate == 0` では段階変化時のみ発火する。
2. `rate == 10` では同一段階で 0.1 秒ごとに発火できる。
3. 最大・平均・指定 ID・最初の接触指が正しい圧力を選ぶ。
4. `.firstTouch` の選択指が離れた場合に次の最古の接触指へ移る。
5. 空フレームで連続発火状態と接触順がリセットされる。
6. `onPressureSample` と `maximumPressure` が最大圧力という従来の意味を保つ。
7. 直接発火とコールバックは、OMS 呼び出しを差し替えられる内部アダプタを使って、成功・失敗・範囲外段階を検証する。

## Compatibility

ソース互換性を維持する。既存のイニシャライザ引数はそのまま使え、追加した設定は既定値を持つ。動作上は、同一段階の自動連続発火が既定で無効になる。連続発火が必要な呼び出し側は `rate` を明示設定する。
