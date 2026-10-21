import Foundation
import PressureHapticsCore
import PressureHapticsTrackpad

@main
@MainActor
struct PressureHapticsRawDataRunner {
    static func main() {
        let calibration = PressureCalibration(
            restingPressure: 100,
            maximumPressure: 600
        )
        let profile = PressureHapticProfile.sevenStage
        let haptics = TrackpadPressureHaptics(
            calibration: calibration,
            profile: profile
        )

        haptics.onTouchFrame = { touches in
            for touch in touches where touch.phase.isTouching {
                print("pressure[\(touch.id)] = \(touch.pressure)")
            }
        }

        haptics.onHapticTrigger = { result in
            guard profile.levels.indices.contains(result.level - 1) else {
                print("haptic level \(result.level): failed")
                return
            }

            let command = profile.levels[result.level - 1].command
            print(
                "haptic level \(result.level): "
                    + "actuationID=\(command.actuationID), "
                    + "rawParameter1=\(command.rawParameter1), "
                    + "rawParameter2=\(command.rawParameter2), "
                    + "rawParameter3=\(command.rawParameter3), "
                    + "succeeded=\(result.succeeded)"
            )
        }

        print("接触ごとの圧力値を表示します。Ctrl-C で終了します。")
        guard haptics.start() else {
            print("トラックパッドの監視を開始できません: \(String(describing: haptics.lastStartError))")
            return
        }

        RunLoop.main.run()
    }
}
