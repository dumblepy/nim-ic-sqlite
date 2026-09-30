## High-level database entry point. SQLite C pointers remain private here.
import std/[options, tables]
import ./ffi/sqlite_api
import ./ffi/vfs_exports
import ./stable/[backend, superblock]
import ./stable/memory_manager
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
  TransactionLease* = ref object
    active: bool
    db: ptr Db
  StatementCacheStats* = object
    hits*: uint64
    misses*: uint64
  DbStorageStats* = object
    ## `sqliteVirtualPages` is the page count of the backend passed to SQLite.
    ## It is deliberately distinct from canister-wide raw stable pages.
    dbSize*: uint64
    sqliteVirtualPages*: uint64
  DbCacheStats* = object
    ## SQLite pager-cache bytes, distinct from VFS/stable-memory counters.
    cacheUsedBytes*: uint64
  DbErrorKind* = enum
    dekSqlite, dekInvalidQuery, dekBind, dekColumnMissing, dekTypeMismatch,
    dekNullViolation, dekOverflow, dekResourceLimit, dekInvalidState,
    ## The selected storage contradicts the requested open intent, e.g. a
    ## `doiCreateOnly` open of a slot that already holds a SQLite image.
    dekStorageMode,
    ## A `doiOpenExisting` open found no SQLite image.  This is the wrong /
    ## empty `MemoryId` case detected during `post_upgrade`.
    dekMissingDatabase
  DbError* = object
    code*: cint
    message*: string
    kind*: DbErrorKind
    column*: string
    expectedType*: string
    actualType*: string
    rowIndex*: int
  DbOpenIntent* = enum
    ## Fail if the selected region already holds a SQLite image.
    doiCreateOnly
    ## Fail if the selected region does not hold a SQLite image. Recommended
    ## for `post_upgrade`, so a wrong or empty `MemoryId` never becomes a new DB.
    doiOpenExisting
    ## Explicit compatibility behaviour: open an existing image, otherwise
    ## create a fresh one.  Existing low-level `Db.init(backend)` callers use it.
    doiOpenOrCreate
  DbStorageMode* = enum
    ## `manager.getMemory(id)`: SQLite lives inside one virtual `MemoryId`.
    dsmManaged
    ## SQLite owns the whole raw region (superblock at physical offset 0).
    dsmExclusive
    ## Explicit legacy view after a wasi2ic `MGR` fixed prefix.
    dsmLegacyFixedOffset
  DbStorage* = object
    ## Resolved storage target plus the mode it was selected with.  The fields
    ## stay private: callers select a mode through the constructors and cannot
    ## re-interpret raw bytes.
    backend: StableBackend
    mode: DbStorageMode
  DbConfig* = object
    maxDirtyPages*: uint64
    maxDirtyBytes*: uint64
    maxSqlBytes*: uint64
    maxBlobBytes*: uint64
    maxResultRows*: uint64
    maxResultBytes*: uint64
    maxQueryParams*: uint64
    statementCacheEnabled*: bool
    maxCachedStatements*: uint64
    ## Optional clean base-page cache inside the update overlay. Kept disabled
    ## (0) by default; non-zero values are only used by benchmark experiments.
    cleanCachePages*: uint64
    ## Optional read-only query connection reuse. Kept disabled by default;
    ## the cached connection is invalidated before every update transaction.
    queryConnectionReuse*: bool
    ## Statement cache bound to the reused read connection. Only effective
    ## while `queryConnectionReuse` is enabled; invalidated together with
    ## the connection so no dangling statement can survive an update.
    queryStatementCacheEnabled*: bool
  Db* = object
    raw: ptr Sqlite3
    backend: StableBackend
    sqlitePageSize: uint32
    lastTxId: uint64
    config: DbConfig
    currentUpdate: TransactionLease
    statementCache: Table[string, ptr Sqlite3Stmt]
    statementCacheStats: StatementCacheStats
    ## Experimental read-connection reuse (disabled by default).  The handle
    ## is invalidated before every update and on close so stale page or
    ## query state can never survive a published transaction.
    cachedQueryRaw: ptr Sqlite3
    ## Statement cache bound to the reused read connection (only effective
    ## while queryConnectionReuse is enabled); cleared with the connection.
    queryStatementCache: Table[string, ptr Sqlite3Stmt]
    queryStatementCacheStats: StatementCacheStats
  UpdateConnection* = object
    db: ptr Db
    lease: TransactionLease
  Connection* = object
    db: ptr Db
    raw: ptr Sqlite3
  Statement* = object
    raw: ptr Sqlite3Stmt
    db: ptr Db
    errorSource: ptr Sqlite3
    cached: bool
    cacheKey: string
    ## Set for cached update statements so a handle leaked past `withUpdate`
    ## cannot be executed after its transaction lease ends.
    lease: TransactionLease
    cachedInDb: bool
  StepResult* = enum
    srRow, srDone
  Migration* = object
    version*: uint64
    sql*: string
  IcSqliteDb* = Db

proc defaultDbConfig*(): DbConfig =
  ## `cleanCachePages` stays 0 by default: the optional clean page cache is an
  ## experiment and must not change resident memory without explicit opt-in.
  DbConfig(maxDirtyPages: 4096, maxDirtyBytes: 64'u64 * 1024 * 1024,
    maxSqlBytes: 1024'u64 * 1024, maxBlobBytes: 16'u64 * 1024 * 1024,
    maxResultRows: 1000, maxResultBytes: 8'u64 * 1024 * 1024,
    maxQueryParams: 999, statementCacheEnabled: false,
    maxCachedStatements: 32, cleanCachePages: 0, queryConnectionReuse: false,
    queryStatementCacheEnabled: false)

proc configIsValid(config: DbConfig): bool =
  config.maxDirtyPages > 0 and config.maxDirtyBytes >= 16384 and
    config.maxSqlBytes > 0 and config.maxBlobBytes > 0 and
    config.maxResultRows > 0 and config.maxResultBytes > 0 and
    config.maxQueryParams > 0 and
    (not config.statementCacheEnabled or config.maxCachedStatements > 0)

proc managedDbStorage*(manager: MemoryManager; id: MemoryId): DbStorage =
  ## Selects one virtual `MemoryId` of an application-owned `MemoryManager` as
  ## SQLite storage.  This only calls `manager.getMemory(id)`; it never inspects
  ## or re-interprets the raw bytes at the manager base.
  if manager.isNil:
    raise newException(ValueError, "nil memory manager")
  DbStorage(mode: dsmManaged, backend: manager.getMemory(id))

proc exclusiveDbStorage*(raw: StableBackend): DbStorage =
  ## SQLite owns the whole raw region.  The caller must guarantee no other
  ## allocator (wasi2ic, IcStableSeq, ...) uses the same raw stable memory.
  if raw.isNil:
    raise newException(ValueError, "nil stable backend")
  DbStorage(mode: dsmExclusive, backend: raw)

proc legacyWasi2icDbStorage*(raw: StableBackend): DbStorage =
  ## **Explicit legacy opt-in.**  Reopens a SQLite image that a previous release
  ## placed after the wasi2ic `MGR` fixed prefix (1025 pages).  Not for new
  ## configurations; prefer `managedDbStorage` with a single owner allocator.
  if raw.isNil:
    raise newException(ValueError, "nil stable backend")
  DbStorage(mode: dsmLegacyFixedOffset, backend: legacyWasi2icOffsetBackend(raw))

proc storageMode*(storage: DbStorage): DbStorageMode {.inline.} = storage.mode

proc queryLimits*(db: Db): tuple[maxRows, maxBytes, maxParams: uint64] =
  (db.config.maxResultRows, db.config.maxResultBytes, db.config.maxQueryParams)

proc statementCacheStats*(db: Db): StatementCacheStats = db.statementCacheStats

proc dbError(db: Db; code: cint): DbError

proc storageStats*(db: Db): DbStorageStats =
  ## Read-only storage metadata for benchmark and operational observation.
  ## Canister-wide raw stable memory must be sampled separately via ic0.
  result.dbSize = databaseSize
  if not db.backend.isNil:
    result.sqliteVirtualPages = db.backend.sizePages()

proc cacheStats*(db: Db): Result[DbCacheStats, DbError] =
  ## `SQLITE_DEFAULT_MEMSTATUS=0` does not disable per-connection db status.
  ## Keep this opt-in observation separate from regular database operations.
  if db.raw.isNil:
    return Result[DbCacheStats, DbError](isOk: false,
      error: DbError(code: -1, message: "database is not open"))
  var current, highwater: cint
  let code = sqlite3_db_status(db.raw, SqliteDbStatusCacheUsed,
    addr current, addr highwater, 0)
  if code != sqlite_api.SqliteOk:
    return Result[DbCacheStats, DbError](isOk: false, error: db.dbError(code))
  if current < 0:
    return Result[DbCacheStats, DbError](isOk: false,
      error: DbError(code: -1, message: "SQLite returned a negative cache size"))
  Result[DbCacheStats, DbError](isOk: true,
    value: DbCacheStats(cacheUsedBytes: uint64(current)))

when defined(benchmarkProfile):
  type DbProfileStats* = object
    dirtyPagesCurrent*, dirtyPagesPeak*: uint64
    dirtyPageNew*, dirtyPageNewBytes*: uint64
    cleanCacheHits*, cleanCacheMisses*, cleanCacheEvictions*, cleanCacheReadBytes*: uint64
    tempBufferAllocs*, tempBufferAllocBytes*: uint64
    vfsReadCalls*, vfsWriteCalls*, vfsShortReads*, vfsTruncateCalls*: uint64

  proc profileStats*(db: Db): Result[DbProfileStats, DbError] =
    ## Benchmark-only counters separated from normal operations by
    ## `-d:benchmarkProfile`. VFS/overlay counters reset per `initVfs`
    ## window; stable I/O call/byte counts come from the canister-level
    ## counting backend, SQLite pager bytes from `cacheStats()`.
    if db.raw.isNil:
      return Result[DbProfileStats, DbError](isOk: false,
        error: DbError(code: -1, message: "database is not open"))
    let vfs = benchmarkVfsProfile()
    let overlay = benchmarkOverlayProfile()
    Result[DbProfileStats, DbError](isOk: true, value: DbProfileStats(
      dirtyPagesCurrent: uint64(dirtyPageCount(activeOverlay)),
      dirtyPagesPeak: overlay.dirtyPagePeak,
      dirtyPageNew: overlay.dirtyPageNew,
      dirtyPageNewBytes: overlay.dirtyPageNewBytes,
      cleanCacheHits: overlay.cleanCacheHits,
      cleanCacheMisses: overlay.cleanCacheMisses,
      cleanCacheEvictions: overlay.cleanCacheEvictions,
      cleanCacheReadBytes: overlay.cleanCacheReadBytes,
      tempBufferAllocs: vfs.tempBufferAllocs,
      tempBufferAllocBytes: vfs.tempBufferAllocBytes,
      vfsReadCalls: vfs.readCalls, vfsWriteCalls: vfs.writeCalls,
      vfsShortReads: vfs.shortReads, vfsTruncateCalls: vfs.truncateCalls))

proc clearStatementCache(db: var Db) =
  for _, statement in db.statementCache:
    if not statement.isNil:
      discard sqlite3_finalize(statement)
  db.statementCache.clear()
  db.statementCacheStats = StatementCacheStats()

proc resetCachedUpdateStatements(db: var Db) =
  ## Called at the end of every update transaction. Cached update statements
  ## stay resident on the persistent write connection but are reset and their
  ## bindings cleared, so no statement state can leak into the next transaction.
  if not db.config.statementCacheEnabled: return
  for _, raw in db.statementCache:
    if not raw.isNil:
      discard sqlite3_reset(raw)
      discard sqlite3_clear_bindings(raw)

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
      lastTxId: db.lastTxId,
      zeroExtents: currentZeroExtents())
    let encoded = encodeSuperblock(metadata)
    db.backend.write(0, unsafeAddr encoded[0], uint64(encoded.len))
    Result[bool, DbError](isOk: true, value: true)
  except CatchableError as error:
    Result[bool, DbError](isOk: false, error: DbError(code: -1, message: error.msg))

proc init*(db: var Db; backend: StableBackend; dbSize = 0'u64;
           config = defaultDbConfig();
           intent = doiOpenOrCreate): Result[bool, DbError] =
  ## Opens /main.db through the `icstable` VFS. The caller selects an
  ## IcStableBackend in canisters or VecStableBackend in native tests.
  ##
  ## The backend's logical offset 0 is the SQLite superblock: this proc never
  ## inspects an `MGR` magic to move the backend. A previous release applied an
  ## implicit 1025-page offset here; use `legacyWasi2icDbStorage` explicitly if
  ## that legacy physical layout must be reopened.
  if backend.isNil: return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "nil stable backend"))
  if not config.configIsValid:
    return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "invalid database resource limits"))
  when not defined(wasm32):
    if ic_sqlite_register_vfs() != sqlite_api.SqliteOk:
      return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "unable to register icstable VFS"))
  let sqliteBackend = backend
  let existing = readExistingSuperblock(sqliteBackend)
  if not existing.isOk:
    return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: existing.error))
  ## Resolve the open intent before any metadata, schema or DB page write. A
  ## rejected open must leave the target region byte-for-byte unchanged.
  let hasExistingImage = existing.value.isSome
  case intent
  of doiCreateOnly:
    if hasExistingImage:
      return Result[bool, DbError](isOk: false,
        error: DbError(code: -1, kind: dekStorageMode,
          message: "stable storage already contains a SQLite image"))
  of doiOpenExisting:
    if not hasExistingImage:
      return Result[bool, DbError](isOk: false,
        error: DbError(code: -1, kind: dekMissingDatabase,
          message: "no SQLite image to open in the selected storage"))
  of doiOpenOrCreate:
    discard
  let restoredSize = if existing.value.isSome: existing.value.get.dbSize else: 0'u64
  let restoredTxId = if existing.value.isSome: existing.value.get.lastTxId else: 0'u64
  let restoredPageSize = if existing.value.isSome: existing.value.get.sqlitePageSize else: 16384'u32
  let restoredZeroExtents = if existing.value.isSome: existing.value.get.zeroExtents else: @[]
  if restoredPageSize != 16384'u32:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "unsupported SQLite page size in stable superblock"))
  db.config = config
  initVfs(sqliteBackend, if dbSize != 0: dbSize else: restoredSize,
    maxDirtyPages = config.maxDirtyPages, maxDirtyBytes = config.maxDirtyBytes,
    zeroExtents = restoredZeroExtents, pageSize = restoredPageSize,
    cleanCachePages = config.cleanCachePages)
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

proc init*(db: var Db; storage: DbStorage; dbSize = 0'u64;
           config = defaultDbConfig();
           intent = doiOpenOrCreate): Result[bool, DbError] =
  ## Storage-mode entry point. The constructor has already resolved the
  ## backend (managed `MemoryId`, exclusive raw region, or explicit legacy
  ## offset), so the DB layer never guesses a layout from raw bytes.
  db.init(storage.backend, dbSize = dbSize, config = config, intent = intent)

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

proc clearQueryStatementCache(db: var Db) =
  for _, statement in db.queryStatementCache:
    if not statement.isNil:
      discard sqlite3_finalize(statement)
  db.queryStatementCache.clear()
  db.queryStatementCacheStats = StatementCacheStats()

proc close*(db: var Db) =
  db.clearStatementCache()
  db.clearQueryStatementCache()
  if not db.cachedQueryRaw.isNil:
    discard sqlite3_close(db.cachedQueryRaw)
    db.cachedQueryRaw = nil
  if not db.raw.isNil:
    discard sqlite3_close(db.raw)
    db.raw = nil

proc invalidateQueryConnection(db: var Db) =
  ## Every update (published or rolled back) invalidates the cached reader so
  ## it can never keep serving stale page or query state.  The query
  ## statement cache lives on that connection and is torn down with it.
  if not db.cachedQueryRaw.isNil:
    db.clearQueryStatementCache()
    discard sqlite3_close(db.cachedQueryRaw)
    db.cachedQueryRaw = nil

proc beginStableOperation(db: var Db): Result[bool, DbError] =
  ## A canister message must not expose writes before the SQLite operation has
  ## succeeded.  Native :memory: tests have no VFS overlay.
  if db.backend.isNil: return Result[bool, DbError](isOk: true, value: false)
  if db.config.queryConnectionReuse:
    db.invalidateQueryConnection()
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
  ## The `values` argument stays alive for the whole call, so the TEXT
  ## parameters are bound with SQLITE_STATIC (zero copy) and finalized before
  ## this proc returns: no borrowed pointer can outlive the caller's buffers.
  for value in values:
    if uint64(value.len) > db.config.maxBlobBytes:
      return Result[int, DbError](isOk: false, error: DbError(code: -1, message: "bound value exceeds maxBlobBytes"))
  var statement: ptr Sqlite3Stmt
  var code = sqlite3_prepare_v2(db.raw, sql.cstring, sql.len.cint, addr statement, nil)
  if code == sqlite_api.SqliteOk:
    for index in 0 ..< values.len:
      let textLen = values[index].len
      let data = if textLen == 0: cstring("")
                 else: cast[cstring](unsafeAddr values[index][0])
      code = ic_sqlite_bind_text_static(statement, cint(index + 1), data, textLen.cint)
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

proc `bind`*(statement: var Statement; index: int; value: SqlValue): Result[bool, DbError]
proc finalize*(statement: var Statement)
proc executeBorrowed*(statement: var Statement;
                      values: openArray[SqlValue]): Result[bool, DbError]
proc invalidateCachedStatement(statement: var Statement)

proc execValues*(db: var Db; sql: string; values: openArray[SqlValue]): Result[int, DbError] =
  ## Typed prepared execution using the same overlay/publish path as execText.
  if db.raw.isNil: return Result[int, DbError](isOk: false, error: DbError(code: -1, message: "database is not initialized", kind: dekInvalidState))
  let begun = db.beginStableOperation()
  if not begun.isOk: return Result[int, DbError](isOk: false, error: begun.error)
  var raw: ptr Sqlite3Stmt
  var code = sqlite3_prepare_v2(db.raw, sql.cstring, sql.len.cint, addr raw, nil)
  if code == sqlite_api.SqliteOk and int(sqlite3_bind_parameter_count(raw)) != values.len:
    code = -1
  if code == sqlite_api.SqliteOk:
    var statement = Statement(raw: raw, db: addr db, errorSource: db.raw)
    let executed = statement.executeBorrowed(values)
    statement.finalize()
    if not executed.isOk:
      discard db.finishStableOperation(begun.value, false)
      return Result[int, DbError](isOk: false, error: executed.error)
  elif not raw.isNil:
    discard sqlite3_finalize(raw)
  if code != sqlite_api.SqliteOk:
    discard db.finishStableOperation(begun.value, false)
    return Result[int, DbError](isOk: false, error: db.dbError(code))
  let finished = db.finishStableOperation(begun.value, true)
  if not finished.isOk: return Result[int, DbError](isOk: false, error: finished.error)
  Result[int, DbError](isOk: true, value: int(sqlite3_changes(db.raw)))

proc lastInsertId*(db: Db): Result[int64, DbError] =
  if db.raw.isNil:
    return Result[int64, DbError](isOk: false,
      error: DbError(code: -1, message: "database is not initialized", kind: dekInvalidState))
  Result[int64, DbError](isOk: true, value: sqlite3_last_insert_rowid(db.raw))

proc exec*(conn: var UpdateConnection; sql: string): Result[int, DbError] =
  if conn.db.isNil:
    return Result[int, DbError](isOk: false, error: DbError(code: -1, message: "nil update connection"))
  conn.db[].execRaw(sql)

proc execText*(conn: var UpdateConnection; sql: string; values: openArray[string]): Result[int, DbError] =
  if conn.db.isNil:
    return Result[int, DbError](isOk: false, error: DbError(code: -1, message: "nil update connection"))
  conn.db[].execTextRaw(sql, values)

proc execValues*(conn: var UpdateConnection; sql: string; values: openArray[SqlValue]): Result[int, DbError] =
  ## Executes inside the active withUpdate transaction; it never starts an overlay.
  if conn.db.isNil: return Result[int, DbError](isOk: false, error: DbError(code: -1, message: "nil update connection", kind: dekInvalidState))
  var raw: ptr Sqlite3Stmt
  var code = sqlite3_prepare_v2(conn.db[].raw, sql.cstring, sql.len.cint, addr raw, nil)
  if code == sqlite_api.SqliteOk and int(sqlite3_bind_parameter_count(raw)) != values.len: code = -1
  if code == sqlite_api.SqliteOk:
    var statement = Statement(raw: raw, db: conn.db, errorSource: conn.db[].raw)
    let executed = statement.executeBorrowed(values)
    statement.finalize()
    if not executed.isOk:
      return Result[int, DbError](isOk: false, error: executed.error)
  elif not raw.isNil:
    discard sqlite3_finalize(raw)
  if code != sqlite_api.SqliteOk:
    return Result[int, DbError](isOk: false, error: conn.db[].dbError(code))
  Result[int, DbError](isOk: true, value: int(sqlite3_changes(conn.db[].raw)))

proc lastInsertId*(conn: UpdateConnection): Result[int64, DbError] =
  if conn.db.isNil:
    return Result[int64, DbError](isOk: false,
      error: DbError(code: -1, message: "nil update connection", kind: dekInvalidState))
  Result[int64, DbError](isOk: true, value: sqlite3_last_insert_rowid(conn.db[].raw))

proc ownerDb*(conn: var UpdateConnection): ptr Db = conn.db

proc changes*(conn: UpdateConnection): int =
  if conn.db.isNil or conn.db[].raw.isNil: 0
  else: int(sqlite3_changes(conn.db[].raw))

proc transactionLease*(conn: UpdateConnection): TransactionLease = conn.lease

proc withUpdateQueryRead*[T](lease: TransactionLease;
    body: proc(conn: var Connection): Result[T, DbError] {.closure.}
  ): Result[T, DbError] =
  if lease.isNil or not lease.active or lease.db.isNil or lease.db[].currentUpdate != lease or lease.db[].raw.isNil:
    return Result[T, DbError](isOk: false,
      error: DbError(code: -1, message: "update query context is no longer active", kind: dekInvalidState))
  var borrowed = Connection(db: lease.db, raw: lease.db[].raw)
  body(borrowed)

proc execValuesInTransaction*(lease: TransactionLease; sql: string;
                               values: openArray[SqlValue]): Result[int, DbError] =
  if lease.isNil or not lease.active or lease.db.isNil or lease.db[].currentUpdate != lease:
    return Result[int, DbError](isOk: false, error: DbError(code: -1, message: "update query context is no longer active", kind: dekInvalidState))
  var connection = UpdateConnection(db: lease.db, lease: lease)
  connection.execValues(sql, values)

proc lastInsertIdInTransaction*(lease: TransactionLease): Result[int64, DbError] =
  if lease.isNil or not lease.active or lease.db.isNil or lease.db[].currentUpdate != lease:
    return Result[int64, DbError](isOk: false, error: DbError(code: -1, message: "update query context is no longer active", kind: dekInvalidState))
  lease.db[].lastInsertId()



proc withQuery*[T](db: var Db;
                   body: proc(conn: var Connection): Result[T, DbError] {.closure.}
                  ): Result[T, DbError] =
  ## Stable DB queries use a distinct read-only SQLite connection. Native
  ## `:memory:` tests cannot share a second connection, so only that test-only
  ## backend reuses its handle.
  if db.raw.isNil:
    return Result[T, DbError](isOk: false,
      error: DbError(code: -1, message: "database is not initialized"))
  if not db.currentUpdate.isNil and db.currentUpdate.active:
    return Result[T, DbError](isOk: false,
      error: DbError(code: -1, message: "ordinary query is forbidden during withUpdate", kind: dekInvalidState))
  if db.backend.isNil:
    let queryOnlyCode = sqlite3_exec(db.raw, "PRAGMA query_only=ON".cstring, nil, nil, nil)
    if queryOnlyCode != sqlite_api.SqliteOk:
      return Result[T, DbError](isOk: false, error: db.dbError(queryOnlyCode))
    defer: discard sqlite3_exec(db.raw, "PRAGMA query_only=OFF".cstring, nil, nil, nil)
    var memoryConnection = Connection(db: addr db, raw: db.raw)
    return body(memoryConnection)
  ## Optional read-connection reuse.  The cached handle is dropped on every
  ## update transaction (published or rolled back) so an update can never
  ## leave a reader holding stale page state.
  var queryRaw = if db.config.queryConnectionReuse: db.cachedQueryRaw else: nil
  if queryRaw.isNil:
    let openCode = sqlite3_open_v2("/main.db", addr queryRaw,
      SqliteOpenReadOnly or SqliteOpenNoMutex, "icstable")
    if openCode != sqlite_api.SqliteOk:
      let error = sqliteError(queryRaw, openCode)
      if not queryRaw.isNil: discard sqlite3_close(queryRaw)
      return Result[T, DbError](isOk: false, error: error)
    let pragmaCode = sqlite3_exec(queryRaw,
      "PRAGMA cache_size=-32768; PRAGMA query_only=ON; PRAGMA locking_mode=EXCLUSIVE; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY;",
      nil, nil, nil)
    if pragmaCode != sqlite_api.SqliteOk:
      discard sqlite3_close(queryRaw)
      return Result[T, DbError](isOk: false, error: sqliteError(queryRaw, pragmaCode))
    if db.config.queryConnectionReuse:
      db.cachedQueryRaw = queryRaw
  var connection = Connection(db: addr db, raw: queryRaw)
  let queryResult = body(connection)
  if not db.config.queryConnectionReuse:
    discard sqlite3_close(queryRaw)
  queryResult

proc prepare*(conn: var Connection; sql: string): Result[Statement, DbError] =
  if conn.db.isNil or conn.raw.isNil:
    return Result[Statement, DbError](isOk: false,
      error: DbError(code: -1, message: "database is not initialized"))
  if sql.len == 0 or uint64(sql.len) > conn.db[].config.maxSqlBytes:
    return Result[Statement, DbError](isOk: false,
      error: DbError(code: -1, message: "SQL exceeds configured limit"))
  ## The statement cache can live on the update connection or on the reused
  ## read connection.  In both cases the cache is invalidated together with
  ## its owning connection, so a cached statement can never outlive it;
  ## `finalize` only resets and clears bindings for cached entries.
  let ownedByDb = conn.raw != nil and conn.raw == conn.db[].raw
  let ownedByQuery = conn.db[].config.queryConnectionReuse and
    not ownedByDb and not conn.db[].cachedQueryRaw.isNil and
    conn.raw == conn.db[].cachedQueryRaw
  let inDbCache = ownedByDb and conn.db[].config.statementCacheEnabled
  let inQueryCache = ownedByQuery and conn.db[].config.queryStatementCacheEnabled
  let cacheable = inDbCache or inQueryCache
  if cacheable:
    let cache: ptr Table[string, ptr Sqlite3Stmt] =
      if inDbCache: addr conn.db[].statementCache
      else: addr conn.db[].queryStatementCache
    let stats: ptr StatementCacheStats =
      if inDbCache: addr conn.db[].statementCacheStats
      else: addr conn.db[].queryStatementCacheStats
    if cache[].hasKey(sql):
      let raw = cache[][sql]
      discard sqlite3_reset(raw)
      discard sqlite3_clear_bindings(raw)
      inc stats[].hits
      return Result[Statement, DbError](isOk: true,
        value: Statement(raw: raw, db: conn.db, errorSource: conn.raw,
          cached: true, cacheKey: sql, cachedInDb: inDbCache))
  var raw: ptr Sqlite3Stmt
  let code = sqlite3_prepare_v2(conn.raw, sql.cstring, sql.len.cint, addr raw, nil)
  if code != sqlite_api.SqliteOk:
    return Result[Statement, DbError](isOk: false, error: sqliteError(conn.raw, code))
  if cacheable:
    let cache: ptr Table[string, ptr Sqlite3Stmt] =
      if inDbCache: addr conn.db[].statementCache
      else: addr conn.db[].queryStatementCache
    let stats: ptr StatementCacheStats =
      if inDbCache: addr conn.db[].statementCacheStats
      else: addr conn.db[].queryStatementCacheStats
    if uint64(cache[].len) < conn.db[].config.maxCachedStatements:
      cache[][sql] = raw
      inc stats[].misses
      return Result[Statement, DbError](isOk: true,
        value: Statement(raw: raw, db: conn.db, errorSource: conn.raw,
          cached: true, cacheKey: sql, cachedInDb: inDbCache))
  Result[Statement, DbError](isOk: true,
    value: Statement(raw: raw, db: conn.db, errorSource: conn.raw))

proc prepare*(conn: var UpdateConnection; sql: string): Result[Statement, DbError] =
  ## A prepared statement used inside the current update transaction.
  ##
  ## When `config.statementCacheEnabled` is set, the statement is cached on the
  ## persistent write connection (`db.statementCache`) so repeated update
  ## messages with the same SQL skip re-preparation. Cached handles carry the
  ## transaction lease and are rejected by `step`/`bind` once the lease ends, so
  ## a handle leaked past `withUpdate` cannot run outside its transaction. The
  ## cache is reset (not finalized) at the end of every transaction and an entry
  ## is evicted if SQLite reports an error for it.
  if conn.db.isNil or conn.db[].raw.isNil or conn.lease.isNil or not conn.lease.active:
    return Result[Statement, DbError](isOk: false,
      error: DbError(code: -1, message: "update connection is not active", kind: dekInvalidState))
  if sql.len == 0 or uint64(sql.len) > conn.db[].config.maxSqlBytes:
    return Result[Statement, DbError](isOk: false,
      error: DbError(code: -1, message: "SQL exceeds configured limit", kind: dekInvalidState))
  let cacheable = conn.db[].config.statementCacheEnabled
  if cacheable:
    let cache = addr conn.db[].statementCache
    if cache[].hasKey(sql):
      let raw = cache[][sql]
      discard sqlite3_reset(raw)
      discard sqlite3_clear_bindings(raw)
      inc conn.db[].statementCacheStats.hits
      return Result[Statement, DbError](isOk: true,
        value: Statement(raw: raw, db: conn.db, errorSource: conn.db[].raw,
          cached: true, cacheKey: sql, lease: conn.lease, cachedInDb: true))
  var raw: ptr Sqlite3Stmt
  let code = sqlite3_prepare_v2(conn.db[].raw, sql.cstring, sql.len.cint, addr raw, nil)
  if code != sqlite_api.SqliteOk:
    if not raw.isNil: discard sqlite3_finalize(raw)
    return Result[Statement, DbError](isOk: false, error: sqliteError(conn.db[].raw, code))
  if cacheable and uint64(conn.db[].statementCache.len) < conn.db[].config.maxCachedStatements:
    conn.db[].statementCache[sql] = raw
    inc conn.db[].statementCacheStats.misses
    return Result[Statement, DbError](isOk: true,
      value: Statement(raw: raw, db: conn.db, errorSource: conn.db[].raw,
        cached: true, cacheKey: sql, lease: conn.lease, cachedInDb: true))
  Result[Statement, DbError](isOk: true,
    value: Statement(raw: raw, db: conn.db, errorSource: conn.db[].raw))

proc finalize*(statement: var Statement) =
  if not statement.raw.isNil:
    if statement.cached:
      discard sqlite3_reset(statement.raw)
      discard sqlite3_clear_bindings(statement.raw)
    else:
      discard sqlite3_finalize(statement.raw)
    statement.raw = nil

proc reset*(statement: var Statement): Result[bool, DbError] =
  if statement.raw.isNil:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "statement is finalized", kind: dekInvalidState))
  let code = sqlite3_reset(statement.raw)
  if code != sqlite_api.SqliteOk:
    return Result[bool, DbError](isOk: false, error: sqliteError(statement.errorSource, code))
  discard sqlite3_clear_bindings(statement.raw)
  Result[bool, DbError](isOk: true, value: true)

proc parameterCount*(statement: Statement): int =
  if statement.raw.isNil: 0 else: int(sqlite3_bind_parameter_count(statement.raw))

proc queryLimits*(statement: Statement): tuple[maxRows, maxBytes, maxParams: uint64] =
  if statement.db.isNil: (0'u64, 0'u64, 0'u64) else: statement.db[].queryLimits()

proc isReadonly*(statement: Statement): bool =
  not statement.raw.isNil and sqlite3_stmt_readonly(statement.raw) != 0

## A non-NULL pointer used to bind a zero-length BLOB. SQLite binds a NULL
## value when the blob pointer is NULL, so an empty `seq[byte]` must be bound
## with a valid pointer and length 0 to stay a zero-length BLOB.
var emptyBlobByte: byte

proc `bind`*(statement: var Statement; index: int; value: SqlValue): Result[bool, DbError] =
  if statement.raw.isNil or statement.db.isNil:
    return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "statement is finalized"))
  if statement.cachedInDb and not statement.lease.isNil and not statement.lease.active:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "update statement lease is no longer active",
        kind: dekInvalidState))
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
    let data = if value.blobValue.len == 0: cast[pointer](addr emptyBlobByte)
               else: unsafeAddr value.blobValue[0]
    code = ic_sqlite_bind_blob(statement.raw, index.cint, data, value.blobValue.len.cint)
  if code != sqlite_api.SqliteOk:
    return Result[bool, DbError](isOk: false, error: sqliteError(statement.errorSource, code))
  Result[bool, DbError](isOk: true, value: true)

## Internal-only borrowed (SQLITE_STATIC) binding helpers. These are NOT part
## of the public API: the caller MUST guarantee that the pointer remains valid
## until the next reset/clear_bindings/finalize, and MUST call reset (which
## clears bindings) on every path — success, error, and early return.
##
## These are used exclusively in benchmark/internal paths where the data
## lifetime is bounded by the statement's step/reset cycle and the caller
## controls the full execution flow.

proc bindStaticText*(statement: var Statement; index: int; data: cstring; length: int): Result[bool, DbError] =
  ## Binds a TEXT value with SQLITE_STATIC (zero-copy, caller retains lifetime).
  if statement.raw.isNil or statement.db.isNil:
    return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "statement is finalized"))
  if index <= 0:
    return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "bind index must be positive"))
  if uint64(length) > statement.db[].config.maxBlobBytes:
    return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "bound value exceeds maxBlobBytes"))
  let code = ic_sqlite_bind_text_static(statement.raw, index.cint, data, length.cint)
  if code != sqlite_api.SqliteOk:
    return Result[bool, DbError](isOk: false, error: sqliteError(statement.errorSource, code))
  Result[bool, DbError](isOk: true, value: true)

proc bindStaticBlob*(statement: var Statement; index: int; data: pointer; length: int): Result[bool, DbError] =
  ## Binds a BLOB value with SQLITE_STATIC (zero-copy, caller retains lifetime).
  if statement.raw.isNil or statement.db.isNil:
    return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "statement is finalized"))
  if index <= 0:
    return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "bind index must be positive"))
  if uint64(length) > statement.db[].config.maxBlobBytes:
    return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "bound value exceeds maxBlobBytes"))
  let code = ic_sqlite_bind_blob_static(statement.raw, index.cint, data, length.cint)
  if code != sqlite_api.SqliteOk:
    return Result[bool, DbError](isOk: false, error: sqliteError(statement.errorSource, code))
  Result[bool, DbError](isOk: true, value: true)

proc executeTextTextBorrowed*(statement: var Statement;
                              first, second: openArray[char]): Result[bool, DbError] =
  ## Internal-only, allocation-free execution of a statement that binds exactly
  ## two TEXT parameters. Uses SQLITE_STATIC, so `first` and `second` MUST stay
  ## alive and unmodified until this call returns; no binding survives it.
  ##
  ## This is deliberately not a public binding API: it always clears bindings
  ## before returning, on success and on every error path, so callers can reuse
  ## or discard the source buffers immediately afterwards. The generic
  ## `bind(SqlValue)` path keeps its own copy via SQLITE_TRANSIENT and is
  ## unchanged.
  if statement.raw.isNil or statement.db.isNil:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "statement is finalized", kind: dekInvalidState))
  if statement.cachedInDb and not statement.lease.isNil and not statement.lease.active:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "update statement lease is no longer active",
        kind: dekInvalidState))
  if int(sqlite3_bind_parameter_count(statement.raw)) != 2:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "statement must have exactly two parameters",
        kind: dekInvalidState))
  if uint64(first.len) > statement.db[].config.maxBlobBytes or
      uint64(second.len) > statement.db[].config.maxBlobBytes:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "bound value exceeds maxBlobBytes",
        kind: dekResourceLimit))
  ## Discard any stale step error code: the next statement state is established
  ## by the bind below, so reset here is only for clearing prior execution.
  discard sqlite3_reset(statement.raw)
  let firstData =
    if first.len == 0: cstring("") else: cast[cstring](unsafeAddr first[0])
  let secondData =
    if second.len == 0: cstring("") else: cast[cstring](unsafeAddr second[0])
  let firstBound = ic_sqlite_bind_text_static(
    statement.raw, 1.cint, firstData, first.len.cint)
  if firstBound != sqlite_api.SqliteOk:
    discard sqlite3_clear_bindings(statement.raw)
    return Result[bool, DbError](isOk: false,
      error: sqliteError(statement.errorSource, firstBound))
  let secondBound = ic_sqlite_bind_text_static(
    statement.raw, 2.cint, secondData, second.len.cint)
  if secondBound != sqlite_api.SqliteOk:
    discard sqlite3_clear_bindings(statement.raw)
    return Result[bool, DbError](isOk: false,
      error: sqliteError(statement.errorSource, secondBound))
  let code = sqlite3_step(statement.raw)
  ## Clear borrowed bindings before inspecting the result so the source buffers
  ## never outlive this call, even when step failed.
  discard sqlite3_clear_bindings(statement.raw)
  if code != sqlite_api.SqliteDone:
    statement.invalidateCachedStatement()
    return Result[bool, DbError](isOk: false, error: sqliteError(statement.errorSource, code))
  Result[bool, DbError](isOk: true, value: true)

proc executeTextBorrowed*(statement: var Statement;
                           value: openArray[char]): Result[bool, DbError] =
  ## Internal-only, allocation-free execution of a statement that binds exactly
  ## one TEXT parameter. Same scoped contract as `executeTextTextBorrowed`:
  ## `value` must stay alive until this call returns and bindings are always
  ## cleared before returning, on success and on every error path.
  if statement.raw.isNil or statement.db.isNil:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "statement is finalized", kind: dekInvalidState))
  if statement.cachedInDb and not statement.lease.isNil and not statement.lease.active:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "update statement lease is no longer active",
        kind: dekInvalidState))
  if int(sqlite3_bind_parameter_count(statement.raw)) != 1:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "statement must have exactly one parameter",
        kind: dekInvalidState))
  if uint64(value.len) > statement.db[].config.maxBlobBytes:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "bound value exceeds maxBlobBytes",
        kind: dekResourceLimit))
  discard sqlite3_reset(statement.raw)
  let data = if value.len == 0: cstring("") else: cast[cstring](unsafeAddr value[0])
  let bound = ic_sqlite_bind_text_static(statement.raw, 1.cint, data, value.len.cint)
  if bound != sqlite_api.SqliteOk:
    discard sqlite3_clear_bindings(statement.raw)
    return Result[bool, DbError](isOk: false,
      error: sqliteError(statement.errorSource, bound))
  let code = sqlite3_step(statement.raw)
  discard sqlite3_clear_bindings(statement.raw)
  if code != sqlite_api.SqliteDone:
    statement.invalidateCachedStatement()
    return Result[bool, DbError](isOk: false, error: sqliteError(statement.errorSource, code))
  Result[bool, DbError](isOk: true, value: true)

proc bindStaticValue(statement: var Statement; values: openArray[SqlValue];
                     index: int): Result[bool, DbError] =
  ## STATIC bind of one element of `values` for a scoped execution. It indexes
  ## the caller's storage directly (no `SqlValue` copy), so the backing
  ## string/seq MUST stay alive until `executeBorrowed` clears the binding.
  if statement.raw.isNil or statement.db.isNil:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "statement is finalized", kind: dekInvalidState))
  let parameter = index + 1
  if parameter <= 0:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "bind index must be positive", kind: dekInvalidState))
  var code: cint
  case values[index].kind
  of svNull:
    code = sqlite3_bind_null(statement.raw, parameter.cint)
  of svInt:
    code = sqlite3_bind_int64(statement.raw, parameter.cint, values[index].intValue)
  of svFloat:
    code = sqlite3_bind_double(statement.raw, parameter.cint, values[index].floatValue.cdouble)
  of svText:
    if uint64(values[index].textValue.len) > statement.db[].config.maxBlobBytes:
      return Result[bool, DbError](isOk: false,
        error: DbError(code: -1, message: "bound value exceeds maxBlobBytes",
          kind: dekResourceLimit))
    let data = if values[index].textValue.len == 0: cstring("")
               else: cast[cstring](unsafeAddr values[index].textValue[0])
    code = ic_sqlite_bind_text_static(
      statement.raw, parameter.cint, data, values[index].textValue.len.cint)
  of svBlob:
    if uint64(values[index].blobValue.len) > statement.db[].config.maxBlobBytes:
      return Result[bool, DbError](isOk: false,
        error: DbError(code: -1, message: "bound value exceeds maxBlobBytes",
          kind: dekResourceLimit))
    let data = if values[index].blobValue.len == 0: cast[pointer](addr emptyBlobByte)
               else: cast[pointer](unsafeAddr values[index].blobValue[0])
    code = ic_sqlite_bind_blob_static(
      statement.raw, parameter.cint, data, values[index].blobValue.len.cint)
  if code != sqlite_api.SqliteOk:
    return Result[bool, DbError](isOk: false,
      error: sqliteError(statement.errorSource, code))
  Result[bool, DbError](isOk: true, value: true)

proc executeBorrowed*(statement: var Statement;
                      values: openArray[SqlValue]): Result[bool, DbError] =
  ## Scoped, general borrowed execution of a non-row statement.
  ##
  ## Binds every value with SQLITE_STATIC, so the backing buffers inside
  ## `values` MUST stay alive until this call returns. That is automatic for
  ## `values` passed as an argument; the bindings never outlive the call because
  ## they are cleared on success and on every error path. The statement must
  ## finish with SQLITE_DONE (INSERT / UPDATE / DELETE): a row result is reported
  ## as an error so a borrowed pointer can never escape into a caller read loop.
  ##
  ## This is the general scoped replacement for the A2 fast path; the public
  ## `bind(SqlValue)` API keeps its own SQLITE_TRANSIENT copy.
  if statement.raw.isNil or statement.db.isNil:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "statement is finalized", kind: dekInvalidState))
  if statement.cachedInDb and not statement.lease.isNil and not statement.lease.active:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "update statement lease is no longer active",
        kind: dekInvalidState))
  if int(sqlite3_bind_parameter_count(statement.raw)) != values.len:
    return Result[bool, DbError](isOk: false,
      error: DbError(code: -1, message: "parameter count does not match bound values",
        kind: dekInvalidState))
  for index in 0 ..< values.len:
    let size = case values[index].kind
      of svText: values[index].textValue.len
      of svBlob: values[index].blobValue.len
      else: 0
    if uint64(size) > statement.db[].config.maxBlobBytes:
      return Result[bool, DbError](isOk: false,
        error: DbError(code: -1, message: "bound value exceeds maxBlobBytes",
          kind: dekResourceLimit))
  discard sqlite3_reset(statement.raw)
  for index in 0 ..< values.len:
    let bound = statement.bindStaticValue(values, index)
    if not bound.isOk:
      discard sqlite3_clear_bindings(statement.raw)
      return bound
  let code = sqlite3_step(statement.raw)
  ## Clear before inspecting the result: no borrowed buffer may outlive the call.
  discard sqlite3_clear_bindings(statement.raw)
  if code != sqlite_api.SqliteDone:
    statement.invalidateCachedStatement()
    return Result[bool, DbError](isOk: false, error: sqliteError(statement.errorSource, code))
  Result[bool, DbError](isOk: true, value: true)

proc invalidateCachedStatement(statement: var Statement) =
  ## Evicts a cached update statement after SQLite reports an error for it so a
  ## failed or expired plan is never reused. The entry is removed from the cache
  ## but the raw handle is kept alive for the caller, which may reset and retry
  ## within the same transaction; `finalize` now really finalizes it.
  if not statement.cachedInDb or statement.cacheKey.len == 0: return
  if not statement.db.isNil:
    statement.db[].statementCache.del(statement.cacheKey)
  statement.cached = false
  statement.cachedInDb = false

proc step*(statement: var Statement): Result[StepResult, DbError] =
  if statement.raw.isNil or statement.db.isNil:
    return Result[StepResult, DbError](isOk: false, error: DbError(code: -1, message: "statement is finalized"))
  if statement.cachedInDb and not statement.lease.isNil and not statement.lease.active:
    return Result[StepResult, DbError](isOk: false,
      error: DbError(code: -1, message: "update statement lease is no longer active",
        kind: dekInvalidState))
  let code = sqlite3_step(statement.raw)
  if code == sqlite_api.SqliteRow:
    return Result[StepResult, DbError](isOk: true, value: srRow)
  if code == sqlite_api.SqliteDone:
    return Result[StepResult, DbError](isOk: true, value: srDone)
  statement.invalidateCachedStatement()
  Result[StepResult, DbError](isOk: false, error: sqliteError(statement.errorSource, code))

proc columnIsNull*(statement: Statement; index: int): bool =
  not statement.raw.isNil and sqlite3_column_type(statement.raw, index.cint) == SqliteNull

proc columnType*(statement: Statement; index: int): cint =
  if statement.raw.isNil: SqliteNull else: sqlite3_column_type(statement.raw, index.cint)

proc columnCount*(statement: Statement): int =
  if statement.raw.isNil: 0 else: int(sqlite3_column_count(statement.raw))

proc columnName*(statement: Statement; index: int): string =
  if statement.raw.isNil: return ""
  let name = sqlite3_column_name(statement.raw, index.cint)
  if name.isNil: "" else: $name

proc columnBytes*(statement: Statement; index: int): int =
  if statement.raw.isNil: 0 else: int(sqlite3_column_bytes(statement.raw, index.cint))

proc columnInt64*(statement: Statement; index: int): int64 =
  sqlite3_column_int64(statement.raw, index.cint)

proc columnFloat64*(statement: Statement; index: int): float64 =
  float64(sqlite3_column_double(statement.raw, index.cint))

proc columnText*(statement: Statement; index: int): string =
  let text = sqlite3_column_text(statement.raw, index.cint)
  let length = sqlite3_column_bytes(statement.raw, index.cint)
  if text.isNil or length <= 0: return ""
  result = newString(int(length))
  copyMem(addr result[0], text, int(length))

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
  let lease = TransactionLease(active: true, db: addr db)
  db.currentUpdate = lease
  defer:
    db.resetCachedUpdateStatements()
    lease.active = false
    lease.db = nil
    if db.currentUpdate == lease: db.currentUpdate = nil
  var connection = UpdateConnection(db: addr db, lease: lease)
  var bodyResult: Result[T, DbError]
  try:
    bodyResult = body(connection)
  except CatchableError as error:
    discard db.execRaw("ROLLBACK")
    discard db.finishStableOperation(begun.value, false)
    return Result[T, DbError](isOk: false,
      error: DbError(code: -1, message: error.msg, kind: dekInvalidState))
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
    for index in 0 ..< queryValues.len:
      ## `queryValues` is a local copy that stays alive until `finalize`, so the
      ## parameters can be bound with SQLITE_STATIC without a second copy.
      let itemLen = queryValues[index].len
      let data = if itemLen == 0: cstring("")
                 else: cast[cstring](unsafeAddr queryValues[index][0])
      let bound = statement.bindStaticText(index + 1, data, itemLen)
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
