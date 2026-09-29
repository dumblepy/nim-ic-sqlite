# Nim版 `ic-sqlite-vfs` 設計書・実装方針

- 文書種別: アーキテクチャ設計 / 実装計画
- 対象: Internet Computer Protocol (ICP) canister
- 実装言語: Nim + C (SQLite ABI shim)
- 想定CDK: [`dumblepy/nicp_cdk`](https://github.com/dumblepy/nicp_cdk)
- 参照実装: [`humandebri/ic-sqlite-vfs`](https://github.com/humandebri/ic-sqlite-vfs)
- 調査日: 2026-09-17

---

## 1. 目的

Rustの `ic-sqlite-vfs` と同じ基本思想、すなわち **SQLiteのVirtual File System (VFS) を独自実装し、SQLiteのDBイメージをICPのstable memoryへ直接保存する** 方式をNimで実現する。

本設計では、SQLiteを通常のWASIファイルシステムへ接続せず、次の経路で動作させる。

```text
Nim Canister API
    |
    v
Nim DB facade
    |
    v
SQLite C core
    |
    v
custom sqlite3_vfs / sqlite3_io_methods
    |
    v
Nim VFS implementation
    |
    v
nicp_cdk ic0_stable64_* API
    |
    v
ICP Stable Memory
```

SQLite本体はCのamalgamation (`sqlite3.c`) をWASMへコンパイルする。

VFS ABIそのものはCの構造体・関数ポインタを多用するため、SQLite ABI境界だけは薄いC shimに閉じ込め、DBイメージ管理、overlay、stable memory、transaction facadeなどの主要ロジックをNimで実装する。

---

## 2. 結論

推奨方式は以下である。

1. SQLiteを `SQLITE_OS_OTHER=1` でビルドする。
2. Unix/WASI標準VFSを使わず、`sqlite3_os_init()` から独自VFS `icstable` を登録する。
3. `sqlite3_vfs` / `sqlite3_io_methods` のABI部分は小さなC shimに実装する。
4. C shimからNimの `{.exportc, cdecl.}` コールバックを呼び出す。
5. `/main.db` のみstable memoryへ保存する。
6. journal/temp fileはheap上の一時ファイルとして扱う。
7. 更新中のSQLite `xWrite` を直接stable memoryへ書かず、Nim heapのpage overlayへ書く。
8. SQLiteの `COMMIT` 成功後にdirty pageをstable memoryへ書き、最後にsuperblockを更新する。
9. stable memoryへのpublish開始後に異常が発生した場合は、エラーを握りつぶしてreturnせず `ic0_trap` してICP message rollbackに任せる。
10. update transaction中は `await` / inter-canister call / `ic0.call_perform` を禁止する。
11. WALは使用しない。
12. productionではSQLite DBが使用するstable memory領域の所有権を明確にする。

最初の実装では **SQLite用stable memoryをcanister内で専有させる** のが最も安全である。

複数のstable structureと共存させる場合は、その後のフェーズで明示的なstable-memory region管理またはMemoryManager相当の仮想メモリ層を追加する。

---

## 3. 参照実装から読み取れる重要点

### 3.1 `ic-sqlite-vfs`

現行の `ic-sqlite-vfs` は、SQLiteのI/OをPOSIX/WASIファイルAPIへ流すのではなく、独自 `sqlite3_vfs` からstable memoryへ直接接続している。

概念的には以下である。

```text
SQLite pager
  -> sqlite3_vfs: icstable
  -> sqlite3_io_methods
  -> VirtualMemory
  -> IC stable memory
```

主な特徴:

- `/main.db` をstable memoryへ保存
- temp/journalはheap
- WAL無効
- `SQLITE_THREADSAFE=0`
- `SQLITE_OS_OTHER=1`
- update transaction中はheap overlayへ書き込む
- `COMMIT` 成功後にdirty pageをstable memoryへ反映
- DBメタデータをsuperblockへ保存
- canister upgrade後もDBイメージをそのまま再利用
- transaction中にawaitしないことをdurability contractとする

特に重要なのは、単純な `xWrite -> stable_write` ではない点である。

SQLiteはtransaction途中でもDBファイルにdirty pageを書こうとする場合があるため、その書き込みを直ちにstable memoryへ反映すると、SQLite transactionがROLLBACKされた場合でもstable memoryだけ変更されてしまう。

そのため参照実装では、更新中の書き込みをheap overlayに保持している。

---

## 4. `nicp_cdk` との適合性

`nicp_cdk` はNimコードをCへ変換し、Clangで `wasm32-wasip1`（WASI preview 1）向けにコンパイルする。wasi-sdk 30 以降は旧 `wasm32-wasi` トリプルが非推奨であり、sysroot に `wasm32-wasi` 向けヘッダが含まれないため `wasm32-wasip1` を使う。

標準プロジェクトのビルドは概ね次の構成を持つ。

```text
Nim
  -> generated C
  -> clang -target wasm32-wasip1
  -> static WASM
  -> ic-wasi-polyfill / wasi2ic
  -> ICP canister WASM
```

一方、stable memoryについては `nicp_cdk` から以下のraw APIを利用できる。

```nim
proc ic0_stable64_size*(): uint64
proc ic0_stable64_grow*(newPages: uint64): uint64
proc ic0_stable64_write*(offset, src, size: uint64)
proc ic0_stable64_read*(dst, offset, size: uint64)
```

したがってSQLite VFSからstable memoryへ直接アクセスするための必須機能はすでに存在する。

`nicp_cdk/storage/libs/stable_memory.nim` にも以下のようなwrapperが存在する。

```nim
stableSizePages()
stableSizeBytes()
ensureStableSize()
stableWrite()
stableRead()
stableReadInto()
```

ただしSQLite VFSではコピー回数を減らすため、`seq[byte]`を生成するAPIだけでなく、raw pointer版も用意した方がよい。

例:

```nim
proc stableReadRaw(dst: pointer, offset, size: uint64) =
  ic0_stable64_read(
    cast[uint64](dst),
    offset,
    size
  )

proc stableWriteRaw(offset: uint64, src: pointer, size: uint64) =
  ic0_stable64_write(
    offset,
    cast[uint64](src),
    size
  )
```

---

## 5. 推奨アーキテクチャ

```text
+---------------------------------------------------------+
| Canister application                                    |
|                                                         |
|  put/get/search/...                                     |
+-----------------------------+---------------------------+
                              |
                              v
+---------------------------------------------------------+
| Nim DB facade                                           |
|                                                         |
|  IcSqliteDb                                             |
|  Connection                                             |
|  Statement                                              |
|  UpdateConnection                                       |
|  migrations                                             |
+-----------------------------+---------------------------+
                              |
                              v
+---------------------------------------------------------+
| sqlite_api.nim                                          |
|                                                         |
| sqlite3_open_v2                                         |
| sqlite3_prepare_v2                                      |
| sqlite3_bind_*                                          |
| sqlite3_step                                            |
| sqlite3_column_*                                        |
| sqlite3_finalize                                        |
+-----------------------------+---------------------------+
                              |
                              v
+---------------------------------------------------------+
| SQLite C core (sqlite3.c)                               |
+-----------------------------+---------------------------+
                              |
                              v
+---------------------------------------------------------+
| C ABI shim                                              |
|                                                         |
| sqlite3_vfs                                             |
| sqlite3_io_methods                                      |
| sqlite3_os_init                                         |
| sqlite3_os_end                                          |
+-----------------------------+---------------------------+
                              |
                              v
+---------------------------------------------------------+
| Nim VFS                                                 |
|                                                         |
| main file                                               |
| temp files                                              |
| lock state                                              |
| overlay                                                 |
+-----------------------------+---------------------------+
                              |
                              v
+---------------------------------------------------------+
| Stable backend                                          |
|                                                         |
| Superblock                                              |
| DB page image                                           |
| zero extents                                            |
+-----------------------------+---------------------------+
                              |
                              v
+---------------------------------------------------------+
| nicp_cdk -> ic0.stable64_*                              |
+---------------------------------------------------------+
```

---

## 6. なぜC shimを置くのか

Nimから直接 `sqlite3_vfs` と `sqlite3_io_methods` を完全に再定義することも可能だが、推奨しない。

理由:

- C ABI上のstruct layoutを完全一致させる必要がある
- SQLite versionによるfield差分を吸収しにくい
- function pointer型の宣言が大量に必要
- `sqlite3_file` の先頭field制約などをNim側で壊しやすい
- SQLite headerそのものを使うCの方がABI安全性が高い

そのため、ABIのみCに置く。

### C shimの責務

```text
SQLite
  -> C callback
  -> Nim exported callback
```

例:

```c
typedef struct IcFile {
    sqlite3_file base;
    uint32_t handle_id;
} IcFile;
```

C側の `xRead`:

```c
static int ic_xRead(
    sqlite3_file *file,
    void *buf,
    int amount,
    sqlite3_int64 offset
) {
    IcFile *f = (IcFile *)file;
    return nim_icvfs_read(
        f->handle_id,
        buf,
        amount,
        offset
    );
}
```

Nim側:

```nim
proc nimIcvfsRead(
    handleId: uint32,
    dst: pointer,
    amount: cint,
    offset: int64
): cint {.exportc: "nim_icvfs_read", cdecl.} =
  try:
    result = vfsRead(handleId, dst, amount, offset)
  except CatchableError as e:
    setLastError(e.msg)
    result = SQLITE_IOERR_READ
```

重要事項:

> Nim exceptionをC/SQLite境界の外へunwindさせてはいけない。

すべてのexport callbackでcatchし、SQLite error codeへ変換する。

ただしstable commitのpublish途中に発生した致命的エラーだけは例外である。後述の通り、その場合はreturnではなくtrapする。

---

## 7. SQLiteのビルド方式

### 7.1 推奨compile flags

`ic-sqlite-vfs` と同じ方向で次を使用する。

```text
SQLITE_CORE
SQLITE_DEFAULT_FOREIGN_KEYS=1
SQLITE_ENABLE_API_ARMOR
SQLITE_ENABLE_FTS5
SQLITE_USE_URI
SQLITE_OS_OTHER=1
SQLITE_THREADSAFE=0
SQLITE_OMIT_WAL
SQLITE_TEMP_STORE=3
SQLITE_OMIT_LOCALTIME
SQLITE_OMIT_DEPRECATED
SQLITE_OMIT_LOAD_EXTENSION
SQLITE_OMIT_SHARED_CACHE
SQLITE_DEFAULT_MEMSTATUS=0
```

必須度が特に高いもの:

```text
SQLITE_OS_OTHER=1
SQLITE_THREADSAFE=0
SQLITE_OMIT_WAL
SQLITE_TEMP_STORE=3
SQLITE_OMIT_LOAD_EXTENSION
SQLITE_OMIT_SHARED_CACHE
```

### 7.2 `SQLITE_OS_OTHER=1`

これによりSQLite内蔵のUnix/Windows VFSを使用しなくなる。

代わりにこちらで次のsymbolを提供する。

```c
int sqlite3_os_init(void);
int sqlite3_os_end(void);
```

`sqlite3_os_init()` 内で独自VFSをregisterする。

```c
int sqlite3_os_init(void) {
    return sqlite3_vfs_register(&IC_VFS, 1);
}
```

### 7.3 WASIを完全排除する必要はない

`nicp_cdk` 自体は `wasm32-wasip1` と `ic-wasi-polyfill` を利用する。

このライブラリの目的は、canister全体からWASIをなくすことではない。

重要なのは **SQLiteのDB I/O経路がWASI filesystemを通らないこと** である。

つまり、

```text
Nim runtime
    -> WASI polyfillを利用してもよい

SQLite database I/O
    -> custom VFS
    -> stable memory
```

という構成にする。

---

## 8. SQLite archiveの生成

developmentでは `sqlite3.c` を直接コンパイルしてもよいが、productionでは事前にstatic archiveを生成する方がよい。

例:

```bash
#!/usr/bin/env bash
set -euo pipefail

CC="${WASI_SDK_PATH}/bin/clang"
AR="${WASI_SDK_PATH}/bin/llvm-ar"

mkdir -p build

"$CC" \
  --target=wasm32-wasip1 \
  -Os \
  -c vendor/sqlite/sqlite3.c \
  -o build/sqlite3.o \
  -DSQLITE_CORE \
  -DSQLITE_DEFAULT_FOREIGN_KEYS=1 \
  -DSQLITE_ENABLE_API_ARMOR \
  -DSQLITE_ENABLE_FTS5 \
  -DSQLITE_USE_URI \
  -DSQLITE_OS_OTHER=1 \
  -DSQLITE_THREADSAFE=0 \
  -DSQLITE_OMIT_WAL \
  -DSQLITE_TEMP_STORE=3 \
  -DSQLITE_OMIT_LOCALTIME \
  -DSQLITE_OMIT_DEPRECATED \
  -DSQLITE_OMIT_LOAD_EXTENSION \
  -DSQLITE_OMIT_SHARED_CACHE \
  -DSQLITE_DEFAULT_MEMSTATUS=0

"$AR" rcs build/libsqlite3_ic.a build/sqlite3.o
```

Nim側 `config.nims` では既存 `nicp_cdk` のWASI設定に加えて、

```nim
switch("passC", "-I" & projectDir / "vendor/sqlite")
switch("passC", "-I" & projectDir / "c")

switch("passL", projectDir / "build/libsqlite3_ic.a")
```

などを追加する。

C shimは、

```nim
{.compile: "../c/ic_sqlite_vfs_shim.c".}
```

または別static archiveとしてlinkする。

---

## 9. Stable memory所有モデル

ここがRust版をNimへ移植する際の最大の設計ポイントである。

`nicp_cdk` のstable storageは `baseOffset` を指定できるものが存在するが、SQLite DBは成長量が大きく、可変長である。

### 9.1 MVP: exclusive stable memory

最初のリリースではこれを推奨する。

```text
raw stable memory
┌───────────────────────────────┐ offset 0
│ SQLite superblock             │
│ 64 KiB                        │
├───────────────────────────────┤ offset 64 KiB
│ SQLite DB image               │
│                               │
│ grows upward                  │
│                               │
└───────────────────────────────┘
```

このモードでは、同一canisterで以下を使用しない。

```text
IcStableValue
IcStableSeq
IcStableTable
IcStableHashMap
```

少なくとも同じraw stable memory address rangeへ配置してはいけない。

SQLite自体が永続ストレージになるため、多くのアプリケーションではこれで十分である。

### 9.2 region mode

他のstable storageと共存させる場合:

```nim
type StableRegion = object
  baseOffset*: uint64
  maxBytes*: uint64
```

logical offsetを

```text
physical = baseOffset + logical
```

へ変換する。

ただしSQLiteより後方に別のdynamic storageを配置すると衝突する可能性がある。

したがって次のどちらかに限定する。

#### 方式A

```text
0 .. fixedPrefixEnd
    application metadata

fixedPrefixEnd .. infinity
    SQLite
```

SQLiteより前の領域を固定上限にする。

#### 方式B

MemoryManager相当を実装する。

### 9.3 将来: MemoryManager互換

複数SQLite DBや複数stable structureを安全に共存させたい場合、Rust版のようなMemoryManager方式を実装する。

```text
raw stable memory
    |
    +-- virtual MemoryId 1 -> SQLite A
    |
    +-- virtual MemoryId 2 -> SQLite B
    |
    +-- virtual MemoryId 3 -> metadata
```

これはMVPとは分離する。

---

## 10. Stable memoryレイアウト

最初のNim版では次を推奨する。

```text
SQLite stable region

offset +0
┌────────────────────────────────────┐
│ Superblock                         │
│ reserved size = 65536 bytes        │
├────────────────────────────────────┤
│ SQLite logical page 0              │
│                                    │
│ DB base = 65536                    │
├────────────────────────────────────┤
│ SQLite logical page 1              │
├────────────────────────────────────┤
│ ...                                │
└────────────────────────────────────┘
```

SQLite page size:

```text
16384 bytes
```

Stable memory page:

```text
65536 bytes
```

よって1 stable-memory pageにはSQLite pageを4枚配置できる。

---

## 11. Superblock

Nim objectをそのままbinary dumpしてはいけない。

compiler versionやalignmentの影響を受けない固定little-endian encodingにする。

例:

```text
0x0000  magic[8]            "NIMSQLV1"
0x0008  formatVersion       u32
0x000C  sqlitePageSize      u32
0x0010  dbSize              u64
0x0018  schemaVersion       u64
0x0020  lastTxId            u64
0x0028  flags               u64
0x0030  dbChecksum          u64
0x0038  zeroExtentCount     u64
0x0040  metaChecksum        u64
0x0048  reserved...
```

zero extent tableは後方へ配置する。

```text
ZeroExtent:
  startPage: u64
  endPage:   u64
```

### 必須field

```nim
type Superblock = object
  formatVersion: uint32
  sqlitePageSize: uint32
  dbSize: uint64
  schemaVersion: uint64
  lastTxId: uint64
  flags: uint64
  dbChecksum: uint64
  zeroExtents: seq[ZeroExtent]
```

metadata checksumにはFNV-1a 64などを利用できる。

これは暗号学的検証ではなく、破損・layout不一致検出が目的である。

---

## 12. foreign stable memoryの検出

初期化時にstable memoryが空でない場合、勝手にsuperblockを上書きしてはいけない。

次の判定を行う。

```text
stableSize == 0
    -> fresh SQLite regionを作成

stableSize > 0
    -> magicを読む

magic == "NIMSQLV1"
    -> load

magic != "NIMSQLV1"
    -> ForeignStableMemoryImage error
```

これにより既存stable storageを誤ってSQLite DBとして初期化する事故を防ぐ。

---

## 13. `sqlite3_vfs`

VFS versionはまず `iVersion = 1` で十分である。

実装対象:

```text
xOpen
xDelete
xAccess
xFullPathname
xRandomness
xSleep
xCurrentTime
xGetLastError
```

使用しない:

```text
xDlOpen
xDlError
xDlSym
xDlClose
xSetSystemCall
xGetSystemCall
xNextSystemCall
```

load extension自体をcompile-timeで無効にする。

---

## 14. `sqlite3_io_methods`

実装対象:

```text
xClose
xRead
xWrite
xTruncate
xSync
xFileSize
xLock
xUnlock
xCheckReservedLock
xFileControl
xSectorSize
xDeviceCharacteristics
```

使用しない:

```text
xShmMap
xShmLock
xShmBarrier
xShmUnmap
xFetch
xUnfetch
```

WALを無効にするためshared-memory APIは不要である。

---

## 15. File classification

`xOpen()` ではSQLiteのfilename/flagsから種類を分類する。

```nim
type FileKind = enum
  fkMainDb
  fkTemp
```

内部的には必要に応じて、

```text
MainDb
MainJournal
TempDb
TempJournal
TransientDb
Wal
Other
```

を分類してもよい。

ルール:

```text
/main.db
    -> stable memory

WAL
    -> SQLITE_CANTOPEN

others
    -> heap temp file
```

---

## 16. heap temp file

temp fileは単純な

```nim
type TempFile = object
  data: seq[byte]
```

でよい。

必要operation:

```nim
proc readAt(...)
proc writeAt(...)
proc truncate(...)
proc len(...)
```

SQLiteのjournal/temp_storeをMEMORYに設定するため、通常のDBデータだけがstable memoryへ残る。

---

## 17. SQLite PRAGMA

write connection:

```sql
PRAGMA page_size = 16384;
PRAGMA journal_mode = MEMORY;
PRAGMA synchronous = OFF;
PRAGMA temp_store = MEMORY;
PRAGMA locking_mode = EXCLUSIVE;
PRAGMA foreign_keys = ON;
PRAGMA cache_size = -32768;
```

既存DBでは `page_size` を再設定しない。

read-only connection:

```sql
PRAGMA cache_size = -32768;
PRAGMA query_only = ON;
PRAGMA locking_mode = EXCLUSIVE;
PRAGMA foreign_keys = ON;
PRAGMA temp_store = MEMORY;
```

### なぜ `synchronous=OFF` でよいのか

通常のSQLiteでは危険な設定だが、この設計ではdurability boundaryはfilesystem `fsync` ではなくICP message executionである。

DB更新の原子性は次の組み合わせに依存する。

```text
SQLite transaction
+
heap overlay
+
ICP message rollback
```

---

## 18. 最重要: update overlay

### 18.1 問題

以下の実装は不可。

```text
SQLite xWrite
  -> ic0_stable64_write
```

SQLite transaction途中でxWriteされる可能性があり、後でROLLBACKされた場合にstable memoryだけ更新済みになるからである。

### 18.2 Overlay

```nim
type Overlay = object
  baseSize: uint64
  size: uint64

  dirtyPages:
    OrderedTable[uint64, seq[byte]]

  cleanPages:
    small page cache

  zeroExtents:
    seq[ZeroExtent]
```

update開始時:

```text
baseSize = superblock.dbSize
size     = baseSize
```

### 18.3 read path

```text
xRead(offset, len)

1. dirty pageに存在
      -> overlayから読む

2. zero extent
      -> 0で埋める

3. clean cache
      -> cacheから読む

4. stable DB image
      -> stable memoryから読む
```

### 18.4 write path

full SQLite page write:

```text
offset % 16384 == 0
len == 16384
```

ならbase pageをreadせずdirty pageへ直接格納する。

partial writeの場合:

```text
load base page
apply partial bytes
store full dirty page
```

このfast pathはstable read削減に重要である。

---

## 19. truncateとzero extent

stable memoryは物理的には縮小できない。

例:

```text
DB size 100 MiB
    ↓ truncate
DB size 20 MiB
    ↓ later grow
DB size 40 MiB
```

20〜40 MiB部分に昔のデータが残っていると、再度有効化された際にSQLiteから見えてしまう。

対策:

```text
ZeroExtent(startPage, endPage)
```

をsuperblockへ保存し、その範囲はlogical zeroとして扱う。

dirty pageが書き込まれた場合はzero extentからそのpageを除外する。

MVPでzero extentを省略する場合、growth時に必ず新規有効範囲を物理zero fillする必要がある。

production実装ではpersistent zero extent方式を推奨する。

---

## 20. transaction lifecycle

update APIは次の流れにする。

```text
beginUpdate()
    |
    v
create heap overlay
    |
    v
BEGIN IMMEDIATE
    |
    v
application SQL
    |
    +---- error ----> ROLLBACK
    |                discard overlay
    |                return error
    |
    v
SQLite COMMIT
    |
    +---- error ----> ROLLBACK
    |                discard overlay
    |
    v
publish overlay to stable memory
    |
    v
update superblock LAST
    |
    v
success
```

Nim擬似コード:

```nim
proc withUpdate[T](
  db: var IcSqliteDb,
  body: proc(conn: var UpdateConnection): Result[T, DbError] {.closure.}
): Result[T, DbError] =

  db.beginOverlay()

  let conn = db.openWriteConnection()

  if conn.exec("BEGIN IMMEDIATE").isErr:
    db.rollbackOverlay()
    return err(...)

  var updateConn = UpdateConnection(conn: conn)
  let userResult = body(updateConn)

  if userResult.isErr:
    discard conn.exec("ROLLBACK")
    db.rollbackOverlay()
    return userResult

  if conn.exec("COMMIT").isErr:
    discard conn.exec("ROLLBACK")
    db.rollbackOverlay()
    return err(...)

  db.publishOverlayOrTrap()

  return userResult
```

---

## 21. stable commitの原子性

publishは次の順序にする。

```text
1. required stable capacity確認
2. stable memoryをgrow
3. dirty pageを書き込む
4. superblockを最後に書く
```

重要:

```text
dirty page write
    ↓
superblock write
```

の途中でエラーになった場合、通常returnしてはいけない。

理由:

- errorをcatchしてcanister methodが正常終了すると
- そのmessage中に行ったstable writeがcommitされる
- superblockだけ旧状態になる可能性がある

したがってstable publish開始後の不可逆段階でエラーになったら:

```nim
ic0_trap(...)
```

でmessage全体をrollbackさせる。

擬似コード:

```nim
proc publishOverlayOrTrap(db: var IcSqliteDb) =
  let plan = prepareCommit(db.overlay)

  ensureCapacity(plan.requiredEnd)

  var startedStableWrite = false

  try:
    for pageNo in plan.dirtyPages.sorted:
      startedStableWrite = true
      stableWritePage(pageNo, plan.page(pageNo))

    writeSuperblock(plan.newSuperblock)

  except CatchableError as e:
    if startedStableWrite:
      trap("sqlite stable commit failed: " & e.msg)
    else:
      raise
```

実際には `ensureCapacity()` もpublish前に完全検証し、stable write開始前に起こり得るerrorはすべて潰しておく。

---

## 22. `await`禁止

durability contract:

```text
one update call
    =
one SQLite transaction
    =
one synchronous IC message execution
```

transaction中は次を禁止する。

```text
await
inter-canister call
ic0.call_perform
```

NimではRustほど型システムで強く制約できないが、callback型を同期procに限定する。

```nim
proc withUpdate[T](
  body:
    proc(conn: var UpdateConnection):
      Result[T, DbError] {.closure.}
)
```

`.async` procは `Future[...]` を返すため、このsignatureには一致しない。

ただしraw `ic0_call_perform` をcallback内から直接呼ぶことまではコンパイラで禁止できない。

そのためAPI documentationでも明確に禁止する。

---

## 23. read-only query

queryでは:

```text
SQLITE_OPEN_READONLY
PRAGMA query_only = ON
```

を使用する。

MVPでは1 query callにつきconnectionをopen/closeしてもよい。

最適化フェーズではread connectionをheapにcacheする。

canister upgrade時にheapは消えるため、connection stateをstable memoryへ保存する必要はない。

---

## 24. locking

ICP canisterは通常のOS processのようなparallel thread共有ファイルを持たない。

さらに:

```text
SQLITE_THREADSAFE=0
locking_mode=EXCLUSIVE
```

とする。

したがって実ファイルlockは不要だが、SQLiteが期待するlock stateは返す。

```nim
type LockLevel = enum
  lkNone
  lkShared
  lkReserved
  lkPending
  lkExclusive
```

`xLock` / `xUnlock` はheap stateのみ更新する。

複数SQLite DBを将来サポートする場合はDB contextごとにlock stateを持つ。

---

## 25. `xSync`

`xSync()` はno-opでよい。

```c
return SQLITE_OK;
```

この設計のdurabilityはfilesystem syncではなくIC message atomicityに依存する。

---

## 26. `xRandomness`

SQLiteのVFS randomnessはreplica間で決定論的である必要がある。

例:

```text
seed =
  lastTxId
  XOR dbSize
  XOR per-message counter
```

からxorshift等を使用する。

これは暗号乱数ではない。

SQLiteの

```sql
random()
randomblob()
```

を

```text
token
nonce
password reset secret
cryptographic id
```

へ利用してはいけない。

暗号用途ではICPのrandomness API等で取得した値をbound parameterとしてSQLへ渡す。

---

## 27. `xCurrentTime`

ICPの `ic0.time` 相当からnanosecondsを取得し、SQLite VFSのJulian day表現へ変換する。

`xCurrentTimeInt64` は概念的に:

```text
unixMilliseconds
+
210866760000000
```

を返す。

local timezoneは使わない。

---

## 28. SQLite FFI layer

NimからはSQLiteの公開C APIを直接importする。

例:

```nim
type
  Sqlite3 {.importc: "sqlite3",
             header: "sqlite3.h",
             incompleteStruct.} = object

  Sqlite3Stmt {.importc: "sqlite3_stmt",
                 header: "sqlite3.h",
                 incompleteStruct.} = object

proc sqlite3_open_v2(
  filename: cstring,
  db: ptr ptr Sqlite3,
  flags: cint,
  vfs: cstring
): cint {.importc, cdecl, header: "sqlite3.h".}

proc sqlite3_prepare_v2(
  db: ptr Sqlite3,
  sql: cstring,
  nByte: cint,
  stmt: ptr ptr Sqlite3Stmt,
  tail: ptr cstring
): cint {.importc, cdecl, header: "sqlite3.h".}

proc sqlite3_step(
  stmt: ptr Sqlite3Stmt
): cint {.importc, cdecl, header: "sqlite3.h".}

proc sqlite3_finalize(
  stmt: ptr Sqlite3Stmt
): cint {.importc, cdecl, header: "sqlite3.h".}
```

TEXT/BLOB bindで `SQLITE_TRANSIENT` を使用するため、小さなC helperを置くのが安全である。

例:

```c
int ic_sqlite_bind_text(
    sqlite3_stmt *stmt,
    int idx,
    const char *data,
    int len
) {
    return sqlite3_bind_text(
        stmt,
        idx,
        data,
        len,
        SQLITE_TRANSIENT
    );
}
```

---

## 29. DB facade

VFSだけでは利用性が低いため、小さなtyped DB facadeを用意する。

```nim
type
  DbError* = object
    code*: int
    message*: string

  IcSqliteDb* = object
    config*: DbConfig

  Connection* = object
    raw*: ptr Sqlite3

  Statement* = object
    raw*: ptr Sqlite3Stmt

  UpdateConnection* = object
    conn*: ptr Connection
```

最低API:

```nim
proc init*(db: var IcSqliteDb, config: DbConfig): Result[void, DbError]

proc withUpdate*[T](...)
proc withQuery*[T](...)

proc exec*(conn: var Connection, sql: string): Result[int, DbError]

proc prepare*(conn: var Connection, sql: string):
  Result[Statement, DbError]

proc bind*(stmt: var Statement, index: int, value: ...)
proc step*(stmt: var Statement): Result[StepResult, DbError]

proc columnInt64*(...)
proc columnFloat64*(...)
proc columnText*(...)
proc columnBlob*(...)
proc columnIsNull*(...)
```

---

## 30. parameter binding

public application APIではSQL文字列連結を避ける。

サポート型:

```text
NULL
INTEGER -> int64
REAL    -> float64
TEXT    -> string
BLOB    -> seq[byte]
```

Nim側:

```nim
type SqlValueKind = enum
  svNull
  svInt
  svFloat
  svText
  svBlob
```

`SqlValue` を用意してもよい。

---

## 31. migration

migrationはversion順に適用する。

例:

```nim
type Migration = object
  version*: uint64
  sql*: string
```

```nim
const migrations = [
  Migration(
    version: 1,
    sql: """
      CREATE TABLE kv (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      );
    """
  )
]
```

library管理table:

```sql
CREATE TABLE IF NOT EXISTS __nim_ic_sqlite_migrations (
  version INTEGER PRIMARY KEY NOT NULL
);
```

migration SQLはstatic trusted SQLのみとする。

user inputをmigration SQLへ連結しない。

---

## 32. canister upgrade

SQLite DB本体はstable memoryにあるため、通常のheap serialize/deserializeは不要。

upgrade後に必要なのは:

```text
1. VFS global state再初期化
2. stable backend再bind
3. superblock load
4. SQLite connection再open
5. migration実行
```

heap上の以下は消えてよい。

```text
SQLite connection
prepared statements
lock state
overlay
temp files
page cache
```

upgrade中にactive transactionが存在することはない。

---

## 33. lifecycle integration

canister initおよびpost-upgradeの両方から共通初期化関数を呼ぶ。

概念例:

```nim
proc initDatabase() =
  sqliteDb.init(
    DbConfig(
      stableMode: exclusiveStableMemory,
      sqlitePageSize: 16384
    )
  ).get()

  sqliteDb.migrate(migrations).get()
```

`nicp_cdk` が提供するinit/post-upgrade lifecycle hookから `initDatabase()` を呼ぶ。

---

## 34. stable backend interface

テストしやすくするためstable memoryアクセスをinterface化する。

```nim
type StableBackend = ref object of RootObj

method sizePages*(self: StableBackend): uint64 {.base.}
method grow*(self: StableBackend, pages: uint64): bool {.base.}

method read*(
  self: StableBackend,
  offset: uint64,
  dst: pointer,
  size: uint64
) {.base.}

method write*(
  self: StableBackend,
  offset: uint64,
  src: pointer,
  size: uint64
) {.base.}
```

production:

```text
IcStableBackend
    -> ic0_stable64_*
```

native test:

```text
VecStableBackend
    -> seq[byte]
```

これによりnative環境でoverlay/superblock/VFSロジックを高速にテストできる。

---

## 35. エラーコードmapping

例:

```text
read failure       -> SQLITE_IOERR_READ
write failure      -> SQLITE_IOERR_WRITE
truncate failure   -> SQLITE_IOERR_TRUNCATE
invalid main open  -> SQLITE_CANTOPEN
readonly write     -> SQLITE_READONLY
WAL open           -> SQLITE_CANTOPEN
```

foreign stable image:

```text
DbError.ForeignStableMemoryImage
```

layout version mismatch:

```text
DbError.UnsupportedLayoutVersion
```

---

## 36. メモリ上限

overlayはdirty pageをheapへ保持する。

巨大transactionでは:

```text
dirtyPages * 16384 bytes
```

がheapを消費する。

そのため設定値として:

```nim
DbConfig:
  maxDirtyPages
  maxDirtyBytes
  maxSqlBytes
  maxBlobBytes
```

を持たせる。

限界を超える場合はstable commit開始前にrecoverable errorを返す。

public canister methodでも:

```text
LIMIT
pagination
input length limit
BLOB size limit
```

を設定する。

---

## 37. arbitrary SQL endpointを公開しない

production canisterで

```text
execute(sql: text)
query(sql: text)
```

のようなpublic endpointをそのまま公開するのは推奨しない。

理由:

- full scan
- huge result
- join explosion
- LIKE '%...%'
- unbounded ORDER BY
- huge BLOB
- instruction limit exhaustion

application-specific endpointへ閉じ込める。

---

## 38. 推奨directory構成

```text
ic-sqlite-vfs/
├── nim_ic_sqlite_vfs.nimble
├── README.md
├── LICENSE
├── build/
├── scripts/
│   └── build_sqlite.sh
├── vendor/
│   └── sqlite/
│       ├── sqlite3.c
│       └── sqlite3.h
├── c/
│   ├── ic_sqlite_vfs_shim.c
│   ├── ic_sqlite_vfs_shim.h
│   └── sqlite_helpers.c
├── src/
│   └── nim_ic_sqlite_vfs/
│       ├── db.nim
│       ├── connection.nim
│       ├── statement.nim
│       ├── value.nim
│       ├── migration.nim
│       ├── ffi/
│       │   ├── sqlite_api.nim
│       │   └── vfs_exports.nim
│       ├── vfs/
│       │   ├── vfs.nim
│       │   ├── file.nim
│       │   ├── temp_file.nim
│       │   ├── overlay.nim
│       │   └── lock.nim
│       └── stable/
│           ├── backend.nim
│           ├── ic_backend.nim
│           ├── region.nim
│           ├── superblock.nim
│           ├── stable_blob.nim
│           └── checksum.nim
├── tests/
│   ├── test_superblock.nim
│   ├── test_overlay.nim
│   ├── test_stable_blob.nim
│   ├── test_sqlite_vfs.nim
│   └── test_upgrade/
└── examples/
    └── minimal_kv/
```

---

## 39. module dependency

```text
db.nim
  |
  +--> connection.nim
  |       |
  |       +--> sqlite_api.nim
  |
  +--> stable_blob.nim
          |
          +--> overlay.nim
          |
          +--> superblock.nim
          |
          +--> backend.nim
                  |
                  +--> ic_backend.nim

C SQLite
  |
  +--> C VFS shim
          |
          +--> vfs_exports.nim
                  |
                  +--> vfs.nim
```

---

## 40. C shim API案

### C -> Nim

```c
extern int nim_icvfs_open(
    const char *name,
    int flags,
    uint32_t *handle_id,
    int *out_flags
);

extern int nim_icvfs_close(
    uint32_t handle_id
);

extern int nim_icvfs_read(
    uint32_t handle_id,
    void *dst,
    int amount,
    sqlite3_int64 offset
);

extern int nim_icvfs_write(
    uint32_t handle_id,
    const void *src,
    int amount,
    sqlite3_int64 offset
);

extern int nim_icvfs_truncate(
    uint32_t handle_id,
    sqlite3_int64 size
);

extern int nim_icvfs_file_size(
    uint32_t handle_id,
    sqlite3_int64 *size
);
```

lock/control系も同様に追加する。

---

## 41. Nim file handle registry

Nim側でC file structへNim objectを直接埋め込まない。

```nim
var nextHandleId: uint32 = 1

var files:
  Table[uint32, FileState]
```

```nim
type FileState = object
  kind: FileKind
  readOnly: bool
  lockLevel: LockLevel
  temp: TempFile
```

`xOpen`:

```text
allocate handle id
insert FileState
return handle id
```

`xClose`:

```text
remove handle id
```

WASM pointerそのものをkeyにする方法もあるが、明示handle IDの方がdebugしやすい。

---

## 42. deterministic behavior

replica間determinismを壊さないため、次を避ける。

- OS random
- local clock
- thread scheduling依存
- address randomization依存
- nondeterministic hash iteration順でstable write順を決める

dirty page commit順はpage numberでsortする。

```nim
let pageNos = overlay.dirtyPages.keys.toSeq.sorted()
```

SQLite DBの最終bytesが同じならwrite順自体は本来結果に影響しないが、canister instruction behaviorも再現しやすくなる。

---

## 43. checksum

DB全体checksumを毎transaction再計算すると高コストになる。

推奨:

```text
update commit
  -> lastTxId++
  -> checksumStale = true
```

controller/admin operationでchunk単位に再計算する。

例:

```nim
proc refreshChecksumChunk(
  maxBytes: uint64
): ChecksumProgress
```

これにより巨大DBでも1messageで全scanしない。

MVPではDB checksum自体を省略し、metadata checksumだけ実装してもよい。

---

## 44. Integrity check

maintenance APIとして

```sql
PRAGMA integrity_check;
```

を実行可能にする。

ただしpublic unrestricted endpointにはしない。

controller限定またはadmin authorizationを入れる。

---

## 45. 複数DB

初期版:

```text
1 canister
1 SQLite DB
```

でよい。

将来:

```nim
type DbContextId = uint32

type DbHandle = object
  contextId: DbContextId
  region: StableRegion
```

として複数DBを管理する。

各DBは別stable regionを持つ。

filename namespaceで複数DBを切り替える方式より、1 DbHandle = 1 SQLite imageの方が設計しやすい。

---

## 46. ATTACH DATABASE

MVPでは禁止する。

理由:

- filename namespaceが複雑化
- atomic multi-database transactionが必要
- region管理が複雑化

必要になった段階で別途設計する。

---

## 47. page cache

最初は簡単な小容量cacheでよい。

例:

```text
clean page cache: 8 pages
read page offset cache: 64 entries
```

ただし固定値としてAPI contractにしない。

performance tuning値として扱う。

---

## 48. native test

native testではstable backendを `seq[byte]` で模擬する。

確認項目:

```text
superblock encode/decode
checksum failure
foreign image detection
read beyond EOF
partial write
full page write
truncate
grow after truncate
zero extent normalization
overlay rollback
overlay commit
```

---

## 49. SQLite VFS test

native SQLiteと接続し以下を実行する。

```sql
CREATE TABLE
INSERT
UPDATE
DELETE
SELECT
BEGIN/ROLLBACK
BEGIN/COMMIT
SAVEPOINT
VACUUM
PRAGMA integrity_check
```

特に:

```text
ROLLBACK後stable DB bytesが不変
```

であることを確認する。

---

## 50. failpoint test

stable commitにfailpointを入れる。

```text
FailBeforeCapacity
FailBeforeFirstPage
FailAfterNthPage
FailBeforeSuperblock
FailDuringSuperblock
```

期待結果:

```text
stable write開始前
    -> recoverable error

stable write開始後
    -> trap
    -> message rollback
```

IC local replica/PocketIC系integration testで、trap後に旧DBが読めることを確認する。

---

## 51. upgrade test

integration test:

```text
1. deploy version A
2. create table
3. insert rows
4. upgrade to version B
5. init VFS again
6. query rows
7. migration apply
8. PRAGMA integrity_check
```

成功条件:

```text
data preserved
schema migration successful
superblock valid
```

---

## 52. fuzz test

可能であれば次をfuzzする。

```text
xRead(offset, len)
xWrite(offset, bytes)
xTruncate(size)
overlay read/write order
zero extents
superblock decoder
```

特にoffset overflow:

```text
offset + len
pageNo * pageSize
baseOffset + logicalOffset
```

はすべてchecked arithmeticにする。

---

## 53. API例

```nim
import nicp_cdk
import nim_ic_sqlite_vfs
import std/results

var db: IcSqliteDb

const migrations = [
  Migration(
    version: 1,
    sql: """
      CREATE TABLE kv (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      );
    """
  )
]

proc initializeDatabase() =
  db = initIcSqliteDb(
    DbConfig(
      stableOwnership: soExclusive,
      pageSize: 16384
    )
  ).get()

  db.migrate(migrations).get()
```

update endpointの概念:

```nim
proc put(key, value: string): Result[void, string] =
  let res = db.withUpdate(proc(conn: var UpdateConnection):
      Result[void, DbError] =

    conn.exec(
      """
      INSERT INTO kv(key, value)
      VALUES (?1, ?2)
      ON CONFLICT(key)
      DO UPDATE SET value = excluded.value
      """,
      @[sql(key), sql(value)]
    )
  )

  if res.isErr:
    return err(res.error.message)

  ok()
```

query:

```nim
proc get(key: string): Result[Option[string], string] =
  let res = db.withQuery(proc(conn: var Connection):
      Result[Option[string], DbError] =

    conn.queryOptionalText(
      "SELECT value FROM kv WHERE key = ?1",
      @[sql(key)]
    )
  )

  if res.isErr:
    return err(res.error.message)

  ok(res.get())
```

---

## 54. 実装フェーズ

### Phase 0: build PoC

目的:

```text
Nim canister
+
SQLite C core
```

をlinkできることを確認する。

実装:

- `sqlite3.c` static archive
- `sqlite_api.nim`
- `sqlite3_open(":memory:")`
- CREATE / INSERT / SELECT

この段階ではcustom VFS不要。

成功条件:

```text
Nim -> SQLite C APIがWASM canister内で動作
```

### Phase 1: C VFS shim

実装:

- `sqlite3_os_init`
- `sqlite3_vfs`
- `sqlite3_io_methods`
- C -> Nim callbacks
- heap-only main DB

stable memoryはまだ使わない。

成功条件:

```text
独自VFSでSQLite DBが動く
```

### Phase 2: stable main DB

実装:

- `IcStableBackend`
- superblock
- `/main.db`
- xRead
- xWrite
- xFileSize
- xTruncate

まずsingle DB / exclusive stable memoryとする。

成功条件:

```text
canister upgrade後にDBが残る
```

### Phase 3: transaction overlay

実装:

- page overlay
- dirty pages
- zero extents
- rollback
- stable publish
- trap semantics

このPhase完了前の実装はproductionでwriteを許可しない。

成功条件:

```text
failed transactionでstable DBが変化しない
```

### Phase 4: DB facade

実装:

- typed bind
- typed column read
- prepared statements
- savepoints
- migrations
- integrity check

成功条件:

```text
applicationがraw SQLite pointerを触らず利用可能
```

### Phase 5: hardening

実装:

- checksum
- chunk checksum refresh
- failpoints
- fuzz
- instruction benchmark
- input bounds

### Phase 6: multi-region / multi-DB

必要になった場合のみ実装。

- region allocator
- MemoryManager
- multiple DbHandle

---

## 55. 最初に実装すべき最小subset

実装順は次がよい。

```text
1. SQLite C build
2. sqlite_api.nim
3. C VFS shim
4. heap temp file
5. stable backend
6. superblock
7. stable logical DB read
8. stable logical DB write
9. overlay
10. transaction facade
11. migration
12. upgrade test
```

いきなりRust版の全機能を移植しない。

特に次は後回しでよい。

```text
multi DB
import/export
checksum refresh
MemoryManager compatibility
bench profiler
FTS5最適化
```

---

## 56. production投入の最低条件

次を満たすまではproduction writeを有効にしない。

- custom VFSで基本CRUD成功
- rollback test成功
- trap rollback test成功
- upgrade persistence test成功
- truncate/grow test成功
- foreign stable memory検出
- metadata checksum検証
- `PRAGMA integrity_check` 成功
- WALを確実に無効化
- transaction中await禁止をAPI/documentationで明確化
- VFS callbackからNim exceptionを外へ漏らさない
- stable address overflowをchecked arithmeticで処理
- public SQL endpointを公開しない

---

## 57. リスク

### 57.1 Nim GC / ARC / ORCとC callback

`nicp_cdk` はORCを使用している。

CへNim-managed pointerを長期保持させない。

C file handleには整数handle IDだけを保存し、Nim objectはNim側registryで所有する。

### 57.2 C callback中のexception

exception unwindingをCへ跨がせない。

すべてSQLite error codeへ変換する。

### 57.3 stable memory衝突

SQLiteと既存 `IcStable*` が同じoffsetを使うと即座に破損する。

最初はexclusive ownershipを推奨する。

### 57.4巨大transaction

overlayがheapを大量消費する。

application-level transactionを小さくし、dirty byte上限を設ける。

### 57.5 SQLite planner cost

SQLが正しくてもIC instruction limitを超える場合がある。

index、LIMIT、paginationを必須設計にする。

### 57.6 SQLite upgrade

SQLite version更新時は:

- compile flags
- file format互換
- VFS ABI
- integrity test

を再確認する。

---

## 58. 代替案

### 代替案A: WASI filesystem + wasi2ic

```text
SQLite
 -> WASI fd
 -> wasi2ic
 -> filesystem abstraction
 -> stable memory
```

利点:

- SQLiteを通常のWASI applicationに近い形で使える
- custom VFS実装量が少ない

欠点:

- layerが増える
- direct VFSよりoverheadが大きい
- transaction semanticsの理解が間接的になる

既存WASI SQLiteをほぼそのまま動かしたい場合には有効。

本プロジェクトの目的にはdirect VFSを推奨する。

### 代替案B: VFS本体もCで実装

```text
Nim -> SQLite C -> C VFS -> ic0 C API
```

最もABIは単純になる。

一方でNim版ライブラリという目的から離れ、stable DB logicの大半がCになる。

### 代替案C: Rust VFSをstatic libraryとしてlink

既存 `ic-sqlite-vfs` をRust static library化しNimから呼ぶ。

実装コストは小さくなる可能性があるが、

- Rust toolchain依存
- Rust ABI bridge
- Nim-native implementationではない

ため、本設計では採用しない。

---

## 59. 推奨方針まとめ

最も現実的なNim版構成は次である。

```text
SQLite core
    C

sqlite3_vfs ABI
    small C shim

DB facade / VFS state / overlay / stable storage
    Nim

IC stable API
    nicp_cdk
```

特に重要な設計原則は以下の4点である。

### 原則1

SQLiteのVFSをstable memoryへ直接接続する。

### 原則2

update中のxWriteはstable memoryへ直接書かない。

### 原則3

SQLite COMMIT後にdirty pageを書き、superblockを最後にpublishする。

### 原則4

stable publish途中のfailureはtrapしてmessage rollbackさせる。

この4点を守れば、Rust版 `ic-sqlite-vfs` と同じ基本的なdurability modelをNim上で実現できる。

---

## 60. 参考ソース

### ic-sqlite-vfs

Repository:

<https://github.com/humandebri/ic-sqlite-vfs>

主要参照ファイル:

```text
README.md
src/sqlite_vfs/vfs.rs
src/sqlite_vfs/file.rs
src/sqlite_vfs/overlay.rs
src/sqlite_vfs/stable_blob.rs
src/sqlite_vfs/register.rs
src/stable/meta.rs
src/db/mod.rs
src/db/transaction.rs
src/db/pragmas.rs
vendor/sqlite/build-flags.txt
docs/BUILD_SETUP.md
```

### nicp_cdk

Repository:

<https://github.com/dumblepy/nicp_cdk>

主要参照ファイル:

```text
README.md
src/nicp_cdk/ic0/ic0.nim
src/nicp_cdk/storage/libs/stable_memory.nim
src/nicp_cdk/storage/stable_value.nim
src/cli/nicp_functions/new_impl.nim
```

### SQLite

VFS documentation:

<https://sqlite.org/vfs.html>

C API:

<https://sqlite.org/c3ref/intro.html>

---

## 61. 次に着手するコード

最初に作るべきファイルは以下である。

```text
vendor/sqlite/sqlite3.c
vendor/sqlite/sqlite3.h

scripts/build_sqlite.sh

c/ic_sqlite_vfs_shim.c
c/ic_sqlite_vfs_shim.h

src/nim_ic_sqlite_vfs/ffi/sqlite_api.nim
src/nim_ic_sqlite_vfs/ffi/vfs_exports.nim

src/nim_ic_sqlite_vfs/vfs/temp_file.nim
src/nim_ic_sqlite_vfs/vfs/vfs.nim

src/nim_ic_sqlite_vfs/stable/backend.nim
src/nim_ic_sqlite_vfs/stable/ic_backend.nim
src/nim_ic_sqlite_vfs/stable/superblock.nim
src/nim_ic_sqlite_vfs/stable/stable_blob.nim
src/nim_ic_sqlite_vfs/vfs/overlay.nim

src/nim_ic_sqlite_vfs/db.nim
```

最初の技術検証は、

```text
Nim canister
 -> SQLite
 -> custom heap VFS
 -> CREATE/INSERT/SELECT
```

までとし、その後stable memoryへ接続する。

この順序なら、SQLite linking問題、VFS ABI問題、stable memory問題、transaction atomicity問題を分離してデバッグできる。
