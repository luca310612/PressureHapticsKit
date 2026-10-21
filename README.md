# PressureHapticsKit

macOSのトラックパッド圧力入力を取得し、圧力レベルに応じたハプティック出力へ変換するSwift Packageです。

## 動作条件

- macOS 13以上
- Xcode 16以上
- `OpenMultitouchSupport`が使用するPrivate Frameworkへの依存あり
- App Sandboxは無効化が必要
- アプリ内で`TrackpadPressureHaptics`を同時に開始するインスタンスは1つだけにする

## 内部構造

サンプル化した接触データは、Trackpad層の選択処理からCore層の判定を経て、Trackpad層の出力処理へ進みます。

1. `PressureFrameProcessor`が有効な接触点を取り出し、選択方針に従って最大・平均・指定点・最初の接触点のいずれかの生圧力を選びます。
2. `PressureHapticController`が校正値で圧力を正規化し、プロファイルとヒステリシス、出力間隔からハプティックレベルを決めます。
3. `TrackpadPressureHaptics`が選ばれたレベルのnative commandをOMS（OpenMultitouchSupport）へ送り、結果をcallbackで通知します。

`PressureWeightMeter`はこの自動出力経路とは独立しており、アプリが圧力callbackの値を渡して使います。各型・callback・データ経路の詳細は[構造・実装ガイド](docs/ARCHITECTURE.md)を参照してください。

## 基本利用

```swift
import PressureHapticsCore
import PressureHapticsTrackpad

let calibration = PressureCalibration(
    restingPressure: 100,
    maximumPressure: 600
)

let haptics = TrackpadPressureHaptics(calibration: calibration)

haptics.onSelectedPressureSample = { pressure, touchCount in
    print(pressure as Any, touchCount)
}

haptics.onHapticTrigger = { result in
    // The default profile reports an integer level from 1 through 7.
    // The level count is freely configurable (see below).
    print(result.level, result.succeeded)
}

guard haptics.start() else {
    print(haptics.lastStartError as Any)
    return
}
```

正規化圧力は 0〜10 のスケールです。`PressureCalibration.normalize(_:)` もプロファイル閾値・ヒステリシスも同じスケールを共有します。

終了時は`stop()`を呼びます。callbackが`haptics`自身を強く参照する場合は、weak captureを使うか、`shutdown()`を呼んでcallbackを解放してください。

```swift
haptics.stop()
// callbackも不要になった場合
haptics.shutdown()
```

## 段階数の設定

レベル数・閾値・強さは自由に設定できます。既定の `.sevenStage`（7段階）のほか、レベル数だけ指定した等間隔プロファイルや、閾値を個別指定したプロファイルを `TrackpadPressureHaptics` の `profile` プロパティに割り当てます。監視中でも差し替えられます。

```swift
// レベル数だけ指定（閾値・強さは等間隔で自動生成）
haptics.profile = try PressureHapticProfile.linear(levelCount: 5)

// 閾値と強さを個別指定（正規化圧力 0〜10 のスケール）
haptics.profile = try PressureHapticProfile.custom(
    thresholds: [2, 5, 8],
    intensities: [0.75, 1.25, 2.0],
    actuationIDs: [3, 4, 6]
)

// コマンド全体を制御する場合（rawParameter1 / rawParameter3 も指定）
haptics.profile = try PressureHapticProfile(levels: [
    .init(lowerBound: 2.5, command: .init(
        actuationID: 3, rawParameter1: 0,
        rawParameter2: 0.7, rawParameter3: 2
    )),
])
```

## 圧力差と重量

校正点を指定した`PressureWeightMeter`だけが実重量を返します。校正点がない場合は、互換動作としてタレとの差分を返します。未校正値を明示的に扱う場合は`pressureDelta(for:)`を使用してください。

## ローカル依存と検証

`OpenMultitouchSupport` の Swift ラッパーは [Vendor/OpenMultitouchSupport](Vendor/OpenMultitouchSupport/README.md) に取り込んでいます。元の1.0.12を基に、同期入力購読と起動失敗処理を修正しています。native XCFramework は元のバージョンとchecksumに固定されています。

入力は最新1フレームに集約し、接触順・接触寿命を保持します。取得後100msを超えたフレームからの自動振動を抑止します。圧力・接触終了の通知は維持します。

```sh
swift test
swift run pressure-haptics-core-tests
swift run pressure-haptics-trackpad-tests
swift build -c release
```
