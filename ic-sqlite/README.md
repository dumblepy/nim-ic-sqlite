# ic-sqlite

## Nim / Rust 比較ベンチマーク

`benchmarks/comparison/` は、Nim 実装と固定した Rust `ic-sqlite-vfs` 実装を同一のローカル ICP レプリカ上で比較します。測定は CI では実行せず、開発環境またはこのリポジトリの開発コンテナで手動実行します。

測定前に `nim`、`nicp`、`icp`、Rust toolchain、`wasm32-unknown-unknown` target、WASI SDK を利用可能にしてください。Docker 環境ではテスト用コンテナ内で以下を実行します。

### Core KV の paired 測定

```bash
cd /application/ic-sqlite/benchmarks/comparison
./prepare_rust.sh
nim c -d:release runner/main.nim
NISQL_COMPARE_NIM_SHA=HEAD ./runner/main 5
```

runner は Nim/Rust ごとに fresh Canister を作成し、各 trial で reset、read、update を実行します。結果は `results/<UTC run ID>/` に保存されます。

- `manifest.json`: 固定 SHA、Wasm hash、toolchain、raw stable memory、heap、phase 前後の status 残高
- `measurements.csv` / `measurements.jsonl`: trial ごとの観測値
- `summary.md`: Update 命令数中央値

生成直後に結果を検証します。`<run-id>` は runner の出力値へ置き換えてください。

```bash
nim c -r runner/validate.nim results/<run-id>
```

`NISQL_COMPARE_NIM_SHA=HEAD` は、現在 checkout している Nim source を測定対象にします。固定済み SHA の再現測定ではこの環境変数を省略します。

外部ネットワークで残高変化も記録する場合は、network と各 fresh Canister の初期Cyclesを明示します。これは Canister 作成・install・実行を行います。

```bash
NISQL_COMPARE_NETWORK=ic \
NISQL_COMPARE_INITIAL_CYCLES=2t \
NISQL_COMPARE_NIM_SHA=HEAD ./runner/main 1
```

外部ネットワークの `cycles` / `reserved_cycles` 差分も manifest に保存します。ただし、runner 自身の ingress・status・query 呼出し等を含む残高変化なので、Update実行命令の料金とは同一視しません。

### Churn と 30 日費用推計

5,000 行を初期化し、1,000 行 DELETE と 1,000 行 INSERT を 100 cycle 実行します。

```bash
cd /application/ic-sqlite/benchmarks/comparison
./prepare_rust.sh
nim c -d:release -r runner/churn.nim
nim c -d:release -r runner/validate.nim results/churn-<run-id>
nim c -d:release -r runner/cost_report.nim results/churn-<run-id>
```

`cost_report.nim` は検証済みの churn artifact だけを入力に受け、dated pricing snapshot で storage と Update の 30 日推計を書き出します。local replica の `cycles` 残高差は管理 status の観測であり、命令実行費用として推計に使いません。

### Profile artifact

read、write、multi-get、growth の共通 profile 指標を fresh Canister で収集します。

```bash
cd /application/ic-sqlite/benchmarks/comparison
./prepare_rust.sh
NISQL_COMPARE_NIM_SHA=HEAD nim c -d:release -r runner/profile.nim
```

`results/profile-<UTC run ID>/profile_measurements.jsonl` には、両実装で共通の rows、instructions、checksum、DB size、logical stable pages/bytes、raw stable memory を保存します。VFS/page-table 固有の詳細値は比較値として保存しません。

```bash
nim c -d:release -r runner/validate.nim results/profile-<run-id>
nim c -d:release -r runner/profile_summary.nim results/profile-<run-id>
```

`profile_summary.md` は profile ごとの Nim/Rust instruction 比を出力します。profile は通常 workload と別の counting backend を使うため、core KV の命令数と平均化しません。

### 解釈上の注意

- `instructions_update` は Update message の Wasm instruction 観測値です。
- query の instruction 値は別の接続・warmup 条件なので、Cycles 見積りに用いません。
- `raw_stable_*` は `ic0_stable64_size`、`sqlite_virtual_pages` は SQLite に渡した logical backend のページ数です。同じ値として比較しません。
- `heap_bytes` は local `canister status` の `memory_size - raw_stable_bytes` です。Canister heap の一般的な定義ではなく、測定時点の status 観測値です。
- profile endpoint は通常 workload と別の counting backend を使います。profile の内訳と通常 workload の命令数を同じ系列として平均化しません。
