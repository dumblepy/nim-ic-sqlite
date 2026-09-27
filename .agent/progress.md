# 進捗管理: 1-method-chain

対象: `ic-sqlite` の Query Builder / Typed ORM。設計・実装上の詳細は
`.agent/rules/branch/1-method-chain.mdc` に集約する。

## プロジェクト全体の完成条件（NISQL-GOAL-001）

完了条件:
- `cd /application/ic-sqlite && nimble test` が終了コード 0 で完了する。
- `cd /application/ic-sqlite && nim c -r tests/test_query_compiler.nim` が終了コード 0 で完了し、識別子の引用・不正識別子・演算子ホワイトリスト・SELECT/UPDATE のプレースホルダー順・空の IN/NOT IN を検証する。
- `cd /application/ic-sqlite && nim c -r tests/test_typed_row.nim` が終了コード 0 で完了し、複数行・0件・INTEGER/REAL/bool/TEXT/BLOB/埋め込み NUL・NULL/Option・型不一致・数値オーバーフロー・不足/重複カラムを検証する。
- `cd /application/ic-sqlite && nim c -r tests/test_query_builder.nim` が終了コード 0 で完了し、`table/select/where/orderBy/limit/offset/get/first/find`、AND/OR グループ、IN/BETWEEN/NULL、JOIN/LEFT JOIN、DISTINCT/GROUP BY/HAVING の SQL と bind 順序を検証する。
- `cd /application/ic-sqlite && nim c -r tests/test_typed_write.nim` が終了コード 0 で完了し、object からの INSERT/insertId/UPDATE/DELETE、変更行数、型付き bind、および SQL injection 入力が SQL 構造を変更しないことを検証する。
- `cd /application/ic-sqlite && nim c -r tests/test_query_transaction.nim` が終了コード 0 で完了し、`withUpdate()` 内の複数 CRUD、失敗時の rollback、同一トランザクション内の未確定更新の読取り、例外時の後始末を検証する。
- `cd /application/ic-sqlite && nim c -r tests/test_query_stable.nim` が終了コード 0 で完了し、`VecStableBackend` 上の更新後の再初期化でもデータが保持されることを検証する。
- `cd /application/ic-sqlite && nimble build` が終了コード 0 で完了し、既存の `import ic_sqlite` だけで Query Builder API を利用できることをコンパイル確認する。
- `cd /application/ic-sqlite && ./scripts/build_sqlite.sh` が終了コード 0 で完了し、既存の wasm32-wasi 向け SQLite ビルドを維持する。

## タスク別完了条件

### GitHub Actions CI

完了条件:
- `actionlint .github/workflows/ci.yml` が終了コード 0 で完了する。
- workflow が recursive submodule checkout 後に、コンテナ内で `./scripts/test.sh` を実行する。
- `cd /application/ic-sqlite && ./scripts/test.sh` が終了コード 0 で完了し、Testament が native test と canister integration test の両方を実行する。

### GitHub Actions の nicp_cdk インストール

完了条件:
- `docker/test.Dockerfile` と `docker/develop.Dockerfile` に Nim パッケージの install/develop/path コマンドが存在しない。
- `cd /application/ic-sqlite && ./scripts/install.sh` が終了コード 0 で完了し、`nimble path nicp_cdk` と `nicp` CLI が利用できる。

### Example canister integration

完了条件:
- `cd /application/ic-sqlite && nim c -r --path:src tests/test_example_canister.nim` が終了コード 0 で完了する。
- Nim テストが `icp network start`、`icp deploy`、`icp canister call` を実行し、migration、INSERT/SELECT/UPDATE/DELETE、upgrade 後の stable memory 永続化を検証する。


### Phase 1 — SQLite Typed Executor

完了条件:
- `cd /application/ic-sqlite && nim c -r tests/test_typed_row.nim` が終了コード 0 で完了する。
- 同テストで、生 SQL から `Result[seq[T], DbError]` を取得でき、複数行・0件・`first` 相当の `none(T)` を検証する。
- 同テストで、正常・bind失敗・step失敗・decode失敗の全経路で statement が finalize されることを検証する。
- `cd /application/ic-sqlite && nimble test` が終了コード 0 で完了し、既存の `exec`、`execText`、`queryOneText` の互換性を確認する。

### Phase 2 — 基本 Query Builder

完了条件:
- `cd /application/ic-sqlite && nim c -r tests/test_query_compiler.nim` が終了コード 0 で完了する。
- `cd /application/ic-sqlite && nim c -r tests/test_query_builder.nim` が終了コード 0 で完了し、`table/select/where/orderBy/limit/offset/get/first/find` の型付き SELECT を検証する。
- 同テストで、Query を分岐して構築しても元 Query と各派生 Query が相互に変更されないことを検証する。
- 同テストで、閉じた DB または無効な実行コンテキストからの実行が `dekInvalidState` 相当のエラーになることを検証する。

### Phase 3 — 条件式と JOIN

完了条件:
- `cd /application/ic-sqlite && nim c -r tests/test_query_compiler.nim` が終了コード 0 で完了し、`orWhere`、`whereGroup`、`whereIn`、`whereNotIn`、`whereBetween`、`whereNull`、`whereNotNull` の SQL と bind 順序を検証する。
- `cd /application/ic-sqlite && nim c -r tests/test_query_builder.nim` が終了コード 0 で完了し、JOIN/LEFT JOIN、別名、DISTINCT、GROUP BY、HAVING を使う複数テーブル検索を検証する。
- 同テストで、LEFT JOIN の NULL が `Option[T]` に復号され、同名カラムが alias なしではマッピングエラーになることを検証する。

### Phase 4 — 型付き更新

完了条件:
- `cd /application/ic-sqlite && nim c -r tests/test_typed_write.nim` が終了コード 0 で完了し、`insert`、`insertId`、`update`、`delete` が `Result[int, DbError]` または `Result[int64, DbError]` を返すことを検証する。
- 同テストで、object のフィールド値（`Option[T]` を含む）が prepared statement の bind parameter として渡され、値が SQL 本文に埋め込まれないことを検証する。
- 同テストで、Db 経由の単独更新が既存の overlay / stable publish 経路を利用し、失敗時に永続データを変更しないことを検証する。

### Phase 5 — トランザクション統合

完了条件:
- `cd /application/ic-sqlite && nim c -r tests/test_query_transaction.nim` が終了コード 0 で完了する。
- 同テストで、`UpdateConnection` 上の複数 CRUD が一つの `withUpdate()` トランザクションとして commit されることを検証する。
- 同テストで、body が `Result` エラーまたは捕捉可能な例外で終了した場合に、全変更が rollback されることを検証する。
- 同テストで、トランザクション内 SELECT が未確定の更新を読み取れ、トランザクション外へ持ち出した Query の実行が拒否されることを検証する。

### Phase 6 — 型拡張・最適化

完了条件:
- `cd /application/ic-sqlite && nim c -r tests/test_typed_row.nim` が終了コード 0 で完了し、標準 codec と登録済みの拡張 codec の成功・失敗を検証する。
- `cd /application/ic-sqlite && nim c -r tests/test_query_builder.nim` が終了コード 0 で完了し、設定した `maxResultRows`、`maxResultBytes`、`maxQueryParams` 超過時に切り詰めず `dekResourceLimit` を返すことを検証する。
- `cd /application/ic-sqlite && nimble test` が終了コード 0 で完了し、Statement Cache を有効化した場合も既存 API と Query Builder の結果・エラー処理が一致することを検証する。

## 進捗

- [x] Phase 1: SQLite Typed Executor
- [x] Phase 2: 基本 Query Builder
- [x] Phase 3: 条件式と JOIN
- [x] Phase 4: 型付き更新
- [x] Phase 5: トランザクション統合
- [x] Phase 6: 型拡張・最適化
- [x] NISQL-GOAL-001: 全完了条件を再実行して成功

## 作業記録

- 現在の問題: example canister の `wasi2ic` が `wasi_snapshot_preview1` import を解消できず、`icp deploy` が失敗した。
- 試したこと: `wasi2ic` の実装と canister config を確認し、WASI 置換関数を提供する `ic_wasi_polyfill` のリンク状態を調査した。
- 結果: `nicpDisableWasiPolyfill` が polyfill の初期化参照を除去し、linker が置換関数を破棄していた。example と minimal_kv の config からこの define を削除した。`nim c -r --path:src tests/test_example_canister.nim` は Wasm build、deploy、CRUD、upgrade を含め終了コード 0 で成功した。
- 否定された仮説: SQLite が stable memory を直接使うため、WASI polyfill を無効にする必要があるという仮説。既存の `sqliteStableBackend()` は wasi2ic の予約領域を検出して SQLite の開始位置をオフセットするため、共存できる。
- 次に試すこと: なし。

- 現在の問題: Nim パッケージの導入が Dockerfile 内にあり、CI のテスト入口が `nimble test` 内の個別 `nim c -r` コマンド列だった。
- 試したこと: `scripts/install.sh` に `nicp_cdk` の導入とヘッダー準備を移し、`scripts/test.sh` から導入・SQLite build・Testament 実行を順に呼ぶ構成に変更した。
- 結果: `testament --simulate --megatest:off p 'tests/test_*.nim'` は native と canister integration を含む16件を検出した。`./scripts/test.sh` は全16件を Testament で実行し、すべて成功した。`nimble build`、スクリプト構文検査、Dockerfile の Nimble 導入コマンド不在も確認した。
- 否定された仮説: `testament r tests/test_query_compiler.nim` でこのディレクトリ配置のテストを実行できるという仮説。`r` は Testament の標準的なカテゴリ形式を要求したため、`p` を使用する。
- 次に試すこと: GitHub Actions で Docker image build と workflow を再実行して確認する。この環境には Docker CLI/daemon がないため Docker build 自体は未実行。

- 現在の問題: GitHub Actions の Docker image build で `nicp_cdk` の `nimble develop -y` が依存解決に失敗し、`base32`、`illwill`、`cligen`、`nim-rustcrypto` が欠落した。
- 試したこと: 隔離した空の Nimble ディレクトリで逐次解決 `--sync` を使って依存を取得し、`develop` と `install` の登録結果を比較した。
- 結果: `--sync` では依存取得が成功。`develop` では `nimble path nicp_cdk` が失敗したが、`install` は CLI をビルドし `nimble path nicp_cdk` と `nicp --help` が成功した。さらに Git 管理情報を含まないソースコピーと空の Nimble ディレクトリで `nimble --sync -y install`、`nimble path nicp_cdk`、`nicp --help`、`nicp cHeaders` がすべて終了コード 0 で完了した。Dockerfile を `nimble --sync -y install` に変更した。`cd ic-sqlite && nimble test` は native test、WASI SQLite build、canister deploy・CRUD を含め終了コード 0 で完了した。`nimble build` と `git diff --check` も成功した。
- 否定された仮説: `develop` だけで Dockerfile 後続の `nimble path nicp_cdk` と `nicp cHeaders` のための CLI 配置まで保証できるという仮説。
- 次に試すこと: GitHub Actions で image build を再実行して確認する。この環境には Docker CLI/daemon がないため Docker build 自体は未実行。

- 現在の問題: canister の `config.nims` が一時的な `build/` 配下の SQLite archive と C object を直接参照しており、fresh checkout と bind mount のいずれでも成果物の場所が明確でなかった。
- 試したこと: `nim-rustcrypto` の vendor-first・target別配置を参考に、`build_sqlite.sh` の wasm32-wasi 成果物を `vendor/sqlite/wasm32-wasi/` へ統一した。両 example の `config.nims` は同ディレクトリを変数化して archive と C shim object を link するよう変更し、生成物は専用 `.gitignore` で非追跡にした。
- 結果: SQLite の source は従来どおり `vendor/sqlite/` に保持し、target依存の `.o` / `.a` は固定の vendor subdirectory にのみ置かれる。`./scripts/build_sqlite.sh` は archive と両 object を生成し、変更後の path を使う `test_example_canister.nim`（wasm build・deploy・migration・CRUD・upgrade）は終了コード 0 で完了した。ライブラリ直下の wasm `config.nims` も同じ参照先へ統一した。
- 否定された仮説: `build/` を共有の linker input 置き場として使い続ければ CI とローカルの双方で十分に再現可能、という仮説。ビルドディレクトリは transient であり、config の依存先として不適切なため採用しない。
- 次に試すこと: なし。この変更に関する build script・deployed-canister integration・shell syntax・差分チェックは成功した。`actionlint` は実行環境に未導入のため、この環境では再実行できない（workflow の変更自体は本作業では行っていない）。

## 進捗管理: 7-cost-performance-test

- P0（再現可能な比較入力・結果形式・Native単体試験）を完了。詳細な設計判断と残タスクは `.agent/rules/branch/7-cost-performance-test.mdc` に記録した。
- `ic-sqlite/benchmarks/comparison/` に固定commitを含むマニフェスト、Rust `key.rs` と照合したNim fixture、CSV/JSONL measurement型を追加した。
- `scripts/test.sh` は既存Testamentに加えて比較基盤のP0テストを実行する。
- P1の基礎Canisterを追加し、`nicp developmentBuild` と `wasm-objdump` で基礎4 endpointのWasm exportを確認した。比較実行に必要なprepared read、churn、PocketIC runnerは未実装。
- P1の基礎APIにprepared read、append、churn、実測SQLite統計とraw stable memory観測を追加し、`icp` の実CanisterでCRUDを確認した。`nicp_cdk` のobject→Candid変換に欠けていた `uint64` 対応を修正し、同CDKのNative試験で確認した。
- P2のNim CLI transportは `icp --json` のCandidバイト列を復号する。固定Rust commitにread-only raw memory endpointパッチを適用し、fresh Canister 5組の比較を `ic-sqlite/benchmarks/comparison/results/20260927T153154Z/` に保存した。
- P3の5,000件×100周回churnを両実装で完走し、各201ステップを `ic-sqlite/benchmarks/comparison/results/churn-20260927T153429Z/` に保存した。両実装のupgrade後churn継続、Native rollback、bounded region隔離も確認した。ZeroExtentの再open不具合は診断テストで再現しており未修正。
- P4の公式Cycle Costs料金スナップショットと30日シナリオ推計を同churn runの `cost_estimate.json` に保存した。Heapと管理APIのCycles分類は未取得で、推計はstable memoryとUpdateのみ。
