## High-level database entry point. SQLite C pointers remain private here.
import std/options
import ./ffi/[sqlite_api, vfs_exports]
import ./stable/[backend, superblock]
import ./vfs/vfs
import ./vfs/overlay

when defined(wasm32):
  proc ic0Trap(src, length: uint32) {.importc: "ic0_trap", cdecl, header: "ic0.h".}

proc trapPublishFailure(message: string) {.noreturn.} =
  when defined(wasm32):
    ic0Trap(cast[uint32](message.cstring), uint32(message.len))
  raise newException(CatchableError, "sqlite stable publish failed: " & message)

type
  DbError* = object
    code*: cint
    message*: string
  DbConfig* = object
    maxDirtyPages*: uint64
    maxDirtyBytes*: uint64
    maxSqlBytes*: uint64
    maxBlobBytes*: uint64
  Db* = object
    raw: ptr Sqlite3
    backend: StableBackend
    sqlitePageSize: uint32
    lastTxId: uint64
    config: DbConfig
  UpdateConnection* = object
    db: ptr Db

const Wasi2icReservedStablePages = 1025'u64

proc defaultDbConfig*(): DbConfig =
  DbConfig(maxDirtyPages: 4096, maxDirtyBytes: 64'u64 * 1024 * 1024,
    maxSqlBytes: 1024'u64 * 1024, maxBlobBytes: 16'u64 * 1024 * 1024)

proc configIsValid(config: DbConfig): bool =
  config.maxDirtyPages > 0 and config.maxDirtyBytes >= 16384 and
    config.maxSqlBytes > 0 and config.maxBlobBytes > 0

proc sqliteStableBackend(backend: StableBackend): StableBackend =
  ## wasi2ic reserves stable memory under the MGR+version header. Preserve that
  ## region and give SQLite a logical page-aligned region after it.
  if backend.sizePages == 0: return backend
  var magic: array[4, byte]
  try:
    backend.read(0, addr magic[0], uint64(magic.len))
    if magic[0 .. 2] == [byte('M'), byte('G'), byte('R')]:
      return newOffsetStableBackend(backend, Wasi2icReservedStablePages * StablePageSize)
  except CatchableError:
    discard
  backend

proc dbError(db: Db; code: cint): DbError =
  DbError(code: code, message: if db.raw.isNil: "SQLite open failed" else: $sqlite3_errmsg(db.raw))

proc persistMetadata(db: Db): Result[bool, DbError] =
  ## This is deliberately written after DB pages have been published.  A
  ## restart can therefore never advertise a DB image larger than the pages
  ## that were already made durable.
  try:
    if db.backend.sizePages == 0 and not db.backend.grow(1):
      return Result[bool, DbError](isOk: false,
        error: DbError(code: -1, message: "unable to allocate stable superblock page"))
    let metadata = Superblock(
      formatVersion: SuperblockFormatVersion,
      sqlitePageSize: db.sqlitePageSize,
      dbSize: databaseSize,
      lastTxId: db.lastTxId)
    let encoded = encodeSuperblock(metadata)
    db.backend.write(0, unsafeAddr encoded[0], uint64(encoded.len))
    Result[bool, DbError](isOk: true, value: true)
  except CatchableError as error:
    Result[bool, DbError](isOk: false, error: DbError(code: -1, message: error.msg))

proc init*(db: var Db; backend: StableBackend; dbSize = 0'u64;
           config = defaultDbConfig()): Result[bool, DbError] =
  ## Opens /main.db through the `icstable` VFS. The caller selects an
  ## IcStableBackend in canisters or VecStableBackend in native tests.
  if backend.isNil: return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "nil stable backend"))
  if not config.configIsValid:
    return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "invalid database resource limits"))
  let sqliteBackend = sqliteStableBackend(backend)
  let existing = readExistingSuperblock(sqliteBackend)
  if not existing.isOk:
    return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: existing.error))
  let restoredSize = if existing.value.isSome: existing.value.get.dbSize else: 0'u64
  let restoredTxId = if existing.value.isSome: existing.value.get.lastTxId else: 0'u64
  let restoredPageSize = if existing.value.isSome: existing.value.get.sqlitePageSize else: 16384'u32
  if restoredPageSize != 16384'u32:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "unsupported SQLite page size in stable superblock"))
  db.config = config
  initVfs(sqliteBackend, if dbSize != 0: dbSize else: restoredSize,
    maxDirtyPages = config.maxDirtyPages, maxDirtyBytes = config.maxDirtyBytes)
  beginOverlay()
  let flags = SqliteOpenReadWrite or SqliteOpenCreate or SqliteOpenNoMutex
  let code = sqlite3_open_v2("/main.db", addr db.raw, flags, "icstable")
  if code != sqlite_api.SqliteOk:
    endOverlay()
    return Result[bool, DbError](isOk: false, error: db.dbError(code))
  let pragmas = if existing.value.isSome:
      "PRAGMA journal_mode=MEMORY; PRAGMA synchronous=OFF; PRAGMA temp_store=MEMORY; PRAGMA locking_mode=EXCLUSIVE; PRAGMA foreign_keys=ON; PRAGMA cache_size=-32768;"
    else:
      "PRAGMA page_size=16384; PRAGMA journal_mode=MEMORY; PRAGMA synchronous=OFF; PRAGMA temp_store=MEMORY; PRAGMA locking_mode=EXCLUSIVE; PRAGMA foreign_keys=ON; PRAGMA cache_size=-32768;"
  let pragmaCode = sqlite3_exec(db.raw, pragmas.cstring, nil, nil, nil)
  if pragmaCode != sqlite_api.SqliteOk:
    endOverlay()
    discard sqlite3_close(db.raw)
    db.raw = nil
    return Result[bool, DbError](isOk: false, error: db.dbError(pragmaCode))
  endOverlay(publish = true)
  db.backend = sqliteBackend
  db.sqlitePageSize = restoredPageSize
  db.lastTxId = restoredTxId
  let metadata = db.persistMetadata()
  if not metadata.isOk:
    discard sqlite3_close(db.raw)
    db.raw = nil
    return Result[bool, DbError](isOk: false, error: metadata.error)
  Result[bool, DbError](isOk: true, value: true)

when not defined(wasm32):
  proc initMemoryForTest*(db: var Db; config = defaultDbConfig()): Result[bool, DbError] =
    ## Native-only integration-test backend. Production canisters must use init.
    if not config.configIsValid:
      return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "invalid database resource limits"))
    let flags = SqliteOpenReadWrite or SqliteOpenCreate or SqliteOpenNoMutex
    let code = sqlite3_open_v2(":memory:", addr db.raw, flags, nil)
    if code != sqlite_api.SqliteOk: return Result[bool, DbError](isOk: false, error: db.dbError(code))
    db.config = config
    Result[bool, DbError](isOk: true, value: true)

proc close*(db: var Db) =
  if not db.raw.isNil:
    discard sqlite3_close(db.raw)
    db.raw = nil

proc beginStableOperation(db: Db): Result[bool, DbError] =
  ## A canister message must not expose writes before the SQLite operation has
  ## succeeded.  Native :memory: tests have no VFS overlay.
  if db.backend.isNil: return Result[bool, DbError](isOk: true, value: false)
  if overlayActive:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "a stable database operation is already active"))
  try:
    beginOverlay()
    Result[bool, DbError](isOk: true, value: true)
  except CatchableError as error:
    Result[bool, DbError](isOk: false, error: DbError(code: -1, message: error.msg))

proc finishStableOperation(db: var Db; started: bool; publish: bool): Result[bool, DbError] =
  if not started: return Result[bool, DbError](isOk: true, value: true)
  try:
    endOverlay(publish)
  except PublishStartedError as error:
    trapPublishFailure(error.msg)
  except CatchableError as error:
    return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: error.msg))
  if publish:
    inc db.lastTxId
    let metadata = db.persistMetadata()
    if not metadata.isOk: trapPublishFailure(metadata.error.message)
  Result[bool, DbError](isOk: true, value: true)

proc execRaw(db: var Db; sql: string): Result[int, DbError] =
  let code = sqlite3_exec(db.raw, sql.cstring, nil, nil, nil)
  if code != sqlite_api.SqliteOk:
    return Result[int, DbError](isOk: false, error: db.dbError(code))
  Result[int, DbError](isOk: true, value: int(sqlite3_changes(db.raw)))

proc execTextRaw(db: var Db; sql: string; values: openArray[string]): Result[int, DbError] =
  for value in values:
    if uint64(value.len) > db.config.maxBlobBytes:
      return Result[int, DbError](isOk: false, error: DbError(code: -1, message: "bound value exceeds maxBlobBytes"))
  var statement: ptr Sqlite3Stmt
  var code = sqlite3_prepare_v2(db.raw, sql.cstring, sql.len.cint, addr statement, nil)
  if code == sqlite_api.SqliteOk:
    for index, value in values:
      code = ic_sqlite_bind_text(statement, cint(index + 1), value.cstring, value.len.cint)
      if code != sqlite_api.SqliteOk: break
  if code == sqlite_api.SqliteOk: code = sqlite3_step(statement)
  if not statement.isNil: discard sqlite3_finalize(statement)
  if code != sqlite_api.SqliteDone:
    return Result[int, DbError](isOk: false, error: db.dbError(code))
  Result[int, DbError](isOk: true, value: int(sqlite3_changes(db.raw)))

proc exec*(db: var Db; sql: string): Result[int, DbError] =
  ## Executes a SQL statement inside the canister. For SELECT statements,
  ## SQLite evaluates the query and this returns the SQLite changes count (0).
  if db.raw.isNil: return Result[int, DbError](isOk: false, error: DbError(code: -1, message: "database is not initialized"))
  if sql.len == 0: return Result[int, DbError](isOk: false, error: DbError(code: -1, message: "SQL must not be empty"))
  if uint64(sql.len) > db.config.maxSqlBytes: return Result[int, DbError](isOk: false, error: DbError(code: -1, message: "SQL exceeds maxSqlBytes"))
  let begun = db.beginStableOperation()
  if not begun.isOk: return Result[int, DbError](isOk: false, error: begun.error)
  let executed = db.execRaw(sql)
  if not executed.isOk:
    discard db.finishStableOperation(begun.value, false)
    return executed
  let finished = db.finishStableOperation(begun.value, true)
  if not finished.isOk: return Result[int, DbError](isOk: false, error: finished.error)
  executed

proc execText*(db: var Db; sql: string; values: openArray[string]): Result[int, DbError] =
  ## Executes one statement with TEXT values bound by SQLite.  This is the
  ## safe building block for canister APIs that accept caller-provided text.
  if db.raw.isNil: return Result[int, DbError](isOk: false, error: DbError(code: -1, message: "database is not initialized"))
  if sql.len == 0: return Result[int, DbError](isOk: false, error: DbError(code: -1, message: "SQL must not be empty"))
  if uint64(sql.len) > db.config.maxSqlBytes: return Result[int, DbError](isOk: false, error: DbError(code: -1, message: "SQL exceeds maxSqlBytes"))
  let begun = db.beginStableOperation()
  if not begun.isOk: return Result[int, DbError](isOk: false, error: begun.error)
  let executed = db.execTextRaw(sql, values)
  if not executed.isOk:
    discard db.finishStableOperation(begun.value, false)
    return executed
  let finished = db.finishStableOperation(begun.value, true)
  if not finished.isOk: return Result[int, DbError](isOk: false, error: finished.error)
  executed

proc exec*(conn: var UpdateConnection; sql: string): Result[int, DbError] =
  if conn.db.isNil:
    return Result[int, DbError](isOk: false, error: DbError(code: -1, message: "nil update connection"))
  conn.db[].execRaw(sql)

proc execText*(conn: var UpdateConnection; sql: string; values: openArray[string]): Result[int, DbError] =
  if conn.db.isNil:
    return Result[int, DbError](isOk: false, error: DbError(code: -1, message: "nil update connection"))
  conn.db[].execTextRaw(sql, values)

proc withUpdate*[T](db: var Db;
                    body: proc(conn: var UpdateConnection): Result[T, DbError] {.closure.}
                   ): Result[T, DbError] =
  ## The closure is synchronous by type. Do not make inter-canister calls from
  ## it: one invocation is one SQLite transaction and one IC update message.
  if db.raw.isNil:
    return Result[T, DbError](isOk: false, error: DbError(code: -1, message: "database is not initialized"))
  let begun = db.beginStableOperation()
  if not begun.isOk: return Result[T, DbError](isOk: false, error: begun.error)
  let beginResult = db.execRaw("BEGIN IMMEDIATE")
  if not beginResult.isOk:
    discard db.finishStableOperation(begun.value, false)
    return Result[T, DbError](isOk: false, error: beginResult.error)
  var connection = UpdateConnection(db: addr db)
  let bodyResult = body(connection)
  if not bodyResult.isOk:
    discard db.execRaw("ROLLBACK")
    discard db.finishStableOperation(begun.value, false)
    return bodyResult
  let committed = db.execRaw("COMMIT")
  if not committed.isOk:
    discard db.execRaw("ROLLBACK")
    discard db.finishStableOperation(begun.value, false)
    return Result[T, DbError](isOk: false, error: committed.error)
  let finished = db.finishStableOperation(begun.value, true)
  if not finished.isOk: return Result[T, DbError](isOk: false, error: finished.error)
  bodyResult

proc queryOneText*(db: var Db; sql: string; values: openArray[string]): Result[Option[string], DbError] =
  ## Returns the first column of the first row.  Query paths never begin an
  ## overlay, so a query cannot publish stable-memory changes.
  if db.raw.isNil: return Result[Option[string], DbError](isOk: false, error: DbError(code: -1, message: "database is not initialized"))
  if sql.len == 0: return Result[Option[string], DbError](isOk: false, error: DbError(code: -1, message: "SQL must not be empty"))
  if uint64(sql.len) > db.config.maxSqlBytes:
    return Result[Option[string], DbError](isOk: false, error: DbError(code: -1, message: "SQL exceeds maxSqlBytes"))
  for item in values:
    if uint64(item.len) > db.config.maxBlobBytes:
      return Result[Option[string], DbError](isOk: false, error: DbError(code: -1, message: "bound value exceeds maxBlobBytes"))
  var statement: ptr Sqlite3Stmt
  var code = sqlite3_prepare_v2(db.raw, sql.cstring, sql.len.cint, addr statement, nil)
  if code == sqlite_api.SqliteOk:
    for index, value in values:
      code = ic_sqlite_bind_text(statement, cint(index + 1), value.cstring, value.len.cint)
      if code != sqlite_api.SqliteOk: break
  if code == sqlite_api.SqliteOk: code = sqlite3_step(statement)
  var value: Option[string]
  if code == sqlite_api.SqliteRow:
    let text = sqlite3_column_text(statement, 0)
    if not text.isNil: value = some($text)
  if not statement.isNil: discard sqlite3_finalize(statement)
  if code != sqlite_api.SqliteRow and code != sqlite_api.SqliteDone:
    return Result[Option[string], DbError](isOk: false, error: db.dbError(code))
  Result[Option[string], DbError](isOk: true, value: value)
