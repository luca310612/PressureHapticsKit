# 100項目レビューの実装トリアージ

この表は、レビューで挙げた100項目を「コードで直せるもの」と「実測・生物データが無いと断定できないもの」に分けた記録です。

- **FIXED**: 実装とテストで確認済み。
- **PARTIAL**: 実装上の境界・表示・検証条件まで整備済み。データ投入後の検証が残る。
- **UNCONNECTED**: MaleCNS/生物計測データが無いため、推測で埋めず明示的に未接続。

## システムの主張と再現性

| # | 指摘 | 状態 |
|---:|---|---|
| 1 | MaleCNS接続済みのように読める説明 | FIXED |
| 2 | 実際のconnectomeローダーが無い | UNCONNECTED |
| 3 | connectomeデータの出典・版・hashが無い | UNCONNECTED |
| 4 | モデルバージョンと変換条件が固定されていない | UNCONNECTED |
| 5 | demo回路と生物バックエンドのモード境界が無い | FIXED |
| 6 | 起動時の機能一覧が分からない | FIXED |
| 7 | 未接続状態を実接続として扱う危険 | FIXED |
| 8 | 神経状態のcheckpointが無い | UNCONNECTED |
| 9 | 長時間実験のreplay形式が無い | PARTIAL |
| 10 | 乱数と初期条件の再現性が弱い | FIXED |
| 11 | FlyGymの単位系がコードから不明 | FIXED |
| 12 | 完了条件・受入条件が明文化されていない | PARTIAL |

## 生物学的妥当性

| # | 指摘 | 状態 |
|---:|---|---|
| 13 | 対象個体（雄雌・成虫）の宣言が無い | UNCONNECTED |
| 14 | 神経細胞数の根拠が無い | UNCONNECTED |
| 15 | シナプス数の根拠が無い | UNCONNECTED |
| 16 | lamina/medulla/lobula等の対応が無い | UNCONNECTED |
| 17 | central complexの対応が無い | UNCONNECTED |
| 18 | ventral nerve cordの対応が無い | UNCONNECTED |
| 19 | motor neuropilの対応が無い | UNCONNECTED |
| 20 | 神経伝達物質の符号が無い | UNCONNECTED |
| 21 | 部位ごとの伝達遅延が無い | UNCONNECTED |
| 22 | 軸索伝導時間が無い | UNCONNECTED |
| 23 | 不応期の生理根拠が無い | UNCONNECTED |
| 24 | 適応・恒常性の生理根拠が無い | UNCONNECTED |
| 25 | 神経調節の根拠が無い | UNCONNECTED |
| 26 | 個体差・発達差を扱っていない | UNCONNECTED |
| 27 | FlyGym bodyとconnectome個体の対応が無い | UNCONNECTED |
| 28 | 視覚以外の感覚入力が無い | UNCONNECTED |
| 29 | proprioceptionの入力が無い | UNCONNECTED |
| 30 | mechanosensationの入力が無い | UNCONNECTED |
| 31 | 生物計測への校正手順が無い | UNCONNECTED |
| 32 | 生物学的な予測検証が無い | UNCONNECTED |

## NumPy回路と数値計算

| # | 指摘 | 状態 |
|---:|---|---|
| 33 | デモ回路の重みがランダム | UNCONNECTED |
| 34 | 層のサイズが生物学的根拠なし | UNCONNECTED |
| 35 | 膜電位・電流の単位が無い | UNCONNECTED |
| 36 | 物理刻みと神経刻みが不一致 | FIXED |
| 37 | 実connectomeのスパイク力学でない | UNCONNECTED |
| 38 | 再帰回路の数値安定性を未検証 | FIXED |
| 39 | シナプス重みの出典が無い | UNCONNECTED |
| 40 | シナプス遅延を回路に実装していない | UNCONNECTED |
| 41 | 生理的な不応期を回路に実装していない | UNCONNECTED |
| 42 | spike countが状態値と混同されている | FIXED |
| 43 | 初期化seedが暗黙的 | FIXED |
| 44 | 入力範囲外を黙ってclipする | FIXED |
| 45 | 出力の符号と神経役割が未定義 | UNCONNECTED |
| 46 | 連続motor outputが結果に無い | FIXED |
| 47 | 回路パラメータの外部ファイル化が無い | UNCONNECTED |
| 48 | 入力→活動の因果テストが無い | FIXED |
| 49 | snapshotのNumPy配列がmutable | FIXED |
| 50 | NaN・inf・負のcountの防御が無い | FIXED |

## 視覚・retina mapping

| # | 指摘 | 状態 |
|---:|---|---|
| 51 | raw eye画像とommatidia入力が別経路 | PARTIAL |
| 52 | RGB→luminanceが近似 | UNCONNECTED |
| 53 | 4×4 poolingが任意 | UNCONNECTED |
| 54 | photoreceptor応答モデルが無い | UNCONNECTED |
| 55 | 色スペクトルの校正が無い | UNCONNECTED |
| 56 | motion fieldの校正が無い | UNCONNECTED |
| 57 | 視角・画角の校正が無い | UNCONNECTED |
| 58 | 左右眼の向きの校正が無い | UNCONNECTED |
| 59 | 両眼差分の処理が無い | UNCONNECTED |
| 60 | retina対応表を推測で作っていた | FIXED |
| 61 | mapping fileの必須配列が未検証 | FIXED |
| 62 | mapping配列のdtype・shapeが未検証 | FIXED |
| 63 | target sizeが未検証 | FIXED |
| 64 | readoutの正規化範囲が未検証 | FIXED |
| 65 | blank/flash/motionの因果テストが無い | FIXED |
| 66 | 存在しないommatidium参照を検出しない | FIXED |
| 67 | raw frameの画素範囲と形状が未検証 | FIXED |

## FlyGym・MuJoCo・表示

| # | 指摘 | 状態 |
|---:|---|---|
| 68 | ハエを固定する理由と機構が曖昧 | FIXED |
| 69 | 自由飛行・歩行が実装されていない | UNCONNECTED |
| 70 | 関節actuatorがゼロだった | FIXED |
| 71 | 神経出力→関節の接続が無かった | PARTIAL |
| 72 | 床の衝突が無効だった | FIXED |
| 73 | projectileの単位が他のコードと不一致 | FIXED |
| 74 | gravcomp付きの人工刺激であることが不明 | PARTIAL |
| 75 | projectileのbody位置とqposが不一致 | FIXED |
| 76 | 発射速度が根拠なく固定値 | PARTIAL |
| 77 | projectileの接触条件が未検証 | FIXED |
| 78 | cameraの初期視野がハエと刺激を外していた | FIXED |
| 79 | flyが暗く、表示上のコントラストが低い | FIXED |
| 80 | checker textureの遠景aliasing | PARTIAL |
| 81 | floor接触フラグの回帰テストが無い | FIXED |
| 82 | 短時間rolloutの有限性テストが無い | FIXED |

## 時間・closed loop

| # | 指摘 | 状態 |
|---:|---|---|
| 83 | runnerが物理を1 stepだけ進めていた | FIXED |
| 84 | 非整数の刻み比を黙って使う | FIXED |
| 85 | viewerがrunnerを通らない | FIXED |
| 86 | 画像・視覚・脳のサンプル順が不明 | FIXED |
| 87 | frameの停滞を検出できない | FIXED |
| 88 | wall clockとsimulation clockを区別しない | PARTIAL |
| 89 | pause/backpressureが無い | PARTIAL |
| 90 | motor outputを実際のctrlへ適用できない | FIXED |
| 91 | reset時の世界・脳状態が同期しない | FIXED |

## Web・セキュリティ・ブラウザ

| # | 指摘 | 状態 |
|---:|---|---|
| 92 | 初期フレーム競合で画面が空白になる | FIXED |
| 93 | frame pollingが重複して震える | FIXED |
| 94 | image object URLを解放しない | FIXED |
| 95 | カメラlookatが毎フレーム動いて揺れる | FIXED |
| 96 | POST操作に認証が無い | FIXED |
| 97 | frame/stateのcache制御が無い | FIXED |
| 98 | backend・frame・actuatorのhealth情報が無い | FIXED |
| 99 | browserに失敗状態が残らない | FIXED |

## テスト

| # | 指摘 | 状態 |
|---:|---|---|
| 100 | 回路・視覚・物理・viewerの回帰テストが無い | FIXED |

## 未接続項目を完了扱いにする条件

生物学的な未接続項目を、ダミーの重みや関節対応で埋めて完了扱いにはしない。少なくとも次が揃った時だけ実接続へ進める。

1. 使用するMaleCNSデータの版、対象個体、取得元、hashを固定する。
2. retinaの全入力列と神経ID、左右眼の座標・視角を校正し、`RetinaMapping` の検証を通す。
3. 神経出力とFlyGym actuatorの対応を実測または出典付きmappingとして保存し、`MotorMapping` の検証を通す。
4. blank、flash、motion、入力ゼロ、全edge無効化、motor無効化の因果試験を通す。
5. 神経時刻・物理時刻・表示時刻をログに記録し、既知の基準回路と数値比較する。

## Looming 実験コマンドの現在地

`gnat experiment` は versioned JSON protocol を読み、baseline・接近刺激・recovery を固定シミュレーション刻みで実行する。run ごとに protocol、依存設定、graph・mapping と取得可能な engine module の SHA-256、各時刻の backend 入力・出力、刺激状態、MuJoCo state を記録する。raw ommatidia 保存は校正試行向けの明示オプション。

この記録は replay に必要な神経入力ログを含むが、保存済みログを再実行する replay CLI、neural state checkpoint、校正済み網膜 mapping、実験照合済みの motor mapping は未実装または未提供。既定 demo backend は生物学的検証には使えず、connectome backend を選んでも、現在は motor output を記録するだけで関節には適用しない。
