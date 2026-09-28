# PressureHapticsKit

macOSのトラックパッド圧力入力を取得し、圧力レベルに応じたハプティック出力へ変換するSwift Packageです。

## 動作条件

- macOS 13以上
- Xcode 16以上
- `OpenMultitouchSupport`が使用するPrivate Frameworkへの依存あり
- App Sandboxは無効化が必要
- アプリ内で`TrackpadPressureHaptics`を同時に開始するインスタンスは1つだけにする

## 基本利用

```swift
import PressureHapticsCore
import PressureHapticsTrackpad

let calibration = PressureCalibration(
    restingPressure: 100,
    maximumPressure: 600
)

let haptics = TrackpadPressureHaptics(calibration: calibration)

// EMA smoothing (alpha) and normalized hysteresis margin around each level.
haptics.pressureSmoothingFactor = 0.35
haptics.levelHysteresis = 0.02

haptics.onSelectedPressureSample = { pressure, touchCount in
    print(pressure as Any, touchCount)
}

haptics.onHapticTrigger = { result in
    print(result.level, result.succeeded)
}

guard haptics.start() else {
    print(haptics.lastStartError as Any)
    return
}
```

終了時は`stop()`を呼びます。callbackが`haptics`自身を強く参照する場合は、weak captureを使うか、`shutdown()`を呼んでcallbackを解放してください。

```swift
haptics.stop()
// callbackも不要になった場合
haptics.shutdown()
```

## 圧力差と重量

校正点を指定した`PressureWeightMeter`だけが実重量を返します。校正点がない場合は、互換動作としてタレとの差分を返します。未校正値を明示的に扱う場合は`pressureDelta(for:)`を使用してください。
