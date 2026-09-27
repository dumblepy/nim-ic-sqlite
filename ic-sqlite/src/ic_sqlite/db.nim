## High-level database entry point. SQLite C pointers remain private here.
import std/options
import ./ffi/sqlite_api
import ./ffi/vfs_exports
import ./stable/[backend, superblock]
import ./vfs/vfs
import ./vfs/overlay
import ./value

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
  Connection* = object
    db: ptr Db
    raw: ptr Sqlite3
  Statement* = object
    raw: ptr Sqlite3Stmt
    db: ptr Db
    errorSource: ptr Sqlite3
  StepResult* = enum
    srRow, srDone
  Migration* = object
    version*: uint64
    sql*: string
  IcSqliteDb* = Db

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

proc sqliteError(raw: ptr Sqlite3; code: cint): DbError =
  DbError(code: code, message: if raw.isNil: "SQLite open failed" else: $sqlite3_errmsg(raw))

proc dbError(db: Db; code: cint): DbError = sqliteError(db.raw, code)

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

proc withQuery*[T](db: var Db;
                   body: proc(conn: var Connection): Result[T, DbError] {.closure.}
                  ): Result[T, DbError] =
  ## Stable DB queries use a distinct read-only SQLite connection. Native
  ## `:memory:` tests cannot share a second connection, so only that test-only
  ## backend reuses its handle.
  if db.raw.isNil:
    return Result[T, DbError](isOk: false,
      error: DbError(code: -1, message: "database is not initialized"))
  if db.backend.isNil:
    let queryOnlyCode = sqlite3_exec(db.raw, "PRAGMA query_only=ON".cstring, nil, nil, nil)
    if queryOnlyCode != sqlite_api.SqliteOk:
      return Result[T, DbError](isOk: false, error: db.dbError(queryOnlyCode))
    defer: discard sqlite3_exec(db.raw, "PRAGMA query_only=OFF".cstring, nil, nil, nil)
    var memoryConnection = Connection(db: addr db, raw: db.raw)
    return body(memoryConnection)
  var queryRaw: ptr Sqlite3
  let openCode = sqlite3_open_v2("/main.db", addr queryRaw,
    SqliteOpenReadOnly or SqliteOpenNoMutex, "icstable")
  if openCode != sqlite_api.SqliteOk:
    let error = sqliteError(queryRaw, openCode)
    if not queryRaw.isNil: discard sqlite3_close(queryRaw)
    return Result[T, DbError](isOk: false, error: error)
  defer: discard sqlite3_close(queryRaw)
  let pragmaCode = sqlite3_exec(queryRaw,
    "PRAGMA cache_size=-32768; PRAGMA query_only=ON; PRAGMA locking_mode=EXCLUSIVE; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY;",
    nil, nil, nil)
  if pragmaCode != sqlite_api.SqliteOk:
    return Result[T, DbError](isOk: false, error: sqliteError(queryRaw, pragmaCode))
  var connection = Connection(db: addr db, raw: queryRaw)
  body(connection)

proc prepare*(conn: var Connection; sql: string): Result[Statement, DbError] =
  if conn.db.isNil or conn.raw.isNil:
    return Result[Statement, DbError](isOk: false,
      error: DbError(code: -1, message: "database is not initialized"))
  if sql.len == 0 or uint64(sql.len) > conn.db[].config.maxSqlBytes:
    return Result[Statement, DbError](isOk: false,
      error: DbError(code: -1, message: "SQL exceeds configured limit"))
  var raw: ptr Sqlite3Stmt
  let code = sqlite3_prepare_v2(conn.raw, sql.cstring, sql.len.cint, addr raw, nil)
  if code != sqlite_api.SqliteOk:
    return Result[Statement, DbError](isOk: false, error: sqliteError(conn.raw, code))
  Result[Statement, DbError](isOk: true,
    value: Statement(raw: raw, db: conn.db, errorSource: conn.raw))

proc finalize*(statement: var Statement) =
  if not statement.raw.isNil:
    discard sqlite3_finalize(statement.raw)
    statement.raw = nil

proc `bind`*(statement: var Statement; index: int; value: SqlValue): Result[bool, DbError] =
  if statement.raw.isNil or statement.db.isNil:
    return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "statement is finalized"))
  if index <= 0:
    return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "bind index must be positive"))
  var code: cint
  case value.kind
  of svNull: code = sqlite3_bind_null(statement.raw, index.cint)
  of svInt: code = sqlite3_bind_int64(statement.raw, index.cint, value.intValue)
  of svFloat: code = sqlite3_bind_double(statement.raw, index.cint, value.floatValue.cdouble)
  of svText:
    if uint64(value.textValue.len) > statement.db[].config.maxBlobBytes:
      return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "bound value exceeds maxBlobBytes"))
    code = ic_sqlite_bind_text(statement.raw, index.cint, value.textValue.cstring, value.textValue.len.cint)
  of svBlob:
    if uint64(value.blobValue.len) > statement.db[].config.maxBlobBytes:
      return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "bound value exceeds maxBlobBytes"))
    let data = if value.blobValue.len == 0: nil else: unsafeAddr value.blobValue[0]
    code = ic_sqlite_bind_blob(statement.raw, index.cint, data, value.blobValue.len.cint)
  if code != sqlite_api.SqliteOk:
    return Result[bool, DbError](isOk: false, error: sqliteError(statement.errorSource, code))
  Result[bool, DbError](isOk: true, value: true)

proc step*(statement: var Statement): Result[StepResult, DbError] =
  if statement.raw.isNil or statement.db.isNil:
    return Result[StepResult, DbError](isOk: false, error: DbError(code: -1, message: "statement is finalized"))
  let code = sqlite3_step(statement.raw)
  if code == sqlite_api.SqliteRow:
    return Result[StepResult, DbError](isOk: true, value: srRow)
  if code == sqlite_api.SqliteDone:
    return Result[StepResult, DbError](isOk: true, value: srDone)
  Result[StepResult, DbError](isOk: false, error: sqliteError(statement.errorSource, code))

proc columnIsNull*(statement: Statement; index: int): bool =
  not statement.raw.isNil and sqlite3_column_type(statement.raw, index.cint) == 5

proc columnInt64*(statement: Statement; index: int): int64 =
  sqlite3_column_int64(statement.raw, index.cint)

proc columnFloat64*(statement: Statement; index: int): float64 =
  float64(sqlite3_column_double(statement.raw, index.cint))

proc columnText*(statement: Statement; index: int): string =
  let text = sqlite3_column_text(statement.raw, index.cint)
  if text.isNil: "" else: $text

proc columnBlob*(statement: Statement; index: int): seq[byte] =
  let length = sqlite3_column_bytes(statement.raw, index.cint)
  let source = sqlite3_column_blob(statement.raw, index.cint)
  if length <= 0 or source.isNil: return @[]
  result = newSeq[byte](int(length))
  copyMem(addr result[0], source, int(length))

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
  let queryValues = @values
  db.withQuery(proc(conn: var Connection): Result[Option[string], DbError] =
    let prepared = conn.prepare(sql)
    if not prepared.isOk:
      return Result[Option[string], DbError](isOk: false, error: prepared.error)
    var statement = prepared.value
    defer: statement.finalize()
    for index, item in queryValues:
      let bound = statement.bind(index + 1, sqlText(item))
      if not bound.isOk:
        return Result[Option[string], DbError](isOk: false, error: bound.error)
    let stepped = statement.step()
    if not stepped.isOk:
      return Result[Option[string], DbError](isOk: false, error: stepped.error)
    if stepped.value == srDone:
      return Result[Option[string], DbError](isOk: true, value: none(string))
    if statement.columnIsNull(0):
      return Result[Option[string], DbError](isOk: true, value: none(string))
    Result[Option[string], DbError](isOk: true, value: some(statement.columnText(0)))
  )

proc migrate*(db: var Db; migrations: openArray[Migration]): Result[bool, DbError] =
  ## Applies trusted, static migrations once in strictly increasing version
  ## order.  Application input must never be interpolated into `Migration.sql`.
  var previous = 0'u64
  for migration in migrations:
    if migration.version == 0 or migration.version <= previous:
      return Result[bool, DbError](isOk: false,
        error: DbError(code: -1, message: "migration versions must be strictly increasing and non-zero"))
    if migration.sql.len == 0 or uint64(migration.sql.len) > db.config.maxSqlBytes:
      return Result[bool, DbError](isOk: false,
        error: DbError(code: -1, message: "migration SQL exceeds configured limit"))
    previous = migration.version
  let table = db.exec("CREATE TABLE IF NOT EXISTS __nim_ic_sqlite_migrations (version INTEGER PRIMARY KEY NOT NULL)")
  if not table.isOk:
    return Result[bool, DbError](isOk: false, error: table.error)
  for migration in migrations:
    let migrationVersion = migration.version
    let migrationSql = migration.sql
    let applied = db.queryOneText(
      "SELECT CAST(version AS TEXT) FROM __nim_ic_sqlite_migrations WHERE version = ?",
      [$migrationVersion])
    if not applied.isOk:
      return Result[bool, DbError](isOk: false, error: applied.error)
    if applied.value.isSome:
      continue
    let transactionResult = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let executed = conn.exec(migrationSql)
      if not executed.isOk:
        return Result[bool, DbError](isOk: false, error: executed.error)
      let recorded = conn.execText(
        "INSERT INTO __nim_ic_sqlite_migrations(version) VALUES (?)", [$migrationVersion])
      if not recorded.isOk:
        return Result[bool, DbError](isOk: false, error: recorded.error)
      Result[bool, DbError](isOk: true, value: true)
    )
    if not transactionResult.isOk:
      return transactionResult
  Result[bool, DbError](isOk: true, value: true)
