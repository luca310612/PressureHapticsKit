## gnat

FlyGym / NeuroMechFly の視覚・物理シミュレーションをブラウザで観察するための実験用パッケージです。
通常起動は軽量な明示的デモ回路ですが、doomfly の `graph.npz`、manifest、校正済み retina mapping を渡すと、upstream の MaleCNS CSR/LIF engine に切り替わります。

### 構成

```text
gnat/
├── pyproject.toml
├── uv.lock
├── src/
│   └── gnat/
│       ├── main.py                # アプリケーションの司令塔
│       ├── viewer.py              # Phase 1 viewer command
│       ├── clock.py               # 秒・ミリ秒の共通タイムベース
│       ├── world/                 # MuJoCo / NeuroMechFly
│       ├── vision/                # 視覚取得・RetinaBridge
│       ├── brain/                 # doomfly接続用のプロトコル
│       ├── motor/                 # 神経出力→運動の境界
│       ├── experiments/           # 刺激と実験ランナー
│       └── runner.py              # 視覚→脳の1ステップ調停
└── README.md
```

実行コードは `src/gnat/` に置きます。`test/` には実行用スクリプトを置きません。

### 実行

```bash
# GUIを起動
uv run exe.py viewer

# または、パッケージのCLIを直接起動
uv run gnat viewer
```

viewerコマンドはローカルブラウザに操作画面を開きます。MuJoCoのシミュレーション映像が上部、
左右の複眼映像が下部に表示され、「オブジェクトを飛ばす」ボタンとリセットボタンを使えます。
メイン映像はドラッグで視点回転、ホイールでズームできます。画面下部には、NumPyで処理した
左右眼→視葉→中枢回路→運動出力の活動を発光ノードと信号パルスで表示します。最初からハエが
画面に入る距離でカメラを初期化し、フレームは画像の読み込み完了後に差し替えます。

デフォルトのNumPy脳は、MaleCNS接続前に使う決定的な可視化用近似回路です。生物学的な神経細胞数や
結線を完全に再現するものではなく、眼画像から近似的な運動 readout までのデータ経路を確認するためのものです。
画面の `DEMO NUMPY / NO CONNECTOME` 表示が出ている間は、実在の全脳神経回路を使っている意味ではありません。

FlyGym 側には全生物学的関節の MuJoCo torque actuator を定義していますが、神経 readout から各関節へ
対応付ける校正データは未接続です。そのため viewer は `MOTOR LINK: DISCONNECTED` と表示し、勝手な生物学的
対応表を生成していません。実際に閉ループ運動を有効化するには、神経→関節の検証済み mapping とテストが必要です。

viewer の `/health` は `backend`、フレーム番号、connectome の有無、actuator 数、motor 接続状態を返します。
同じ `/health` の `render_fps` が実測表示レート、`target_fps` が目標値です。viewer は30 FPSに合わせて
1フレームあたり約33.3 ms（デフォルト物理ステップ333回）を進め、画面配信も30 FPSのデッドラインでスケジュールします。
画像と脳状態 API には viewer 起動時に発行するローカルトークンが必要です。

MaleCNS backend を明示的に起動する場合:

```bash
# /path/to は例です。3つのファイルとdoomfly checkoutを実在パスへ置換してください。
uv run gnat viewer \
  --connectome /path/to/doomfly/outputs/doom/malecns_v1/graph.npz \
  --manifest /path/to/doomfly/outputs/doom/malecns_v1/manifest.json \
  --doomfly-root /path/to/doomfly \
  --retina-mapping /path/to/calibrated-retina.npz
```

`graph.npz` は大容量のためこのリポジトリには同梱していません。`--connectome` を付けた場合、
校正済み mapping がない状態では起動を拒否します。推測した視野対応や関節対応を自動生成しません。

レビュー100項目の実装状況と、未接続のまま残す条件は [REVIEW_STATUS.md](REVIEW_STATUS.md) に記録しています。
神経出力を関節へ適用する場合は、推測で対応付けず `MotorMapping` と `MotorActuatorBridge` に校正済み `.npz` を渡します。

GUIなしで構成だけ確認する場合:

```bash
uv run exe.py check
```

テスト:

```bash
PYTHONPATH=src python -m unittest discover -s test -v
```


現在の `RetinaBridge` は、推測した対応表を持たず、校正済み `.npz` を明示的に受け取る設計です。

### 再現可能な looming 実験

`examples/looming-demo.json` を使うと、baseline → 接近刺激 → recovery の一試行を実行できます。
距離は FlyGym の座標系に合わせて mm、時間は秒で指定します。

```bash
uv run gnat experiment --spec examples/looming-demo.json --output runs
```

この例は固定seedの NumPy デモ回路を使用します。生物学的な反応を示すものではありません。
connectome backend を使う場合は、MaleCNS graph に加えて校正済み網膜対応表を指定します。

```bash
uv run gnat experiment \
  --spec examples/looming-demo.json \
  --output runs \
  --connectome /path/to/graph.npz \
  --manifest /path/to/manifest.json \
  --doomfly-root /path/to/doomfly \
  --retina-mapping /path/to/calibrated-retina.npz
```

各 run は上書きせず新しいフォルダーに保存されます。`manifest.json` に protocol、backend、実行環境、gnat ソースの SHA-256、モデルと mapping の SHA-256 を記録し、`steps.jsonl` に各時刻の網膜入力、神経 readout、刺激の距離・視角・拡大率、MuJoCo の `qpos/qvel` を保存します。視角はワールド原点を基準にした幾何値で、眼位置や画角の校正値ではありません。`summary.json` には baseline・刺激・recovery 別の活動量の記述統計も入ります。宣言した成功条件を自動判定するものではありません。短い校正試行で生の ommatidia readout も保存するには `--record-raw-retina` を追加します。

この実験コマンドは神経の motor output を記録しますが、関節へは適用しません。視覚刺激は仮想の濃灰色球で、接触を無効にしてあります。入力 mapping、刺激条件、神経応答、行動の生物学的妥当性は別途校正・検証が必要です。

### 壁のあいだを横切る物体への反応

`examples/horizontal-object-demo.json` は、固定した左右の壁のあいだを球体がハエの左側から右側へ横切るプロトコルです。球体は一定の半径を保つ弧上を動くため、ワールド原点から見た距離と見かけの大きさがほぼ一定になり、角速度を指定できます。壁は全試行で固定し、衝突は起こしません。

```bash
uv run gnat experiment --spec examples/horizontal-object-demo.json --output runs
```

各ステップに刺激位置・角度、網膜入力、神経 readout、motor output が記録されます。現段階では反応潜時を自動で一つの数値にしません。どの神経 readout または motor output を反応とみなすか、ベースラインからの変化をどう判定するかを定める必要があります。motor output もまだ関節へ適用されないため、測定できるのはモデル内部の応答であり、身体の行動潜時ではありません。デモ回路は生物学的な反応速度の根拠にはなりません。
