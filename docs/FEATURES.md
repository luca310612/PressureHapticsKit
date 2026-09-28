# PressureHapticsKit 機能ガイド

PressureHapticsKit は、Mac のトラックパッドから圧力と接触情報を読み取り、圧力レベルに応じたハプティック出力へ変換する Swift Package です。圧力処理だけを行う `PressureHapticsCore` と、実機のトラックパッドに接続する `PressureHapticsTrackpad` で構成されています。

## 目次

- [動作条件とパッケージ構成](#動作条件とパッケージ構成)
- [セットアップと基本利用](#セットアップと基本利用)
- [処理の流れ](#処理の流れ)
- [圧力校正](#圧力校正)
- [ハプティックプロファイルと制御](#ハプティックプロファイルと制御)
- [複数接触点とフレーム処理](#複数接触点とフレーム処理)
- [重量メーターとタレ](#重量メーターとタレ)
- [トラックパッド監視とハプティック操作](#トラックパッド監視とハプティック操作)
- [デモアプリ](#デモアプリ)
- [公開 API 一覧](#公開-api-一覧)
- [制約と注意点](#制約と注意点)

## 動作条件とパッケージ構成

- macOS 13 以降、Xcode 16 以降（Swift tools 6.0）。
- トラックパッド接続層は `OpenMultitouchSupport` に依存し、macOS の Private Framework を利用します。
- トラックパッド入力には App Sandbox を無効にしたアプリが必要です。
- `TrackpadPressureHaptics` は共有の `OMSManager` を使うため、同時に監視を開始できるインスタンスはプロセス内で1つです。

| Product | 用途 |
| --- | --- |
| `PressureHapticsCore` | 校正、圧力レベル選択、ハプティック出力の判断、タレ・重量換算。トラックパッドへの接続なしで利用可能。 |
| `PressureHapticsTrackpad` | 実機入力、接触フレーム処理、ハプティック送信。Core に加えて `OpenMultitouchSupport` を利用。 |
| `pressure-haptics-demo` | SwiftUI 製の実機デモアプリ。 |

## セットアップと基本利用

Swift Package として依存に追加し、必要なモジュールを import します。以下は `PressureHapticsTrackpad` を使った最小例です。

```swift
import PressureHapticsCore
import PressureHapticsTrackpad

let calibration = PressureCalibration(
    restingPressure: 100,
    maximumPressure: 600
)
let haptics = TrackpadPressureHaptics(calibration: calibration)

haptics.onSelectedPressureSample = { pressure, touchCount in
    print("selected pressure:", pressure as Any, "touches:", touchCount)
}
haptics.onHapticTrigger = { result in
    print("level:", result.level, "sent:", result.succeeded)
}

guard haptics.start() else {
    print("Could not start:", haptics.lastStartError as Any)
    return
}
```

監視を終えるときは `stop()` を呼びます。オブジェクトを破棄する際に callback も確実に解放したい場合は `shutdown()` を使います。

```swift
haptics.stop()
haptics.shutdown() // stop に加えて登録済み callback を nil にする
```

`TrackpadPressureHaptics` とその callback は `@MainActor` 上で扱います。長く保持する callback からインスタンス自身を参照すると循環参照になることがあるため、通常は `[weak haptics]` や `[weak self]` を使います。

## 処理の流れ

1. `PressureCalibration` が生の圧力を 0〜1 に正規化します。
2. `PressureFrameProcessor` が接触中の点を抽出し、設定された選択方法と EMA 平滑化で圧力をまとめます。
3. `PressureHapticController` がプロファイルの閾値、ヒステリシス、発火レートから出力レベルを判断します。
4. `TrackpadPressureHaptics` が対応する低レベルコマンドを `OMSManager` に渡します。

Core の構造体を直接使えば、実機入力を使わずにフレームや合成圧力を処理できます。

## 圧力校正

### 正規化

`PressureCalibration(restingPressure:maximumPressure:)` で安静時圧力と最大圧力を指定します。`normalize(_:)` は次の式で計算し、結果を 0〜1 に収めます。

```text
(pressure - restingPressure) / (maximumPressure - restingPressure)
```

安静時以下は 0、最大圧力以上は 1 です。値が有限でない場合や校正範囲が不正な場合は 0 を返します。通常の initializer は校正値を自動検証しないため、入力値を検証したい場合は `validate()` または throwing initializer を使います。

```swift
let calibration = try PressureCalibration(
    validatingRestingPressure: 100,
    maximumPressure: 600
)
try calibration.validate()
```

### 圧力からグラムへの校正

`massPoints` に圧力と質量の対応点を2点以上渡すと、`grams(for:)` が区分線形補間を行います。範囲外は最小点または最大点の質量に丸めます。対応点なしの場合は `nil` です。

```swift
let calibration = PressureCalibration(
    restingPressure: 100,
    maximumPressure: 600,
    massPoints: [
        .init(pressure: 100, grams: 0),
        .init(pressure: 300, grams: 400),
        .init(pressure: 600, grams: 1_000),
    ]
)
let normalized = calibration.normalize(350)
let gramsAtPressure = calibration.grams(for: 350)
```

`validate()` は次を確認します。

- 安静時圧力と最大圧力が有限で、最大値が安静時より大きい。
- 質量点は未指定、または2点以上。
- 各点の圧力・グラム値が有限で、グラム値が0以上。
- 圧力値は厳密な昇順、グラム値は非減少。

検証時のエラーは `PressureCalibrationError` の `.invalidRange`、`.insufficientMassPoints`、`.invalidMassPoint(index:)`、`.massPointsMustBeAscending` です。`grams(for:)` は点を圧力順に並べ直して妥当性を確認するため、順番を含めて事前に保証したい場合は `validate()` を呼びます。

## ハプティックプロファイルと制御

### 標準7段階プロファイル

標準の `PressureHapticProfile.sevenStage` は、正規化圧力に対して次の7段階を定義します。閾値未満ではレベルは選択されません。

| レベル | 閾値 | actuation ID | rawParameter2 |
| ---: | ---: | ---: | ---: |
| 1 | 0.1500 | 3 | 0.50 |
| 2 | 0.2714 | 3 | 0.75 |
| 3 | 0.3929 | 4 | 1.00 |
| 4 | 0.5143 | 4 | 1.25 |
| 5 | 0.6357 | 4 | 1.50 |
| 6 | 0.7571 | 6 | 1.75 |
| 7 | 0.8786 | 6 | 2.00 |

全レベルで `rawParameter1` は 0、`rawParameter3` は 2 です。

### 独自プロファイル

`PressureHapticProfile(levels:)` に、昇順の閾値と各レベルの `RawHapticCommand` を指定します。閾値は有限かつ 0〜1、rawParameter2/3 は有限である必要があります。空配列、無効な閾値・コマンド、昇順でない閾値は `PressureHapticProfileError` になります。

```swift
let profile = try PressureHapticProfile(levels: [
    .init(lowerBound: 0.25, command: .init(
        actuationID: 3, rawParameter1: 0,
        rawParameter2: 0.7, rawParameter3: 2
    )),
    .init(lowerBound: 0.70, command: .init(
        actuationID: 6, rawParameter1: 0,
        rawParameter2: 1.6, rawParameter3: 2
    )),
])
```

`selection(for:)` は閾値以下のうち最も高いレベルを返し、入力圧力は 0〜1 に丸めます。最初の閾値より小さい場合や入力が有限でない場合は `nil` です。ヒステリシス付き overload は現在のレベルを閾値の上下に指定幅だけ維持します。

### 圧力に応じた発火

`PressureHapticController.consume(pressure:isTouching:timestamp:rate:)` は `HapticEmission?` を返します。

- 接触中に初めて閾値へ達したとき、またはレベルが変わったときに出力候補を返す。
- `rate > 0` の場合、同じレベルの再出力を指定間隔（1 / rate 秒）で許可する。`rate == 0` ではレベル変化時だけ出力する。
- 接触終了、閾値未満、または不正な時刻で発火状態をリセットする。
- `levelHysteresis` の初期値は 0.02（正規化圧力単位）。許容範囲は 0〜1。

`HapticEmission` は正規化圧力、計算された `intensity`、0始まりの `levelIndex`、低レベル `command` を持ちます。Trackpad 層が実際に送るのはプロファイルに保存された `command` です。

## 複数接触点とフレーム処理

### 接触サンプル

`TrackpadTouchSample` は接触 ID、位置、圧力、状態に加えて、総容量 `total`、接触楕円の軸 `axis`、角度 `angle`、密度 `density`、元データの文字列表現の時刻 `timestamp` を保持します。後ろ5項目には既定値があり、手動生成時に省略できます。

`TrackpadTouchPhase.isTouching` は `.starting`、`.hovering`、`.making`、`.touching`、`.breaking`、`.lingering` を接触中として扱います。`.notTouching` と `.leaving` は非接触です。

### 圧力選択

`PressureSelectionStrategy` は自動ハプティックや選択圧力 callback に使う圧力の決め方です。

| 戦略 | 選択値 |
| --- | --- |
| `.maximum` | 接触中の点の最大圧力（既定値） |
| `.average` | 接触中の圧力の平均 |
| `.touch(id:)` | 指定 ID の接触圧力。該当点がない場合は選択なし。 |
| `.firstTouch` | 現在の接触セッションで最初に現れ、まだ接触中の点。 |

非有限圧力の接触点と非接触状態はフレーム処理から除外されます。最大圧力値は選択戦略にかかわらず別途集計されます。

### 平滑化とフレーム結果

`PressureFrameProcessor` は選択圧力に指数移動平均（EMA）を適用します。

```text
filtered = sample * smoothingFactor + previousFiltered * (1 - smoothingFactor)
```

`smoothingFactor` の範囲は (0, 1]、既定値は 0.35 です。1 にすると平滑化しません。係数を変えると保存済みの平滑化値がリセットされます。`levelHysteresis` の既定値は 0.02 です。時刻が逆行した場合や `reset()` 時は平滑化状態も消去されます。

`consume(_:timestamp:selectionStrategy:rate:)` が返す `PressureFrameResult` には以下が含まれます。

- `maximumPressure`: 有効な接触点の最大圧力。接触点がなければ 0。
- `selectedPressure` / `currentPressure`: 選択戦略で決まった現在圧力。選択できない場合は `nil`。
- `activeTouchCount`: 有効な接触点の数。
- `emission`: 今フレームで出力すべき `HapticEmission`。出力不要なら `nil`。

## 重量メーターとタレ

`PressureWeightMeter` は圧力値をタレ基準の値に変換し、現在値とピーク値を追跡します。

```swift
var meter = PressureWeightMeter(calibration: calibration)
meter.tare(rawPressure: 100)       // 物体を載せていない状態でゼロ設定
let current = meter.update(rawPressure: 180)
let peak = meter.peakGrams
```

- `tare(rawPressure:)`: 有限な圧力をゼロ点に設定し、現在値とピーク値を0にする。
- `resetTare()`: ゼロ点と現在値を消去し、ピークを0にする。
- `resetPeak()`: タレ値を保ったままピークだけを0にする。
- `update(rawPressure:)`: 現在値を更新する。タレ未設定または圧力不正なら `nil` を返し、`currentGrams` も `nil` にする。
- `resetThresholdGrams`: 更新値がこの閾値以下になると、物体を取り除いたものとしてピークを0に戻す。既定値は1。質量校正がない場合は圧力単位の差分と比較されます。

質量校正点が2つ以上ある場合は、校正から得た質量とタレ時の質量との差をグラムで返します。校正点がない場合は後方互換のため、生圧力のタレとの差分を返します。この場合、プロパティ名が `currentGrams` / `peakGrams` でも値はグラムではなく圧力単位です。単位の誤解を避けるには `pressureDelta(for:)` を使います。

## トラックパッド監視とハプティック操作

### 入力 callback

`TrackpadPressureHaptics` は接触フレームごとに次の callback を呼びます。

| Callback | 内容 |
| --- | --- |
| `onTouchFrame` | 有効な接触圧力を持つ接触点と、非接触状態の点を含むフレーム。接触中で圧力が非有限の点は除外。 |
| `onPressureSample` | 有効な接触中の最大圧力と接触数。接触がなければ圧力0・接触数0。 |
| `onSelectedPressureSample` | 選択戦略で得た圧力（該当なしなら `nil`）と接触数。 |
| `onHapticTrigger` | 送信を試みた1始まりのレベルと、ドライバーが返した成否。無効レベルでは送信せず `false` を通知。 |

### 開始・停止とエラー

- `start()` は監視を開始できたら `true`。すでに自分が監視中なら `true` を返す。
- ほかのインスタンスが監視中、または共有 listener がすでに使用中なら `false`、`lastStartError == .alreadyListening`。
- listener の起動に失敗した場合は `false`、`lastStartError == .listenerUnavailable`。
- `stop()` は入力監視と繰り返しハプティックを止め、フレーム処理の状態をリセットする。
- `shutdown()` は `stop()` に加えて4つの callback を `nil` にする。
- `isListening` は本インスタンスが開始した listener と受信タスクが両方稼働中かを示す。

### 自動・手動ハプティック

`isAutomaticHapticsEnabled` は圧力フレームからの自動出力だけを有効／無効にします。既定値は `true` です。切替時に圧力処理状態をリセットします。タッチ／圧力 callback と手動出力は無効化されません。

```swift
haptics.selectionStrategy = .firstTouch
haptics.pressureSmoothingFactor = 0.5
haptics.levelHysteresis = 0.03
haptics.rate = 8 // 最大8回/秒の同一レベル再出力、および手動反復の頻度

haptics.triggerHaptic(level: 4) // 1回送信
haptics.startHaptic(level: 4)   // 即時送信し、rate > 0 なら繰り返す
haptics.stopHaptic()            // 手動の繰り返しを停止
```

レベル番号は1から始まり、範囲は `1...profile.levels.count` です。`rate` は有限かつ0以上である必要があり、不正値を代入すると以前の値を維持します。手動反復中に `rate` を変えると、反復タスクを新しい頻度で再作成します。`stop()` と deinit でも反復タスクは停止します。

## デモアプリ

`swift run pressure-haptics-demo` で SwiftUI デモを起動できます。画面には正規化圧力、タレとの差分相当の現在値・ピーク値、接触数、直近のハプティックレベルと成否、監視状態が表示されます。監視の開始・停止、自動出力の切替、タレ設定、レベル1〜7の手動出力を試せます。

デモの校正は安静時100・最大600で、質量点を指定していません。そのため表示される「圧力差相当」は実重量ではなくタレからの圧力差です。接触イベントが消えたあとも圧力値を保持し、接触が2秒間戻らないと表示値をリセットします。

## 公開 API 一覧

### `PressureHapticsCore`

| 型 | 主な公開要素 |
| --- | --- |
| `PressureCalibrationPoint` | `pressure`, `grams`, `init(pressure:grams:)` |
| `PressureCalibration` | `restingPressure`, `maximumPressure`, `massPoints`; 通常／検証付き initializer; `validate()`, `normalize(_:)`, `grams(for:)` |
| `PressureCalibrationError` | `.invalidRange`, `.insufficientMassPoints`, `.invalidMassPoint(index:)`, `.massPointsMustBeAscending` |
| `PressureWeightMeter` | `calibration`, `zeroOffset`, `currentGrams`, `peakGrams`, `resetThresholdGrams`, `isMassCalibrated`; `tare`, `resetTare`, `resetPeak`, `update`, `grams`, `pressureDelta` |
| `RawHapticCommand` | `actuationID`, `rawParameter1`, `rawParameter2`, `rawParameter3` |
| `PressureHapticLevel` | `lowerBound`, `command` |
| `PressureHapticProfile` | `levels`, throwing `init(levels:)`, `selection(for:)`, `selection(for:previousIndex:hysteresis:)`, `.sevenStage` |
| `PressureHapticProfileError` | `.emptyLevels`, `.invalidLowerBound(index:)`, `.invalidCommand(index:)`, `.levelsMustBeStrictlyAscending` |
| `HapticEmission` | `normalizedPressure`, `intensity`, `levelIndex`, `command` |
| `PressureHapticController` | `init(calibration:profile:levelHysteresis:)`, `levelHysteresis`, `reset()`, `consume(pressure:isTouching:timestamp:rate:)` |

### `PressureHapticsTrackpad`

| 型 | 主な公開要素 |
| --- | --- |
| `TrackpadTouchPhase` | 8状態、`allCases`, `isTouching` |
| `TrackpadTouchSample` | `id`, `position`, `pressure`, `phase`, `total`, `axis`, `angle`, `density`, `timestamp` と initializer |
| `PressureSelectionStrategy` | `.maximum`, `.average`, `.touch(id:)`, `.firstTouch` |
| `PressureFrameResult` | `currentPressure`, `maximumPressure`, `selectedPressure`, `activeTouchCount`, `emission` |
| `PressureFrameProcessor` | `init(calibration:profile:smoothingFactor:levelHysteresis:)`, `smoothingFactor`, `levelHysteresis`, `reset()`, `consume(_:timestamp:selectionStrategy:rate:)` |
| `HapticTriggerResult` | `level`, `succeeded` |
| `TrackpadPressureHapticsStartError` | `.alreadyListening`, `.listenerUnavailable` |
| `TrackpadPressureHaptics` | `selectionStrategy`, `pressureSmoothingFactor`, `levelHysteresis`, `isAutomaticHapticsEnabled`, `rate`, `isListening`, `lastStartError`, 4つの callback、`start`, `stop`, `shutdown`, `triggerHaptic`, `startHaptic`, `stopHaptic` |
| `TrackWeightPressureHaptics` | 旧名の非推奨 typealias。`TrackpadPressureHaptics` へ移行。 |

## 制約と注意点

- トラックパッド接続機能は macOS 専用です。Core の純粋な計算型は実機 listener を必要としません。
- Private Framework の依存があるため、OS 更新による互換性や配布要件の影響を受ける可能性があります。
- `start()` の成功は入力 listener の開始を示します。実際のハプティック送信成否は `onHapticTrigger` の `succeeded` で確認してください。
- 圧力校正値と質量校正値は利用環境・機器に合わせて設定してください。質量点が未設定の `PressureWeightMeter` は実重量を測定しません。
