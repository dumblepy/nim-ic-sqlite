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
- workflow が recursive submodule checkout 後に、コンテナ内で `nimble test` を実行し、その task 内で `./scripts/build_sqlite.sh` と canister integration test を実行する。

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

- 現在の問題: GitHub Actions の fresh Docker image に `nicp_cdk` Nimble package がなく、`ic_sqlite.nimble` の依存解決が失敗する。
- 試したこと: Dockerfile の Nim インストール直後に、build context 内の `nicp_cdk` git submodule を `/opt/nicp_cdk` へ `COPY` し、`nimble develop` と `nimble path nicp_cdk` を実行するよう変更した。workflow の workspace-local `nimble develop` は不要なため削除済み。
- 結果: Docker image build 時に親リポジトリが固定した submodule commit を依存として登録するため、CI run 時の空の Nimble cache と外部リポジトリの最新状態に依存しない。Docker CLI はこの開発コンテナにないため image rebuild は GitHub Actions で行われる。
- 否定された仮説: native `initMemoryForTest` だけで canister の実行経路を十分に検証できるという仮説。wasm build・lifecycle hook・Candid call を通らないため採用しない。
- 次に試すこと: Docker image を rebuild し、`nimble path nicp_cdk` と CI test task を確認する。
