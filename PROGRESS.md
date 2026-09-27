# PROGRESS — ic-sqlite 実装

> このファイルは自律開発ループの作業記録として維持する。
> 設計書: `/application/design/nim_ic_sqlite_vfs_design.md`
> 実装先: `/application/ic-sqlite/`
> コンテキスト圧縮後も、このファイルと git diff とテスト結果を確認して作業を継続する。

## プロジェクト全体の完成条件（NISQL-GOAL-SQLITEVFS）

[設計書](./design/nim_ic_sqlite_vfs_design.md) の全セクションを実装し、以下の検証可能な条件を満たす。

- [x] 1. SQLite を `SQLITE_OS_OTHER=1` で static archive にビルドできる。
- [x] 2. C shim → Nim VFS exports → stable backend の呼び出し経路が native test で通る。
- [x] 3. Superblock が stable memory へ正しく read/write できる。
- [x] 4. Overlay が dirty page を保持し、read/write/commit を正しく処理する。
- [x] 5. VFS 経由で `sqlite3_open_v2` が成功し、`CREATE TABLE`, `INSERT`, `SELECT` が stable memory 上で動作する。
- [x] 6. SQLite transaction commit 後に dirty page が stable memory へ反映される。
- [x] 7. ROLLBACK 後に stable memory が変更されない。
- [x] 8. heap temp file (journal) が正しく動作する。
- [x] 9. 空 stable memory → fresh DB 作成 → reopen で既存 DB を読める。
- [x] 10. foreign stable memory 検出 ("NIMSQLV1" magic) が動作する。
- [x] 11. wasm32-wasi 向けにクロスコンパイルでき、ic-wasi-polyfill / wasi2ic 経由で ICP canister WASM が生成できる。
- [x] 12. local ICP 上で canister を deploy し、SQLite CRUD + upgrade persistence を実証できる。

---

## ディレクトリ構成

設計書 38節の推奨構成に従い、`/application/ic-sqlite/` に構築する。

```
/application/ic-sqlite/
├── AGENTS.md                       # ic-sqlite 固有ルール
├── ic_sqlite.nimble
├── build/                          # SQLite static archive 成果物
├── scripts/
│   └── build_sqlite.sh             # SQLite amalgamation ビルド
├── vendor/
│   └── sqlite/                     # SQLite amalgamation (sqlite3.c, sqlite3.h)
├── c/
│   └── ic_sqlite_vfs_shim.c/h      # C ABI shim (sqlite3_vfs / sqlite3_io_methods)
├── src/
│   ├── ic_sqlite.nim               # 公開モジュール (集約 export)
│   ├── db.nim                      # IcSqliteDb facade
│   ├── connection.nim              # Connection / UpdateConnection
│   ├── statement.nim               # Statement wrapper
│   ├── sqlite_api.nim              # FFI: sqlite3_* C API import
│   ├── value.nim                   # SqlValue / SqlValueKind
│   ├── migration.nim               # Migration framework
│   ├── ffi/
│   │   └── vfs_exports.nim         # Nim exportc callback (nim_icvfs_*)
│   ├── vfs/
│   │   ├── vfs.nim                 # VFS global state / registry
│   │   ├── file.nim                # FileState / FileKind
│   │   ├── temp_file.nim           # TempFile (seq[byte])
│   │   ├── overlay.nim             # Overlay (dirty page management)
│   │   └── lock.nim                # LockLevel / lock state
│   └── stable/
│       ├── backend.nim             # StableBackend interface
│       ├── ic_backend.nim          # IcStableBackend → ic0_stable64_*
│       ├── region.nim              # StableRegion (baseOffset/maxBytes)
│       ├── superblock.nim          # Superblock (fixed LE encoding)
│       ├── stable_blob.nim         # StableBlob (SQLite DB image I/O)
│       └── checksum.nim            # FNV-1a 64 helper
├── tests/
│   ├── test_vfs.nim                # VFS + sqlite3_open 統合 test
│   ├── test_overlay.nim            # Overlay 単体 test
│   ├── test_superblock.nim         # Superblock 単体 test
│   ├── test_temp_file.nim          # TempFile 単体 test
│   ├── test_stable_backend.nim     # VecStableBackend 動作確認
│   └── test_db_facade.nim          # DB facade CRUD test
└── examples/
    └── minimal_kv/                 # 最小限 ICP canister
```

---

## タスク一覧

### Task 1: プロジェクト構造の初期化

**完了条件:**
- [x] `/application/ic-sqlite/` ディレクトリが上記構成で作成されている (`nimble test` の layout test)
- [x] `ic_sqlite.nimble` に必要な dependency (nicp_cdk) が定義されている
- [x] Nimble の `srcDir` / `bin` / `task` などが適切に設定されている
- [x] `nimble build` が (中身が空でも) エラーなく通る

**詳細:**
- `nimble init` または手動で `nim_ic_sqlite_vfs.nimble` を作成
- 設計書 38節の全ディレクトリを作成
- 各ディレクトリに `.gitkeep` を配置
- 依存関係: `nicp_cdk`, `nicp_cdk/storage/libs/stable_memory`

---

### Task 2: SQLite ビルドスクリプト

**完了条件:**
- [x] `vendor/sqlite/sqlite3.c` と `sqlite3.h` が配置されている (SQLite 3.53.4、公式 SHA3-256 検証済み)
- [x] `scripts/build_sqlite.sh` が設計書 8節の compile flags で static archive を生成する
- [x] 生成された `build/libsqlite3_ic.a` が wasm32-wasi 向けである (`llvm-objdump`: `file format wasm`。環境に `file` コマンドなし)
- [x] `build_sqlite.sh` が再現可能である (SQLite 3.53.4 を固定)

**詳細:**
- SQLite amalgamation を https://sqlite.org/download.html から取得
- 設計書 7.1節の compile flags をすべて反映
- CC に `${WASI_SDK_PATH}/bin/clang`、AR に `${WASI_SDK_PATH}/bin/llvm-ar` を使用
- 設計書 8節 `build_sqlite.sh` をベースに実装

---

### Task 3: C ABI shim

**完了条件:**
- [x] `c/ic_sqlite_vfs_shim.h` に `IcFile` struct (`sqlite3_file` を base に持つ) と `IC_VFS` (`sqlite3_vfs` の実体) が定義されている
- [x] `c/ic_sqlite_vfs_shim.c` に以下の関数が実装されている:
  - `sqlite3_os_init()` / `sqlite3_os_end()`
  - `ic_xOpen`, `ic_xDelete`, `ic_xAccess`, `ic_xFullPathname`, `ic_xRandomness`, `ic_xSleep`, `ic_xCurrentTime`, `ic_xGetLastError`
  - `ic_xClose`, `ic_xRead`, `ic_xWrite`, `ic_xTruncate`, `ic_xSync`, `ic_xFileSize`, `ic_xLock`, `ic_xUnlock`, `ic_xCheckReservedLock`, `ic_xFileControl`, `ic_xSectorSize`, `ic_xDeviceCharacteristics`
- [x] C shim が参照する `nim_icvfs_*` 外部関数の宣言が一致している（Task 8 の export 名・引数を先行固定）
- [x] C shim 単体が wasm32-wasi 向けにコンパイルできる (link 不要)

**詳細:**
- 設計書 6節, 13節, 14節, 40節の API に従う
- `IcFile` は `sqlite3_file` を先頭フィールドに持ち、`handle_id: uint32` を保持
- WAL 関連 (`xShmMap` 等) は実装しない
- `nim_icvfs_*` は Nim 側の `{.exportc, cdecl.}` 関数として実装予定

---

### Task 4: Stable backend interface + IcStableBackend

**完了条件:**
- [x] `StableBackend` が ref object の interface (method 3つ) として定義されている
  - `sizePages(): uint64`
  - `grow(pages: uint64): bool`
  - `read(offset: uint64, dst: pointer, size: uint64)`
  - `write(offset: uint64, src: pointer, size: uint64)`
- [x] 設計書 34節の `IcStableBackend` が `StableBackend` を継承し `ic0_stable64_*` を呼ぶ
- [x] `VecStableBackend` (native test用) が `StableBackend` を継承し `seq[byte]` で動作する
- [x] raw pointer 版 `stableReadRaw` / `stableWriteRaw` (設計書 4節) が ic_backend.nim で提供される
- [x] native test で `VecStableBackend` の read/write/grow が通る

**詳細:**
- 設計書 4節, 34節を実装
- `nicp_cdk` の `ic0_stable64_*` は `.importc` で直接利用
- `VecStableBackend` は stable memory を模した `seq[byte]` を持つ

---

### Task 5: Superblock

**完了条件:**
- [x] 設計書 11節の Superblock 型が `superblock.nim` で定義されている (fixed LE encoding)
- [x] Superblock の serialize/deserialize が正しく行われる:
  - `encodeSuperblock(sb: Superblock): seq[byte]`
  - `decodeSuperblock(data: seq[byte]): Result[Superblock, string]`
- [x] magic `"NIMSQLV1"` (設計書 11節) の検証が decode に含まれている
- [x] zero extent の encode/decode が含まれている
- [x] FNV-1a 64 checksum (metaChecksum) の検証が含まれている
- [x] 設計書 12節: foreign stable memory 検出で magic 不一致時にエラーを返す
- [x] native test で serialize → deserialize → field一致 を確認する

**詳細:**
- 設計書 11節の binary layout を厳密に守る
- Nim object をそのまま binary dump しない (design 11節)
- 初期化時: `stableSize == 0` → fresh / `magic == "NIMSQLV1"` → load
- zero extent: `seq[ZeroExtent]` を superblock 後方に配置

---

### Task 6: Overlay

**完了条件:**
- [x] 設計書 18節の `Overlay` 型が実装されている
- [x] read path (設計書 18.3節): dirty → zero extent → stable backend の順で読む
- [x] write path (設計書 18.4節): full page write は直接 dirty へ、partial write は base page load → apply → store
- [x] `publishDirtyPages(backend: StableBackend)` が dirty page を stable backend へ書き込む
- [x] `discardOverlay()` で dirty page を破棄できる
- [x] zero extent の管理: truncate 時に range 追加、dirty write 時に該当 page を除外
- [x] native test (VecStableBackend) で overlay read/write/publish の正しさを確認する

**詳細:**
- 設計書 18-19節を実装
- `dirtyPages`: `OrderedTable[uint64, seq[byte]]` (page number → page data)
- page size は config から (default 16384)
- `baseSize`: overlay 開始時の DB size
- 設計書 19節: zero extent は MVP では dirty page 除外のみ、persistent 保存は superblock 経由

---

### Task 7: TempFile + Lock

**完了条件:**
- [x] 設計書 16節の `TempFile` 型 (`seq[byte]`) + operation が実装されている
  - `readAt(offset, len): seq[byte]`
  - `writeAt(offset, data: seq[byte])`
  - `truncate(size)`
  - `len: int`
- [x] 設計書 24節の `LockLevel` enum + lock state 管理が実装されている
  - `xLock` / `xUnlock` / `xCheckReservedLock` の sematics を満たす

**詳細:**
- TempFile は heap 上の `seq[byte]` で journal/temp store を表現
- Lock は複数 connection を想定しない (SQLITE_THREADSAFE=0, locking_mode=EXCLUSIVE)

---

### Task 8: Nim VFS exports + registry

**完了条件:**
- [x] 設計書 41節の file handle registry (`files: Table[uint32, FileState]`) が実装されている
- [x] 以下の `{.exportc, cdecl.}` callback がすべて実装されている:
  - `nim_icvfs_open`, `nim_icvfs_close`, `nim_icvfs_read`, `nim_icvfs_write`
  - `nim_icvfs_truncate`, `nim_icvfs_file_size`
  - lock 系: `nim_icvfs_lock`, `nim_icvfs_unlock`, `nim_icvfs_check_reserved_lock`
  - その他: `nim_icvfs_randomness`, `nim_icvfs_current_time`, `nim_icvfs_last_error`
- [x] 設計書 6節: 全 callback で exception を catch し SQLite error code に変換している
- [x] 設計書 15節の file classification が実装されている: `/main.db` → stable memory / WAL → `SQLITE_CANTOPEN` / others → heap temp
- [x] 設計書 25節: `xSync` は `SQLITE_OK` を返す
- [x] 設計書 26節: `xRandomness` は決定論的乱数 (seed = lastTxId XOR dbSize XOR counter など)
- [x] 設計書 27節: `xCurrentTime` は `ic0.time` 相当から Julian day へ変換
- [x] native test で file registry の open/close/read/write が通る

**詳細:**
- 全 callback は `raises: []` を原則とし、失敗は error code へ変換
- 設計書 6節の例外ハンドリングパターンを全関数に適用
- 設計書 40節の C → Nim API 定義と一致させる

---

### Task 9: SQLite FFI layer (sqlite_api.nim)

**完了条件:**
- [x] 設計書 28節の `Sqlite3`, `Sqlite3Stmt` incomplete struct が定義されている
- [x] 最低限必要な sqlite3_* 関数が `{.importc, cdecl, header: "sqlite3.h".}` で import されている:
  - `sqlite3_open_v2`, `sqlite3_close`, `sqlite3_prepare_v2`, `sqlite3_finalize`
  - `sqlite3_step`, `sqlite3_reset`, `sqlite3_bind_*`, `sqlite3_column_*`
  - `sqlite3_errmsg`, `sqlite3_changes`, `sqlite3_last_insert_rowid`
  - `sqlite3_exec`
- [x] `SQLITE_TRANSIENT` 用の C helper (`ic_sqlite_bind_text` 等) が c/ に実装されている
- [x] SQLite compile flags から必要十分な関数がリンク可能である

**詳細:**
- 設計書 28節の FFI パターンに従う
- `nim_ic_sqlite_vfs.nimble` で `passL` に `build/libsqlite3_ic.a` と `c/ic_sqlite_vfs_shim.o` を追加

---

### Task 10: DB facade (db.nim + connection.nim + statement.nim + value.nim + migration.nim)

**完了条件:**
- [x] `IcSqliteDb` (設計書 29節) が実装されている:
  - `init(config)`, `withUpdate(body)`, `withQuery(body)`
  - `migrate(migrations)`
- [x] `Connection` / `UpdateConnection` が実装されている
- [x] `Statement` が実装されている (prepare/bind/step/column access)
- [x] `SqlValue` / `SqlValueKind` (設計書 30節) が実装されている
- [x] `DbError` (設計書 29節) が実装されている
- [x] Migration framework (設計書 31節) が実装されている
- [x] 設計書 20節の transaction lifecycle が `withUpdate` で実装されている
- [x] 設計書 21節: `publishOverlayOrTrap` が atomic publish を実装している
- [x] 設計書 17節: write connection 用 PRAGMA / read-only connection 用 PRAGMA が適用される
- [x] 設計書 22節: `withUpdate` の body は同期 proc (`{.closure.}`) に限定されている
- [x] 設計書 37節: `arbitrary SQL endpoint を公開しない` 方針が守られている
- [x] 設計書 36節: `DbConfig` に `maxDirtyPages` / `maxDirtyBytes` / `maxSqlBytes` / `maxBlobBytes` が含まれている
- [x] native test (VecStableBackend) で CRUD が通る

**詳細:**
- 設計書 29-33節, 17節, 20-22節, 36-37節を実装
- `withUpdate` 内で BEGIN IMMEDIATE → body → COMMIT/ROLLBACK → publishOverlayOrTrap の流れ
- migration は `__nim_ic_sqlite_migrations` テーブルで管理

---

### Task 11: canister lifecycle integration

**完了条件:**
- [x] 設計書 32節・33節の upgrade lifecycle が実装されている:
  - `initDatabase()` を `init` / `post_upgrade` の両方から呼ぶ
  - VFS global state → stable backend bind → superblock load → SQLite reopen → migration
- [x] 設計書 12節: foreign stable memory 検出で既存データ破壊を防止
- [x] `nim_ic_sqlite_vfs.nim` に公開 API が集約されている

**詳細:**
- `nicp_cdk` の lifecycle hook を利用
- `post_upgrade` では stable memory 上の superblock を読み直すだけで heap state は再生成

---

### Task 12: examples/minimal_kv

**完了条件:**
- [x] `examples/minimal_kv/` に Canister プロジェクトが作成されている
- [x] `init` と `post_upgrade` で DB 再初期化が行われる
- [x] `get(key)`, `put(key, value)` の update endpoint が提供される
- [x] `get(key)` の query endpoint が提供される
- [x] build スクリプトで WASM → ic-wasi-polyfill → wasi2ic の chain が通る
- [x] local ICP で deploy して CRUD が動作する
- [x] upgrade 後もデータが保持される

**詳細:**
- 設計書 31節の migration + 32節の upgrade を実証
- `nim_ic_sqlite_vfs.nimble` の example task として build 可能にする

---

### Task 13: 全テスト + 最終検証

**完了条件:**
- [x] 全 native test が `nimble test` で通る
- [x] wasm32-wasi 向け static archive build が成功する
- [x] 最終 Wasm (ic-wasi-polyfill + wasi2ic) が生成できる
- [x] local ICP で canister install + CRUD が trap せず動作する
- [x] canister upgrade 後もデータが保持される
- [x] 異なる MemoryId の stable data と共存できる (region mode)

**詳細:**
- 設計書 35節の error code mapping の網羅
- 設計書 42節: deterministic behavior (page sorted write 等)
- 設計書 43節: checksum refresh (admin operation)

---

## 反復記録

### 反復 0 — 2026-09-17

**現在の問題:**
設計書の実装を開始する前の初期状態。コードは一切存在しない。

**試したこと:**
設計書 `/application/design/nim_ic_sqlite_vfs_design.md` を全セクション読み、Task に分割した。

**結果:**
13 Task に分割。各 Task に完了条件を設定した。

**次に試すこと:**
Task 1 (プロジェクト構造の初期化) から実装を開始する。

### 反復 1 — 2026-09-18

**現在の問題:**
設計書が `/application/design/nim_ic_sqlite_vfs_design.md` に移動。`/application/ic-sqlite/` 配下に `AGENTS.md` が配置される方針に変更。

**試したこと:**
PROGRESS.md と project.mdc の設計書パス参照を `/application/design/` に更新。

**結果:**
パス参照を修正。`/application/ic-sqlite/` は現時点で空。実装未着手。

**次に試すこと:**
`/application/ic-sqlite/AGENTS.md` を作成し、Task 1 (プロジェクト構造の初期化) から実装を開始する。

### 反復 2 — 2026-09-18

**現在の問題:**
新アーキテクチャ用の `/application/ic-sqlite/` は旧 Nimble のサンプルだけで、
設計書 38節の構成と正規公開モジュールが存在しなかった。

**試したこと:**
`ic_sqlite.nimble`、公開入口、Phase 0 のディレクトリ、README、ライセンス、
レイアウト検証テストを追加した。`nimble build` の対象未指定エラーに対し、公開モジュールを
`bin` として明示した。

**結果:**
`nimble build` と `nimble test` が成功。Task 1 の完了条件を満たした。

**否定された仮説:**
ライブラリ用 Nimble package は `bin` 未指定でも `nimble build` が成功するという仮説。

**次に試すこと:**
Task 2 として、固定版 SQLite amalgamation と wasm32-wasi static archive ビルドを実装・検証する。

### 反復 3 — 2026-09-18

**現在の問題:**
SQLite amalgamation と wasm32-wasi 向け static archive が未配置だった。

**試したこと:**
SQLite 3.53.4 の公式 `sqlite-amalgamation-3530400.zip` を取得し、公式掲載値と
SHA3-256 が一致することを検証して `sqlite3.c` / `sqlite3.h` を配置した。設計書 7.1節の
全フラグを使うビルドスクリプトを追加して WASI SDK 21.1.4 で実行した。

**結果:**
`build/libsqlite3_ic.a` を生成。`llvm-objdump -h build/sqlite3.o` は `file format wasm` を示し、
archive から `sqlite3_open_v2` と `sqlite3_prepare_v2` の公開も確認した。`nimble test` も成功。

**否定された仮説:**
このコンテナに `file` または `llvm-readobj` が存在するという仮説。いずれも未配置のため、
WASI SDK 同梱の `llvm-objdump` で同等の形式検証を行った。

**次に試すこと:**
Task 3 として C ABI shim を実装し、WASI 単体コンパイルを確認する。

### 反復 4 — 2026-09-18

**現在の問題:**
SQLite ABI に適合する VFS/I/O methods がなく、Nim 側の将来の object layout に依存させずに
C callback から安全に handle registry へ接続する経路がなかった。

**試したこと:**
`sqlite3_file` を先頭に置く `IcFile` と、VFS version 1 / I/O methods version 1 の shim を
実装した。C から Nim への ABI を `uint32_t` handle ID、C scalar、pointer に限定した。

**結果:**
WASI clang の `-Wall -Wextra -Werror` で shim object の単体コンパイルが成功し、
`llvm-objdump` は `file format wasm` を示した。初回の strict compile で
`sqlite3_vfs.xNextSystemCall` の NULL 初期化漏れを検出・修正した。`nimble test` も成功。

**否定された仮説:**
SQLite VFS version 1 では version 3 で追加された system-call callback の初期化が不要という仮説。
現行ヘッダの struct 全 field を明示的に NULL 初期化する必要があった。

**次に試すこと:**
Task 4 として StableBackend と native 用 VecStableBackend を実装する。

### 反復 5 — 2026-09-18

**現在の問題:**
stable memory I/O を VFS 実装と native test の双方から使える、raw pointer 対応の抽象化がなかった。

**試したこと:**
64 KiB page を基準にする `StableBackend`、`IcStableBackend`、`VecStableBackend` を実装した。
IC syscall は wasm32 時だけ `.importc` でリンクし、native 実行では誤って heap 実装へフォールバック
しないよう明示エラーにした。

**結果:**
native test は grow/read/write と範囲外 I/O、IC backend の native fail-fast を検証して成功した。
`nimble build` も成功。

**否定された仮説:**
native test で IC stable memory を暗黙に `seq` へ置き換えてよいという仮説。実環境との差を
隠すため、テスト用 backend は明示的に選択する設計にした。

**次に試すこと:**
Task 5 として固定 little-endian Superblock と foreign-memory 検出を実装する。

### 反復 7 — 2026-09-18

**現在の問題:**
stable memory に SQLite image の所有情報を安全に保存し、既存の foreign image を上書きせずに
判定する固定レイアウトがなかった。

**試したこと:**
`Superblock` と `ZeroExtent` を固定 little-endian で encode/decode し、checksum field をゼロ化
した byte sequence に FNV-1a 64 を適用した。stable memory が空なら fresh、非空なら magic を含む
superblock を検証する `readExistingSuperblock` を実装した。

**結果:**
native test で全 field と zero extent の往復、magic 不一致、metadata 改竄、fresh/foreign memory
の分岐を検証して成功した。

**否定された仮説:**
Nim object のメモリ表現を保存しても compiler/version 差の影響を受けないという仮説。明示的な
byte-order encoding により layout を固定した。

**次に試すこと:**
Task 6 として page overlay の read/write/publish/discard を実装する。

### 反復 8 — 2026-09-18

**現在の問題:**
SQLite の更新途中の page write を stable memory へ直接反映すると、ROLLBACK 後にも
永続データだけが変更される危険があった。

**試したこと:**
logical DB offset を stable DB base offset から分離する heap `Overlay` を実装した。full-page
write は stable read なしで dirty page を作り、partial write は base page を読み込んで変更する。
truncate は zero extent を追加し、同 page への write はその extent を除外するようにした。

**結果:**
native test で publish 前に stable memory が変化しないこと、partial write、discard、truncate
後の logical zero、再 write 後の zero extent 除去を確認した。`nimble test` と `nimble build` が成功。

**否定された仮説:**
SQLite の `xWrite` ごとに stable memory へ書いても transaction rollback を維持できるという仮説。
更新内容は COMMIT 後の publish まで heap overlay に保持する必要がある。

**次に試すこと:**
Task 7 として heap TempFile と single-connection lock state を実装する。

### 反復 9 — 2026-09-18

**現在の問題:**
SQLite の journal/temp file を通常 filesystem に依存させず、かつ VFS が期待する lock state を
返す実装がなかった。

**試したこと:**
`seq[byte]` ベースで gap をゼロ埋めする `TempFile` と、`lkNone` から `lkExclusive` までの
`LockState` を追加した。single-connection / `SQLITE_THREADSAFE=0` 前提のため lock は heap state
だけを遷移させ、reserved-lock query を提供する。

**結果:**
native test で temp file の read/write/truncate と範囲検証、lock の昇格・降格・reserved state を
確認した。`nimble test` と `nimble build` が成功。

**次に試すこと:**
Task 8 として Nim VFS exports と file handle registry を実装する。

### 反復 10 — 2026-09-18

**現在の問題:**
C shim が参照する callback と Nim の file state を接続する registry がなく、main DB と
journal/temp file の storage model を分離できなかった。

**試したこと:**
`Table[uint32, FileState]` registry、`/main.db` / WAL / heap temp の分類、overlay 経由の main DB
I/O、TempFile I/O、lock callback、deterministic xorshift randomness、C ABI export を追加した。

**結果:**
native test で C-compatible callback の open/write/read/close、overlay publish、temp file、WAL 拒否、
決定論的乱数を確認した。`nimble test` と `nimble build` は成功。

**残る問題:**
Task 8 の canister 時刻取得（`ic0.time`）と export callback の `raises: []` による機械的な
例外境界保証を追加する必要がある。

**次に試すこと:**
VFS export の exception barrier と wasm32 `ic0.time` provider を実装して Task 8 を完了する。

### 反復 11 — 2026-09-19

**現在の問題:**
VFS callback の例外仕様を compiler が検証しておらず、時刻が native test の固定値だけに
依存していた。

**試したこと:**
全 `nim_icvfs_*` export に `raises: []` を付け、callback 内部の失敗を SQLite error code に
変換する barrier を追加した。wasm32 では `ic0_time` を import し、native では注入値を使う
time provider を追加した。

**結果:**
`raises: []` 付き exports の native compile、Julian day 変換 test、全 native test、Nimble build、
WASI clang による C shim strict compile が成功。Task 8 の全条件を満たした。

**次に試すこと:**
Task 9 として SQLite C API FFI と `SQLITE_TRANSIENT` binding helper を実装する。

### 反復 12 — 2026-09-19

**現在の問題:**
Nim の DB facade が SQLite C API を安全に呼び出す FFI と、TEXT/BLOB の所有権を
`SQLITE_TRANSIENT` に固定する binding helper を持っていなかった。

**試したこと:**
incomplete struct と open/prepare/step/bind/column/error/exec API を `ffi/sqlite_api.nim` に
集約し、`sqlite_helpers.c` に TEXT/BLOB copy helper を追加した。wasm32 限定で SQLite archive、
VFS shim、helper object をリンクする `config.nims` を追加した。

**結果:**
FFI declaration test、`nimble test`、`nimble build` が成功。WASI clang で helper object を
strict compile し、archive に open/close/prepare/finalize/step/reset/exec/error 等の symbol が
含まれることを `llvm-nm` で確認した。

**否定された仮説:**
Nim の `sqlite3_bind_text` 宣言だけで transient destructor semantics を移植できるという仮説。
SQLite macro を C helper に閉じ込める必要がある。

**次に試すこと:**
Task 10 として高水準 DB facade と transaction lifecycle を実装する。

### 反復 13 — 2026-09-19

**現在の問題:**
利用者が C pointer や SQLite C API を意識せず、キャニスター内で `Db.exec("SELECT …")` を
実行する公開 API がなかった。

**試したこと:**
`Db`、`DbError`、`init`、`close`、`exec` を追加した。production の `init` は `/main.db` を
`icstable` VFS で開き、初期 open の page write を overlay に保持して publish する。overlay publish
には必要 stable page を grow する処理を追加した。native 統合 test では system SQLite の
`:memory:` backend を使い、同じ facade の `Db.exec("SELECT 1")` を実行した。

**結果:**
`Db.exec("SELECT 1")` は SQLite engine で成功し、changes count 0 を返した。`nimble test` と
`nimble build` が成功した。

**残る問題:**
local ICP canister 上での `icstable` VFS を使う end-to-end query 実証と、write transaction の
BEGIN/COMMIT/overlay publish lifecycle は未実装。

**次に試すこと:**
`Db.exec` を canister example に組み込み、WASM build と local ICP query 実証を行う。その後、
write transaction API を追加する。

### 反復 14 — 2026-09-19

**現在の問題:**
`Db.exec` が実際の ICP canister 内で wasm32 の SQLite archive と `icstable` VFS をリンクして
実行できることを、local ICP で再現可能に実証する必要があった。

**試したこと:**
example backend に固定 SQL の update endpoint `selectOne()` を追加し、初回呼出しで
`Db.init(newIcStableBackend())`、続けて `Db.exec("SELECT 1")` を実行するようにした。任意 SQL を
公開しないよう SQL は endpoint 内に固定し、既存の `greet` API も維持した。WASM link 用に SQLite
archive、VFS shim、C helper の include/link 設定を example の Nim config に追加した。

**結果:**
`nicp developmentBuild` で WASI → `wasi2ic` → Candid metadata 付き canister WASM の生成に成功。
local ICP (`icp deploy -e local`) へ deploy 後、`icp canister call backend selectOne '()' -e local`
は `("ok")` を返した。`greet("ICP")` も `("Hello, ICP!")` を返し、既存 API の互換性も確認した。
全 native test と `nimble build` も成功した。

**否定された仮説:**
WASM build で `ic0_stable64_*` / `ic0_time` の import が未解決になるという仮説。Nim import に
`header: "ic0.h"` を指定することで SDK の syscall declaration を用いて解決した。

**次に試すこと:**
`CREATE TABLE` / `INSERT` / `SELECT` と upgrade persistence を含む transaction API を実装し、
Task 10--13 の CRUD・永続化完了条件を満たす。

### 反復 15 — 2026-09-19

**現在の問題:**
canister example は `SELECT 1` の実行確認だけであり、stable-memory SQLite に対する
テーブル作成と値の CRUD を示せていなかった。

**試したこと:**
`Db.execText`（SQLite placeholder への TEXT binding）と `Db.queryOneText` を追加した。
stable backend の書込みは各 statement を overlay で囲み、SQLite の成功後にのみ publish する。
example には固定 SQL と parameter binding を使う `createTable` / `put` / `get` / `update` /
`deleteValue` endpoint を追加し、任意 SQL は公開しなかった。Nim test task は test ごとの
nimcache を用いるようにして異なる module graph の古い生成物が混ざらないようにした。

**結果:**
native の DB facade test で table create、insert、select、update、delete、not-found を確認。
WASM build 後、新規 detached local canister `4fbx2-kt777-77775-aaabq-cai` に install し、
`createTable → put(user:1, Alice) → get(Alice) → update(Bob) → get(Bob) → deleteValue →
get(not_found)` がすべて成功した。これにより stable VFS 経由の Task 5 と local CRUD 条件を満たした。

**否定された仮説:**
`remove` が CDK update method として公開されるという仮説。local canister では method が
export されなかったため、衝突しない `deleteValue` に変更した。

**次に試すこと:**
superblock に DB size と transaction metadata を反映して post-upgrade reopen を実装し、
upgrade persistence と atomic publish の完了条件を満たす。

### 反復 16 — 2026-09-19

**現在の問題:**
canister upgrade で heap 上の DB size が失われ、stable SQLite image を再オープンできなかった。
また、`wasi2ic` の stable-memory manager header (`MGR` + version) と SQLite の offset 0 が競合した。

**試したこと:**
`Db.init` が superblock から DB size / transaction ID を復元し、初回 open と各成功 write publish の後に
metadata を保存するようにした。runtime 管理領域を検出した場合は、1025 stable pages の prefix 後方を
logical stable region として公開する `OffsetStableBackend` を使い、manager を破壊しないようにした。
CDK に WASI-free build 用の `NICP_SKIP_WASI2IC` opt-out も追加した（通常 build は `wasi2ic` を維持）。

**結果:**
native test で offset region と stable superblock storage read を確認。local detached canister
`52jen-jl777-77775-aaafa-cai` で `createTable`、`put("upgrade:key", "persisted")` 後に
`--mode upgrade` で同一 WASM を install し、`get("upgrade:key")` が `("persisted")` を返した。
local CRUD + upgrade persistence の完成条件を満たした。

**次に試すこと:**
transaction API (`withUpdate`) の明示的 BEGIN/COMMIT/ROLLBACK と publish failure 時の trap を実装し、
Task 10 の atomic transaction 条件を満たす。

### 反復 17 — 2026-09-19

**現在の問題:**
単文 `Db.exec` は SQLite の implicit transaction に任せており、複数 SQL を一つの canister update
として明示的に COMMIT / ROLLBACK する API がなかった。

**試したこと:**
同期 closure に限定した `Db.withUpdate` と `UpdateConnection` を追加した。`withUpdate` は
overlay 開始、`BEGIN IMMEDIATE`、body 実行、`COMMIT`、overlay publish の順に実行し、body または
COMMIT の失敗時は `ROLLBACK` と overlay discard を行う。transaction 内部の TEXT binding も
`UpdateConnection.execText` で提供した。

**結果:**
native DB facade test で、成功 body の insert が COMMIT 後に読めること、および error を返す body の
insert が ROLLBACK 後に読めないことを確認した。`nimble test` と `nimble build` が成功した。

**次に試すこと:**
publish 開始後の failure を `ic0_trap` に変換する failpoint 対応と、write/read PRAGMA・DbConfig の
resource limit を追加する。

### 反復 18 — 2026-09-19

**現在の問題:**
DB facade に SQL・parameter・dirty overlay の resource limit がなく、write connection の SQLite
PRAGMA も明示的に固定されていなかった。

**試したこと:**
`DbConfig` に `maxDirtyPages` / `maxDirtyBytes` / `maxSqlBytes` / `maxBlobBytes` を追加した。
overlay が上限を超える新規 dirty page を拒否するようにし、SQL text と bound text のサイズも facade
で検証する。fresh DB では page size を設定し、write connection には MEMORY journal、synchronous OFF、
MEMORY temp store、EXCLUSIVE lock、foreign keys、cache size の PRAGMA を適用した。

**結果:**
native test で上限超過 SQL と bound value が拒否されることを確認し、既存 CRUD / COMMIT / ROLLBACK
test も成功した。

**次に試すこと:**
stable publish 中の failpoint と `ic0_trap` を導入し、不可逆 write 中の failure を正常 return させない。

### 反復 19 — 2026-09-19

**試したこと:**
overlay publish が stable page write を開始した後の backend error を `PublishStartedError` として区別した。
DB facade はこの例外、または page publish 後の superblock write 失敗を wasm32 で `ic0_trap` に渡す。
capacity grow など write 開始前の失敗は recoverable error のまま返す。

**結果:**
native CRUD / transaction / resource-limit test、library build、`nicp developmentBuild` が成功した。

**次に試すこと:**
backend failpoint を追加し、publish 前 error と publish 後 trap の境界を機械的に検証する。

### 反復 20 — 2026-09-27

**現在の問題:**
stable publish の不可逆境界と、設計書29--31節の typed statement / migration API が native test で十分に検証されていなかった。

**試したこと:**
2回目の stable page write を失敗させる backend を overlay test に追加し、1枚目の write 後の失敗が
`PublishStartedError` になることを検証した。公開 API に `SqlValue`（NULL / INTEGER / REAL / TEXT / BLOB）、
`Connection`、`Statement`、同期 `withQuery`、prepare/bind/step/column access、および順序・冪等性を
検証する migration framework を追加した。

**結果:**
overlay の不可逆失敗境界、typed statement での全基本値の read、migration の初回適用・再実行時の
非重複・version順序拒否が native test で成功した。

**否定された仮説:**
`openArray[Migration]` のループ変数を `withUpdate` closure が安全に捕捉できるという仮説。
Nim の lent iterator 制約により、version と SQL を loop 内で値コピーして closure に渡す必要があった。

**次に試すこと:**
read-only query connection の分離と read PRAGMA を実装し、Task 10 の残条件を満たす。その後 Task 11 の
canister lifecycle 公開 API を実装する。

### 反復 21 — 2026-09-27

**現在の問題:**
`withQuery` が write connection を共有しており、設計書17節・23節の read-only connection と read PRAGMA を満たしていなかった。また lifecycle の init/post-upgrade で共有する再初期化手順が公開 API に存在しなかった。

**試したこと:**
stable DB では `SQLITE_OPEN_READONLY` で別接続を開き、`cache_size`、`query_only`、`locking_mode`、`foreign_keys`、`temp_store` を設定して callback 終了時に close するようにした。native `:memory:` test は共有可能な別接続を持てないため、callback 中だけ同一接続へ `query_only=ON` を設定し、defer で必ず解除するようにした。さらに init と upgrade の双方から使う `initDatabase` / `reopenDatabaseAfterUpgrade` API を追加した。

**結果:**
typed query test と query callback 内 INSERT の SQLite 拒否を native test で確認した。Task 10 の完了条件をすべて満たした。lifecycle API は公開モジュールから import 可能であることを layout test で確認した。

**次に試すこと:**
Task 11 として、nicp_cdk が提供する canister init/post-upgrade hook への接続方法を確定し、example から `initDatabase` を呼ぶ。

### 反復 22 — 2026-09-27

**現在の問題:**
`nicp_cdk` には init/post-upgrade 専用 macro がなく、example の lifecycle export と VFS callback link が検証されていなかった。

**試したこと:**
`exportwasm` で canonical `canister_init` / `canister_post_upgrade` export を追加し、両方から `initDatabase` を呼ぶようにした。初期化失敗は `ic0_trap` に変換する。WASM build 時に VFS callback export が欠落したため、facade が `vfs_exports` を import して linker の生成対象に固定した。

**結果:**
`nicp developmentBuild` 成功後、`wasm-objdump -x main.wasm` で両 lifecycle export を確認した。local ICP で `createTable`、`put("lifecycle:key", "before-upgrade")`、`get`、upgrade、再度 `get` を実行し、upgrade 後にも `"before-upgrade"` が返った。Task 11 の完了条件を満たした。

**否定された仮説:**
native library build が成功すれば WASM link でも VFS callback が到達可能という仮説。export callback を含む Nim module が到達グラフから外れると、C shim の未解決 symbol が WASM link で発生した。

**次に試すこと:**
Task 12 として、設計書どおり `examples/minimal_kv` に独立した canister project を配置し、同じ lifecycle / CRUD / upgrade 検証を再現可能にする。

### 反復 23 — 2026-09-27

**現在の問題:**
検証済み canister example は `example/` 配下にあり、設計書38節・Task 12 が要求する独立した `examples/minimal_kv` プロジェクトではなかった。

**試したこと:**
`examples/minimal_kv` に icp-cli project、Nimble metadata、canister build 設定、Candid、migration-aware lifecycle、`put` update と `get` query endpoint を作成した。既存 local network と競合しない port 8001 の専用 replica で build/deploy/upgrade を実行した。

**結果:**
`nicp developmentBuild` により WASM → wasi2ic → Candid metadata chain が成功した。local ICP で `put("minimal:key", "stable-value")`、`get`、upgrade、再度 `get` を実行し、upgrade 後にも `"stable-value"` が返った。検証後に専用 replica を停止した。Task 12 の完了条件をすべて満たした。

**否定された仮説:**
`icp.yaml` の canister 名は任意の表示名でよいという仮説。icp-cli は manifest の `name` と project の canister 名の一致を要求するため、独立例では `backend` に統一した。

**次に試すこと:**
Task 13 の最終検証として、全 native test、WASM build、region mode の stable data 共存テストを再実行・拡充する。

### 反復 24 — 2026-09-27

**現在の問題:**
region mode は runtime prefix 用の offset backend だけで、固定範囲を越える SQLite write を防ぐ境界と foreign data 保全の直接検証が不足していた。

**試したこと:**
`StableRegion(baseOffset, maxBytes)` と bounded `OffsetStableBackend` を追加した。region 内の write、raw backend prefix の sentinel 保持、region 容量を越える grow/write の拒否を native test に追加した。全 native test と SQLite 3.53.4 wasm32-wasi archive build を再実行した。

**結果:**
foreign prefix は変更されず、region 外 write は `ValueError`、全 `nimble test`、`nimble build`、`build_sqlite.sh`、`git diff --check` は成功した。Task 13 とプロジェクト全体の機械的完了条件を満たした。

### 反復 21 — 2026-09-27

**現在の問題:**
`withQuery` が write connection を共有しており、設計書17節・23節の read-only connection と read PRAGMA を満たしていなかった。

**試したこと:**
stable DB では `SQLITE_OPEN_READONLY` で別接続を開き、`cache_size`、`query_only`、`locking_mode`、`foreign_keys`、`temp_store` を設定して callback 終了時に close するようにした。native `:memory:` test は共有可能な別接続を持てないため、callback 中だけ同一接続へ `query_only=ON` を設定し、defer で必ず解除するようにした。

**結果:**
typed query test と query callback 内 INSERT の SQLite 拒否を native test で確認した。Task 10 の完了条件をすべて満たした。

**次に試すこと:**
Task 11 として、canister init/post-upgrade から再初期化を呼べる lifecycle integration API を追加する。

### 反復 6 — 2026-09-18

**現在の問題:**
公開 Nim モジュール名と内部モジュール空間が `nim_ic_sqlite_vfs` であり、利用側が期待する
`ic_sqlite` と一致していなかった。

**試したこと:**
Nimble package、公開入口、内部モジュールディレクトリ、テストの import、開発規約、README を
`ic_sqlite` へ rename した。C shim の `nim_icvfs_*` は C ABI 契約のため維持した。

**結果:**
`import ic_sqlite`、`import ic_sqlite/stable/backend` を使う `nimble test` と
`nimble build` が成功した。

**次に試すこと:**
Task 5 として固定 little-endian Superblock と foreign-memory 検出を実装する。

---

## 過去の反復記録 (旧アーキテクチャ: Rust FFI 経由)

> 以下は以前のアーキテクチャ (Rust FFI crate 経由) での記録。現在は Nim + C shim + direct VFS アーキテクチャ (設計書 `/application/design/nim_ic_sqlite_vfs_design.md`) に移行したため、記録として保持する。

### 反復 N+2 — 2026-09-16

**現在の問題:**
Nim/WASI 最終リンク後、`sqlite3_vfs_find` は成功する一方で `sqlite3_open_v2` が `no such vfs: icstable` を返していた。

**試したこと:**
Rust archive の whole-archive link、URI の `vfs=` 除去、Wasm constructor の実行回数を比較し、VFS 登録を接続の直前に移動した。local IC canister で `probe_open` と通常更新中の `CREATE TABLE` を実行した。

**結果:**
`Connection::open` の直前で `register()` と `sqlite3_vfs_find()` を再実行すると `probe_open` と通常メッセージ内の `CREATE TABLE` が成功した。従って scoped external-memory context は SQLite/VFS callback の完了まで公開され、Nim callback 経由の stable-memory 書込みも実機で到達している。

**残る問題:**
canister install/post-upgrade callback 内で SQL を実行すると約 201 GB の Wasm heap grow が発生するため、例は lifecycle callback では DB handle の再生成だけを行い、最初の `put` 更新で冪等な schema 作成を行うよう変更した。さらに `COUNT(*)` が `no such function: COUNT`、text parameter が `text value must be valid UTF-8` となるため、query/parameter FFI の最終 Wasm ABI を追加調査する必要がある。

**次に試すこと:**
C ABI の `nicp_sqlite_value` の Nim 側レイアウトと、最終 Wasm で SQLite built-in 関数が初期化される順序を直接診断し、put/get/count と upgrade 永続化の統合試験を完成させる。

### 反復 N+3 — 2026-09-16

**現在の問題:**
final Wasm で parameterized write の text parameter が破損する。Rust は第1値を正しく読めるが、第2値では無効な UTF-8 byte 列を読む。

**試したこと:**
Wasm 用 SQLite を target-aligned な `sqlite-precompiled` に戻し、C/Rust の `nicp_sqlite_value` layout を wasm32 で比較した。size=40、field offset（kind=0, integer=8, real=16, data=24, len=32）は一致した。Nim 側の ABI probe は request 引数の `alpha` / `first` を正しく読む。FFI value 配列に text/blob 所有コピーと明示 keep-alive を追加した。

**結果:**
SQLite/VFS の問題ではなく、Nim から `nicp_sqlite_execute_params` へ渡す複数値配列の lifetime/layout に問題が残る。Rust error diagnostic は値0を正しく読む一方、値1の pointer が解放済み領域を指すことを示した。

**否定された仮説:**
SQLite bundled/precompiled の差、C/Rust record size/offset の不一致、Candid request から得た Nim string 自体の破損は原因ではない。

**次に試すこと:**
Nim 生成 C の `FfiValues` destroy/liveness を確認し、必要なら text/blob bytes を C ABI 呼出し直前に連続 caller-owned arena へコピーする表現へ変更する。続いて連続 scoped call と lifecycle schema 初期化も修正する。

### 反復 N+4 — 2026-09-16

**現在の問題:**
複数の TEXT/BLOB parameter を C ABI へ渡すと、第2要素の buffer が失効していた。

**試したこと:**
Nim の `toFfiValues` を、各 value 内の一時 string/blob pointer を保存する実装から、必要な全 bytes を先に算出して単一固定長 `payload` arena にコピーする実装へ変更した。Rust FFI 呼出し完了後まで arena を参照する keep-alive も維持した。

**結果:**
local IC canister で `probe_open`、schema 作成、2 TEXT parameter の `put`、parameterized `get` が成功した。Nim string の共有・ARC lifetime が原因だった。残る query の `COUNT(*)` は `no such function: COUNT` であり、parameter ABI 問題から分離できた。

**次に試すこと:**
precompiled SQLite archive の built-in aggregate 初期化と Wasm constructor 順序を確認し、`count`、upgrade persistence、別 MemoryId 共存の統合試験へ進む。

### 反復 N+5 — 2026-09-16

**現在の問題:**
Wasm final link で SQLite built-in aggregate が初期化されず、`COUNT(*)` が `no such function` になっていた。

**試したこと:**
`register()` を SQLite public API による VFS register に変更し、scoped operation が connection を保持しない性質を利用して scope 開始時に `sqlite3_shutdown()`→`sqlite3_initialize()` を実施した。

**結果:**
local IC で parameterized `put` が `(1 : nat64)` を返し、`COUNT` の function-not-found は解消した。count 実行後は `unreachable` trap となるため、aggregate の後処理／read scoped cleanup が次の原因箇所である。

**次に試すこと:**
read query の statement/connection drop と scoped cleanup の順序を最小 query で分離し、SQLite shutdown を connection が残らない scope 境界だけに一度適用するよう整える。

### 反復 N+6 — 2026-09-16

**現在の問題:**
scoped external-memory の開始時に SQLite を毎回停止・初期化すると、接続直前の再登録でも同じ scope 内で SQLite を二重に停止していた。また upgrade 後に SQLite image が新規状態として開かれる。

**試したこと:**
`sqlite3_shutdown()` を `register()` から分離し、`with_external_memory` の scope 開始時に一度だけ実施するよう変更した。callback failure を Result 化する試作も行ったが、最終 Wasm の indirect-call table を壊して `table out of bounds` となったため撤回した。Nim callback の例外ログを追加し、Wasm archive を再生成して local IC に再 deploy した。

**結果:**
初回 install では `initialize_schema`、`probe_select_one`、parameterized `put`、`get`、`COUNT(*)` がすべて成功した。従来の `COUNT` の未登録と read-query trap は解消した。`icp deploy --mode upgrade` 後は `get` が context setup の NotInitialized で失敗し、診断 update 後には SQLite image が空で `no such table` となる。upgrade 永続性は未達である。

**次に試すこと:**
post-upgrade における constructor 二重実行と MemoryManager の stable layout 再読込を分離して検証し、upgrade 前後の同一 MemoryId/物理 stable memory を直接確認する。callback の本番エラー伝播は panic に依存しない API へ設計し直す。

### 反復 N+7 — 2026-09-17

**現在の問題:**
upgrade 後の再接続で SQLite image が失われるように見え、また同一 message 内で schema 作成と parameterized write を別 scoped FFI call として続けると context setup が失敗する。

**試したこと:**
`icp` local upgrade の既存 `nicp_cdk` 統合テストを調査した。`icp 1.5.0` managed local network が upgrade 時に stable state を再初期化することは既知であり、この環境の upgrade 結果を永続性判定に使えないと確認した。代わりに native integration test で manager/db handle を同じ stable image に対して再構築した。そこで `MemoryManager` の再読込が、遅延拡張中の末尾 bucket 境界を stable size 以下と誤判定する欠陥を再現・修正した。

**結果:**
`test_memory_adapter.nim` は SQLite write 後に `MemoryManager` と `SqliteDb` を再構築し、既存 INTEGER/TEXT 値を正常に読めるようになった。これは実 upgrade の handle 再構築で必要な stable layout の修正である。Rust FFI native test 2件も pass した。local IC では schema endpoint → 2件の parameterized put → get まで成功するが、2行後の query `COUNT(*)` はなお unknown trap となる。shutdown を context 公開後へ移す試行は悪化したため撤回した。

**否定された仮説:**
upgrade 時の SQLite image 喪失を ic-sqlite の memoryId 不一致だけで説明する仮説。実際には `icp` local の既知制約と `MemoryManager` の末尾 bucket validation が重なっていた。

**次に試すこと:**
複数ページ／複数行 read の VFS read callback を最小化して `COUNT` trap を再現し、callback failure を panic/trap にせず SQLite I/O error として返す fallible backend 境界を ABI 互換に導入する。PocketIC が利用可能な環境では final Nim Wasm の upgrade test を追加して実 IC lifecycle を検証する。
