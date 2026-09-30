## P1 benchmark canister. Each update endpoint performs one synchronous SQLite
## transaction; no inter-canister call is made inside the measurement window.
import nicp_cdk
import nicp_cdk/ic0/ic0
import std/tables
import ic_sqlite
import ic_sqlite/stable/backend as stable_backend
import ic_sqlite/stable/ic_backend
import ../../../shared/bench_spec

type
  BenchReport = object
    rows, instructions, checksum, db_size, stable_pages, stable_bytes: uint64
  DbStatsReport = object
    db_size, stable_pages, stable_bytes, sqlite_page_size, sqlite_page_count, sqlite_freelist_count: uint64
    sqlite_cache_used_bytes: uint64
  BenchChurnStepReport = object
    cycle, rows, instructions, row_count, db_size, stable_pages, stable_bytes: uint64
    sqlite_page_size, sqlite_page_count, sqlite_freelist_count: uint64
    phase: string
  HostStatsReport = object
    raw_stable_pages, raw_stable_bytes: uint64
  NimCapacityGrowthReport = object
    rows, writes, instructions, checksum: uint64
    db_size_before, db_size_after: uint64
    sqlite_virtual_pages_before, sqlite_virtual_pages_after: uint64
    raw_stable_pages_before, raw_stable_pages_after: uint64
    raw_stable_bytes_before, raw_stable_bytes_after: uint64
  NimGrowthProfileReport = object
    rows, writes, instructions, checksum, db_size, stable_pages, stable_bytes: uint64
    update_open, key_value_format, execute_total: uint64
    stable_read_calls, stable_read_bytes, stable_write_calls, stable_write_bytes: uint64
    stable_grow_calls, stable_grow_pages: uint64
  NimReadProfileReport = object
    rows, instructions, checksum, db_size, stable_pages, stable_bytes: uint64
    prepare, reset_bind, step, column_read: uint64
    stable_read_calls, stable_read_bytes: uint64
  NimWriteProfileReport = object
    rows, instructions, checksum, db_size, stable_pages, stable_bytes: uint64
    update_open, prepare, key_value_format, execute_total: uint64
    stable_read_calls, stable_read_bytes, stable_write_calls, stable_write_bytes: uint64
    stable_grow_calls, stable_grow_pages: uint64
  NimGetManyProfileReport = object
    rows, instructions, checksum, db_size, stable_pages, stable_bytes: uint64
    sql_build, key_build, prepare, bind_total, row_scan: uint64
    stable_read_calls, stable_read_bytes: uint64
  ## -d:benchmarkProfile 版の overlay / clean-page cache / VFS counters.
  ## raw_stable_bytes / heap_bytes / pager cache bytes are kept as separate
  ## fields so a report never mixes physical stable memory with heap.
  NimCleanCacheProfileReport = object
    rows, writes, instructions, checksum: uint64
    clean_cache_pages: uint64
    dirty_pages_current, dirty_pages_peak: uint64
    dirty_pages_new, dirty_pages_new_bytes: uint64
    clean_cache_hits, clean_cache_misses, clean_cache_evictions, clean_cache_bytes: uint64
    temp_buffer_allocs, temp_buffer_alloc_bytes: uint64
    vfs_read_calls, vfs_write_calls, vfs_short_reads, vfs_truncate_calls: uint64
    stable_read_calls, stable_read_bytes: uint64
    stable_write_calls, stable_write_bytes: uint64
    stable_grow_calls, stable_grow_pages: uint64
    db_size, sqlite_virtual_pages, sqlite_page_count, sqlite_cache_used_bytes: uint64
    raw_stable_pages, raw_stable_bytes: uint64
  ## Isolated VFS/core comparison series: fixed allocation-free buffers, same
  ## SQL / transaction / prepare / step / reset counts. Deliberately kept
  ## separate from the public API series.
  NimVfsCoreProfileReport = object
    rows, instructions, checksum: uint64
    clean_cache_pages: uint64
    dirty_pages_current, dirty_pages_peak: uint64
    dirty_pages_new, dirty_pages_new_bytes: uint64
    clean_cache_hits, clean_cache_misses, clean_cache_evictions, clean_cache_bytes: uint64
    temp_buffer_allocs, temp_buffer_alloc_bytes: uint64
    vfs_read_calls, vfs_write_calls, vfs_short_reads, vfs_truncate_calls: uint64
    stable_read_calls, stable_read_bytes: uint64
    stable_write_calls, stable_write_bytes: uint64
    stable_grow_calls, stable_grow_pages: uint64
    db_size, sqlite_virtual_pages, sqlite_page_count, sqlite_cache_used_bytes: uint64
    raw_stable_pages, raw_stable_bytes: uint64
  StableIoMetrics = object
    readCalls, readBytes, writeCalls, writeBytes, growCalls, growPages: uint64
  MetricsBackend = ref object of stable_backend.StableBackend
    inner: stable_backend.StableBackend

var stableIoMetrics: StableIoMetrics
var stableIoMetricsEnabled = false

proc resetStableIoMetrics() = stableIoMetrics = StableIoMetrics()

proc newMetricsBackend(): MetricsBackend = MetricsBackend(inner: newIcStableBackend())

method sizePages(backend: MetricsBackend): uint64 = backend.inner.sizePages()
method grow(backend: MetricsBackend; pages: uint64): bool =
  if stableIoMetricsEnabled:
    inc stableIoMetrics.growCalls
    stableIoMetrics.growPages += pages
  backend.inner.grow(pages)
method read(backend: MetricsBackend; offset: uint64; dst: pointer; size: uint64) =
  if stableIoMetricsEnabled:
    inc stableIoMetrics.readCalls
    stableIoMetrics.readBytes += size
  backend.inner.read(offset, dst, size)
method write(backend: MetricsBackend; offset: uint64; src: pointer; size: uint64) =
  if stableIoMetricsEnabled:
    inc stableIoMetrics.writeCalls
    stableIoMetrics.writeBytes += size
  backend.inner.write(offset, src, size)

var database: Db
var databaseReady = false
var useMetricsBackend = false
var dbCleanCachePages = 0'u64
var dbQueryReuse = false
var dbStatementCache = false

when defined(benchmarkFailpoint):
  type FaultInjectingBackend = ref object of stable_backend.StableBackend
    inner: stable_backend.StableBackend

  var failAfterStableWrites = -1

  proc newFaultInjectingBackend(): FaultInjectingBackend =
    FaultInjectingBackend(inner: newIcStableBackend())

  method sizePages(backend: FaultInjectingBackend): uint64 = backend.inner.sizePages()
  method grow(backend: FaultInjectingBackend; pages: uint64): bool = backend.inner.grow(pages)
  method read(backend: FaultInjectingBackend; offset: uint64; dst: pointer; size: uint64) =
    backend.inner.read(offset, dst, size)
  method write(backend: FaultInjectingBackend; offset: uint64; src: pointer; size: uint64) =
    if failAfterStableWrites == 0:
      raise newException(ValueError, "injected stable write failure")
    if failAfterStableWrites > 0: dec failAfterStableWrites
    backend.inner.write(offset, src, size)

proc replyOk[T: object](value: T) =
  ## nicp_cdk versions before the Nat64 conversion fix need explicit fields.
  var record = CandidRecord(kind: ckRecord, fields: initOrderedTable[string, CandidValue]())
  for name, item in value.fieldPairs:
    when item is uint64: record.fields[name] = newCandidNat64(item)
    elif item is string: record.fields[name] = newCandidText(item)
    else: {.error: "unsupported benchmark Candid field type".}
  reply(newCandidVariant("Ok", newCandidRecord(record)))

proc replyErr(message: string) =
  reply(newCandidVariant("Err", newCandidText(message)))

proc ensureDatabase(): string =
  if databaseReady: return ""
  database.close()
  var config = defaultDbConfig()
  config.cleanCachePages = dbCleanCachePages
  config.queryConnectionReuse = dbQueryReuse
  config.statementCacheEnabled = dbStatementCache
  when defined(benchmarkFailpoint):
    let opened = database.init(newFaultInjectingBackend(), config = config)
  else:
    let opened = database.init(if useMetricsBackend: newMetricsBackend() else: newIcStableBackend(), config = config)
  if not opened.isOk: return opened.error.message
  let schema = database.exec("CREATE TABLE IF NOT EXISTS bench (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID")
  if not schema.isOk: return schema.error.message
  databaseReady = true
  ""

proc canister_init() {.exportwasm.} =
  let failure = ensureDatabase()
  if failure.len > 0: ic0_trap(cast[int](failure.cstring), failure.len)

proc canister_post_upgrade() {.exportwasm.} =
  databaseReady = false
  let failure = ensureDatabase()
  if failure.len > 0: ic0_trap(cast[int](failure.cstring), failure.len)

proc report(rows: uint32; start, checksum: uint64): BenchReport =
  let instructions = ic0_performance_counter(0'u32) - start
  let stats = database.storageStats()
  BenchReport(rows: uint64(rows), instructions: instructions, checksum: checksum,
    db_size: stats.dbSize, stable_pages: stats.sqliteVirtualPages,
    stable_bytes: stats.sqliteVirtualPages * bench_spec.StablePageSize)

proc insertRows(tableName: string; start, count: uint32; operation: string;
                resetTable = false): Result[uint64, DbError] =
  database.withUpdate(proc(conn: var UpdateConnection): Result[uint64, DbError] =
    if resetTable:
      let dropped = conn.exec("DROP TABLE IF EXISTS " & tableName)
      if not dropped.isOk: return Result[uint64, DbError](isOk: false, error: dropped.error)
      let created = conn.exec(if tableName == "bench": BenchSchemaSql else: ChurnSchemaSql)
      if not created.isOk: return Result[uint64, DbError](isOk: false, error: created.error)
    let sql = case operation
      of "insert": "INSERT INTO " & tableName & "(key, value) VALUES (?, ?)"
      of "update": "UPDATE bench SET value = ? WHERE key = ?"
      else: "DELETE FROM churn_bench WHERE key = ?"
    let prepared = conn.prepare(sql)
    if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
    var statement = prepared.value
    defer: statement.finalize()
    for offset in 0'u32 ..< count:
      let index = start + offset
      let key = if tableName == "churn_bench": churnKey(index) else: benchKey(index)
      let first = if operation == "update": updatedValue(index)
                  elif operation == "delete": key
                  else: key
      let bound = statement.bind(1, sqlText(first))
      if not bound.isOk: return Result[uint64, DbError](isOk: false, error: bound.error)
      if operation != "delete":
        let second = statement.bind(2, sqlText(if operation == "update": key else: benchValue(index)))
        if not second.isOk: return Result[uint64, DbError](isOk: false, error: second.error)
      let stepped = statement.step()
      if not stepped.isOk: return Result[uint64, DbError](isOk: false, error: stepped.error)
      if operation == "delete" and conn.changes() != 1:
        return Result[uint64, DbError](isOk: false, error: DbError(message: "churn row not found"))
      let resetResult = statement.reset()
      if not resetResult.isOk: return Result[uint64, DbError](isOk: false, error: resetResult.error)
    Result[uint64, DbError](isOk: true, value: uint64(count))
  )

proc insertRowsBorrowed(tableName: string; start, count: uint32; operation: string;
                        resetTable = false): Result[uint64, DbError] =
  ## A1-style borrowed variant of `insertRows`: same seed/SQL/transaction/report,
  ## but the TEXT parameters are bound with SQLITE_STATIC through the scoped
  ## helpers and cleared per row.
  database.withUpdate(proc(conn: var UpdateConnection): Result[uint64, DbError] =
    if resetTable:
      let dropped = conn.exec("DROP TABLE IF EXISTS " & tableName)
      if not dropped.isOk: return Result[uint64, DbError](isOk: false, error: dropped.error)
      let created = conn.exec(if tableName == "bench": BenchSchemaSql else: ChurnSchemaSql)
      if not created.isOk: return Result[uint64, DbError](isOk: false, error: created.error)
    let sql = case operation
      of "insert": "INSERT INTO " & tableName & "(key, value) VALUES (?, ?)"
      of "update": "UPDATE bench SET value = ? WHERE key = ?"
      else: "DELETE FROM churn_bench WHERE key = ?"
    let prepared = conn.prepare(sql)
    if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
    var statement = prepared.value
    defer: statement.finalize()
    for offset in 0'u32 ..< count:
      let index = start + offset
      let key = if tableName == "churn_bench": churnKey(index) else: benchKey(index)
      case operation
      of "update":
        let executed = statement.executeTextTextBorrowed(updatedValue(index), key)
        if not executed.isOk: return Result[uint64, DbError](isOk: false, error: executed.error)
      of "delete":
        let executed = statement.executeTextBorrowed(key)
        if not executed.isOk: return Result[uint64, DbError](isOk: false, error: executed.error)
      else:
        let executed = statement.executeTextTextBorrowed(key, benchValue(index))
        if not executed.isOk: return Result[uint64, DbError](isOk: false, error: executed.error)
      if operation == "delete" and conn.changes() != 1:
        return Result[uint64, DbError](isOk: false, error: DbError(message: "churn row not found"))
    Result[uint64, DbError](isOk: true, value: uint64(count))
  )

proc resetBench(rows: uint32): Result[uint64, DbError] =
  insertRows("bench", 0, rows, "insert", resetTable = true)

proc scalar(sql: string): Result[uint64, DbError] =
  database.withQuery(proc(conn: var Connection): Result[uint64, DbError] =
    let prepared = conn.prepare(sql)
    if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
    var statement = prepared.value
    defer: statement.finalize()
    let stepped = statement.step()
    if not stepped.isOk: return Result[uint64, DbError](isOk: false, error: stepped.error)
    if stepped.value != srRow: return Result[uint64, DbError](isOk: false, error: DbError(message: "no SQLite statistic"))
    Result[uint64, DbError](isOk: true, value: uint64(statement.columnInt64(0)))
  )

proc bench_reset() {.update.} =
  let request = Request.new()
  let rows = request.getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let start = ic0_performance_counter(0'u32)
  let inserted = resetBench(rows)
  if not inserted.isOk: replyErr(inserted.error.message); return
  replyOk(report(rows, start, uint64(rows)))

proc bench_insert_only() {.update.} =
  let request = Request.new()
  let rows = request.getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let cleared = resetBench(0)
  if not cleared.isOk: replyErr(cleared.error.message); return
  let start = ic0_performance_counter(0'u32)
  let inserted = insertRows("bench", 0, rows, "insert")
  if not inserted.isOk: replyErr(inserted.error.message); return
  replyOk(report(rows, start, uint64(rows)))

proc bench_insert_only_borrowed() {.update.} =
  ## A1: same as `bench_insert_only` but TEXT parameters are bound with
  ## SQLITE_STATIC through the scoped borrowed helpers.
  let request = Request.new()
  let rows = request.getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let cleared = resetBench(0)
  if not cleared.isOk: replyErr(cleared.error.message); return
  let start = ic0_performance_counter(0'u32)
  let inserted = insertRowsBorrowed("bench", 0, rows, "insert")
  if not inserted.isOk: replyErr(inserted.error.message); return
  replyOk(report(rows, start, uint64(rows)))

proc bench_update_only() {.update.} =
  let request = Request.new()
  let rows = request.getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let seeded = resetBench(rows)
  if not seeded.isOk: replyErr(seeded.error.message); return
  let start = ic0_performance_counter(0'u32)
  let updated = insertRows("bench", 0, rows, "update")
  if not updated.isOk: replyErr(updated.error.message); return
  replyOk(report(rows, start, uint64(rows)))

proc bench_update_only_borrowed_string() {.update.} =
  ## A1: same seed/SQL/transaction/report as `bench_update_only`, but the two
  ## TEXT parameters are bound with the allocation-free internal
  ## `executeTextTextBorrowed` while the strings are still formatted per row.
  let request = Request.new()
  let rows = request.getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let seeded = resetBench(rows)
  if not seeded.isOk: replyErr(seeded.error.message); return
  let start = ic0_performance_counter(0'u32)
  let updated = database.withUpdate(proc(conn: var UpdateConnection): Result[uint64, DbError] =
    let prepared = conn.prepare("UPDATE bench SET value = ? WHERE key = ?")
    if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
    var statement = prepared.value
    defer: statement.finalize()
    for index in 0'u32 ..< rows:
      let value = updatedValue(index)
      let key = benchKey(index)
      let executed = statement.executeTextTextBorrowed(value, key)
      if not executed.isOk: return Result[uint64, DbError](isOk: false, error: executed.error)
    Result[uint64, DbError](isOk: true, value: uint64(rows))
  )
  if not updated.isOk: replyErr(updated.error.message); return
  replyOk(report(rows, start, uint64(rows)))

proc bench_update_only_borrowed() {.update.} =
  ## A2: `executeTextTextBorrowed` with fixed-length `array` inputs that match
  ## the Rust `updated_value()` / `key()` fixtures byte for byte. This removes
  ## the per-row string formatting as well as the SQLITE_TRANSIENT copy.
  let request = Request.new()
  let rows = request.getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let seeded = resetBench(rows)
  if not seeded.isOk: replyErr(seeded.error.message); return
  let start = ic0_performance_counter(0'u32)
  let updated = database.withUpdate(proc(conn: var UpdateConnection): Result[uint64, DbError] =
    let prepared = conn.prepare("UPDATE bench SET value = ? WHERE key = ?")
    if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
    var statement = prepared.value
    defer: statement.finalize()
    for index in 0'u32 ..< rows:
      let valueBuffer = updatedValueBuffer(index)
      let keyBuffer = benchKeyBuffer(index)
      let executed = statement.executeTextTextBorrowed(valueBuffer, keyBuffer)
      if not executed.isOk: return Result[uint64, DbError](isOk: false, error: executed.error)
    Result[uint64, DbError](isOk: true, value: uint64(rows))
  )
  if not updated.isOk: replyErr(updated.error.message); return
  replyOk(report(rows, start, uint64(rows)))

proc bench_update_only_borrowed_general() {.update.} =
  ## A2-general: the same workload through the public scoped API
  ## `executeBorrowed(openArray[SqlValue])`, which supports N parameters and
  ## mixed types. It must match the specialized A2 path (no SQLITE_TRANSIENT
  ## copy) while adding the `SqlValue` construction overhead.
  let request = Request.new()
  let rows = request.getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let seeded = resetBench(rows)
  if not seeded.isOk: replyErr(seeded.error.message); return
  let start = ic0_performance_counter(0'u32)
  let updated = database.withUpdate(proc(conn: var UpdateConnection): Result[uint64, DbError] =
    let prepared = conn.prepare("UPDATE bench SET value = ? WHERE key = ?")
    if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
    var statement = prepared.value
    defer: statement.finalize()
    for index in 0'u32 ..< rows:
      let values = [sqlText(updatedValue(index)), sqlText(benchKey(index))]
      let executed = statement.executeBorrowed(values)
      if not executed.isOk: return Result[uint64, DbError](isOk: false, error: executed.error)
    Result[uint64, DbError](isOk: true, value: uint64(rows))
  )
  if not updated.isOk: replyErr(updated.error.message); return
  replyOk(report(rows, start, uint64(rows)))

proc bench_append_insert() {.update.} =
  let request = Request.new()
  let baseRows = request.getNat32(0)
  let appendRows = request.getNat32(1)
  if not validateFixedBenchKeyRows(baseRows) or not validateFixedBenchKeyRange(baseRows, appendRows):
    replyErr("rows exceeds fixed key range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let seeded = resetBench(baseRows)
  if not seeded.isOk: replyErr(seeded.error.message); return
  let start = ic0_performance_counter(0'u32)
  let inserted = insertRows("bench", baseRows, appendRows, "insert")
  if not inserted.isOk: replyErr(inserted.error.message); return
  replyOk(report(appendRows, start, uint64(appendRows)))

proc bench_large_blob() {.update.} =
  let bytes = Request.new().getNat32(0)
  if bytes > 16'u32 * 1024 * 1024: replyErr("blob exceeds configured limit"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let start = ic0_performance_counter(0'u32)
  var payload = newSeq[byte](int(bytes))
  for index in 0 ..< payload.len: payload[index] = 0x5a
  let written = database.withUpdate(proc(conn: var UpdateConnection): Result[uint64, DbError] =
    let schema = conn.exec("DROP TABLE IF EXISTS blob_bench; CREATE TABLE blob_bench (id INTEGER PRIMARY KEY, body BLOB NOT NULL)")
    if not schema.isOk: return Result[uint64, DbError](isOk: false, error: schema.error)
    let inserted = conn.execValues("INSERT INTO blob_bench(id, body) VALUES (?, ?)", [sqlInt(1), sqlBlob(payload)])
    if not inserted.isOk: return Result[uint64, DbError](isOk: false, error: inserted.error)
    let length = conn.prepare("SELECT length(body) FROM blob_bench WHERE id = 1")
    if not length.isOk: return Result[uint64, DbError](isOk: false, error: length.error)
    var statement = length.value
    defer: statement.finalize()
    let stepped = statement.step()
    if not stepped.isOk: return Result[uint64, DbError](isOk: false, error: stepped.error)
    if stepped.value != srRow: return Result[uint64, DbError](isOk: false, error: DbError(message: "blob row missing"))
    Result[uint64, DbError](isOk: true, value: uint64(statement.columnInt64(0)))
  )
  if not written.isOk: replyErr(written.error.message); return
  replyOk(report(bytes, start, written.value))

proc bench_join() {.update.} =
  let rows = Request.new().getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let start = ic0_performance_counter(0'u32)
  let joined = database.withUpdate(proc(conn: var UpdateConnection): Result[uint64, DbError] =
    let schema = conn.exec("DROP TABLE IF EXISTS join_left; DROP TABLE IF EXISTS join_right; CREATE TABLE join_left (id INTEGER PRIMARY KEY, group_id INTEGER NOT NULL, body TEXT NOT NULL); CREATE TABLE join_right (group_id INTEGER PRIMARY KEY, label TEXT NOT NULL)")
    if not schema.isOk: return Result[uint64, DbError](isOk: false, error: schema.error)
    for group in 0'i64 ..< 100'i64:
      let inserted = conn.execValues("INSERT INTO join_right(group_id, label) VALUES (?, ?)", [sqlInt(group), sqlText("group-" & $group)])
      if not inserted.isOk: return Result[uint64, DbError](isOk: false, error: inserted.error)
    for index in 0'u32 ..< rows:
      let inserted = conn.execValues("INSERT INTO join_left(id, group_id, body) VALUES (?, ?, ?)",
        [sqlInt(int64(index)), sqlInt(int64(index mod 100)), sqlText("body-" & $index)])
      if not inserted.isOk: return Result[uint64, DbError](isOk: false, error: inserted.error)
    let count = conn.prepare("SELECT COUNT(*) FROM join_left JOIN join_right ON join_left.group_id = join_right.group_id")
    if not count.isOk: return Result[uint64, DbError](isOk: false, error: count.error)
    var statement = count.value
    defer: statement.finalize()
    let stepped = statement.step()
    if not stepped.isOk: return Result[uint64, DbError](isOk: false, error: stepped.error)
    if stepped.value != srRow: return Result[uint64, DbError](isOk: false, error: DbError(message: "join count missing"))
    Result[uint64, DbError](isOk: true, value: uint64(statement.columnInt64(0)))
  )
  if not joined.isOk: replyErr(joined.error.message); return
  replyOk(report(rows, start, joined.value))

proc bench_read() {.query.} =
  let rows = Request.new().getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let start = ic0_performance_counter(0'u32)
  let read = database.withQuery(proc(conn: var Connection): Result[uint64, DbError] =
    let prepared = conn.prepare("SELECT value FROM bench WHERE key = ?")
    if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
    var statement = prepared.value
    defer: statement.finalize()
    var checksum = 0'u64
    for index in 0'u32 ..< rows:
      let bound = statement.bind(1, sqlText(benchKey(index)))
      if not bound.isOk: return Result[uint64, DbError](isOk: false, error: bound.error)
      let stepped = statement.step()
      if not stepped.isOk: return Result[uint64, DbError](isOk: false, error: stepped.error)
      if stepped.value == srRow: checksum += uint64(statement.columnBytes(0))
      let resetResult = statement.reset()
      if not resetResult.isOk: return Result[uint64, DbError](isOk: false, error: resetResult.error)
    Result[uint64, DbError](isOk: true, value: checksum)
  )
  if not read.isOk: replyErr(read.error.message); return
  replyOk(report(rows, start, read.value))

proc bench_read_borrowed() {.query.} =
  ## A1-style read: the point-read key is bound with SQLITE_STATIC and the
  ## bindings are cleared by `reset` after the column is read, so no borrowed
  ## pointer outlives the loop iteration.
  let rows = Request.new().getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let start = ic0_performance_counter(0'u32)
  let read = database.withQuery(proc(conn: var Connection): Result[uint64, DbError] =
    let prepared = conn.prepare("SELECT value FROM bench WHERE key = ?")
    if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
    var statement = prepared.value
    defer: statement.finalize()
    var checksum = 0'u64
    for index in 0'u32 ..< rows:
      let key = benchKey(index)
      let bound = statement.bindStaticText(1, cast[cstring](unsafeAddr key[0]), key.len)
      if not bound.isOk: return Result[uint64, DbError](isOk: false, error: bound.error)
      let stepped = statement.step()
      if not stepped.isOk: return Result[uint64, DbError](isOk: false, error: stepped.error)
      if stepped.value == srRow: checksum += uint64(statement.columnBytes(0))
      let resetResult = statement.reset()
      if not resetResult.isOk: return Result[uint64, DbError](isOk: false, error: resetResult.error)
    Result[uint64, DbError](isOk: true, value: checksum)
  )
  if not read.isOk: replyErr(read.error.message); return
  replyOk(report(rows, start, read.value))

proc bench_many_rows() {.query.} =
  let rows = Request.new().getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let start = ic0_performance_counter(0'u32)
  let read = database.withQuery(proc(conn: var Connection): Result[uint64, DbError] =
    let prepared = conn.prepare("SELECT value FROM bench ORDER BY key LIMIT ?")
    if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
    var statement = prepared.value
    defer: statement.finalize()
    let bound = statement.bind(1, sqlInt(int64(rows)))
    if not bound.isOk: return Result[uint64, DbError](isOk: false, error: bound.error)
    var checksum = 0'u64
    while true:
      let stepped = statement.step()
      if not stepped.isOk: return Result[uint64, DbError](isOk: false, error: stepped.error)
      if stepped.value == srDone: break
      checksum += uint64(statement.columnBytes(0))
    Result[uint64, DbError](isOk: true, value: checksum)
  )
  if not read.isOk: replyErr(read.error.message); return
  replyOk(report(rows, start, read.value))

proc pointRead(rows: uint32; prepareEach: bool): Result[uint64, DbError] =
  database.withQuery(proc(conn: var Connection): Result[uint64, DbError] =
    var checksum = 0'u64
    var cached: Statement
    if not prepareEach:
      let prepared = conn.prepare("SELECT value FROM bench WHERE key = ?")
      if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
      cached = prepared.value
    defer:
      if not prepareEach: cached.finalize()
    for index in 0'u32 ..< rows:
      var statement: Statement
      if prepareEach:
        let prepared = conn.prepare("SELECT value FROM bench WHERE key = ?")
        if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
        statement = prepared.value
      else:
        statement = cached
      let bound = statement.bind(1, sqlText(benchKey(index)))
      if not bound.isOk: return Result[uint64, DbError](isOk: false, error: bound.error)
      let stepped = statement.step()
      if not stepped.isOk: return Result[uint64, DbError](isOk: false, error: stepped.error)
      if stepped.value == srRow: checksum += uint64(statement.columnBytes(0))
      if prepareEach:
        statement.finalize()
      else:
        let reset = statement.reset()
        if not reset.isOk: return Result[uint64, DbError](isOk: false, error: reset.error)
        cached = statement
    Result[uint64, DbError](isOk: true, value: checksum)
  )

proc bench_read_public_helper() {.query.} =
  let rows = Request.new().getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let start = ic0_performance_counter(0'u32)
  let read = pointRead(rows, false)
  if not read.isOk: replyErr(read.error.message); return
  replyOk(report(rows, start, read.value))

proc bench_read_prepare_each() {.query.} =
  let rows = Request.new().getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let start = ic0_performance_counter(0'u32)
  let read = pointRead(rows, true)
  if not read.isOk: replyErr(read.error.message); return
  replyOk(report(rows, start, read.value))

proc bench_get_many_in() {.query.} =
  let rows = Request.new().getNat32(0)
  if rows == 0 or rows > 999 or not validateFixedBenchKeyRows(rows):
    replyErr("multi-get rows must be between 1 and 999"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  var sql = "SELECT value FROM bench WHERE key IN ("
  for index in 0'u32 ..< rows:
    if index > 0: sql.add(",")
    sql.add("?")
  sql.add(") ORDER BY key")
  let start = ic0_performance_counter(0'u32)
  let read = database.withQuery(proc(conn: var Connection): Result[uint64, DbError] =
    let prepared = conn.prepare(sql)
    if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
    var statement = prepared.value
    defer: statement.finalize()
    for index in 0'u32 ..< rows:
      let bound = statement.bind(int(index) + 1, sqlText(benchKey(index)))
      if not bound.isOk: return Result[uint64, DbError](isOk: false, error: bound.error)
    var checksum = 0'u64
    while true:
      let stepped = statement.step()
      if not stepped.isOk: return Result[uint64, DbError](isOk: false, error: stepped.error)
      if stepped.value == srDone: break
      checksum += uint64(statement.columnBytes(0))
    Result[uint64, DbError](isOk: true, value: checksum)
  )
  if not read.isOk: replyErr(read.error.message); return
  replyOk(report(rows, start, read.value))

proc bench_unbounded_order_by() {.update.} =
  let rows = Request.new().getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let start = ic0_performance_counter(0'u32)
  let sorted = database.withUpdate(proc(conn: var UpdateConnection): Result[uint64, DbError] =
    let schema = conn.exec("DROP TABLE IF EXISTS order_bench; CREATE TABLE order_bench (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
    if not schema.isOk: return Result[uint64, DbError](isOk: false, error: schema.error)
    for index in 0'u32 ..< rows:
      let inserted = conn.execValues("INSERT INTO order_bench(id, value) VALUES (?, ?)",
        [sqlInt(int64(index)), sqlText("order-" & $(rows - index))])
      if not inserted.isOk: return Result[uint64, DbError](isOk: false, error: inserted.error)
    let prepared = conn.prepare("SELECT value FROM order_bench ORDER BY value")
    if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
    var statement = prepared.value
    defer: statement.finalize()
    var checksum = 0'u64
    while true:
      let stepped = statement.step()
      if not stepped.isOk: return Result[uint64, DbError](isOk: false, error: stepped.error)
      if stepped.value == srDone: break
      checksum += uint64(statement.columnBytes(0))
    Result[uint64, DbError](isOk: true, value: checksum)
  )
  if not sorted.isOk: replyErr(sorted.error.message); return
  replyOk(report(rows, start, sorted.value))

proc bench_growth() {.update.} =
  let request = Request.new()
  let rows = request.getNat32(0)
  let writes = request.getNat32(1)
  if rows == 0 or not validateFixedBenchKeyRows(rows) or not validateFixedBenchKeyRows(writes):
    replyErr("invalid growth range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let seeded = database.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
    let schema = conn.exec("DROP TABLE IF EXISTS growth_bench; CREATE TABLE growth_bench (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID")
    if not schema.isOk: return Result[bool, DbError](isOk: false, error: schema.error)
    for index in 0'u32 ..< rows:
      let inserted = conn.execValues("INSERT INTO growth_bench(key, value) VALUES (?, ?)",
        [sqlText(prefixedKey('g', index)), sqlText(growthValue(index))])
      if not inserted.isOk: return Result[bool, DbError](isOk: false, error: inserted.error)
    Result[bool, DbError](isOk: true, value: true)
  )
  if not seeded.isOk: replyErr(seeded.error.message); return
  let start = ic0_performance_counter(0'u32)
  for index in 0'u32 ..< writes:
    let updated = database.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let result = conn.execValues("UPDATE growth_bench SET value = ? WHERE key = ?",
        [sqlText(writeValue(index)), sqlText(prefixedKey('g', index mod rows))])
      if not result.isOk: return Result[bool, DbError](isOk: false, error: result.error)
      if conn.changes() != 1: return Result[bool, DbError](isOk: false, error: DbError(message: "growth row missing"))
      Result[bool, DbError](isOk: true, value: true)
    )
    if not updated.isOk: replyErr(updated.error.message); return
  replyOk(report(rows, start, uint64(writes)))

proc bench_capacity_growth_guard() {.update.} =
  ## Nim has a fixed superblock offset and no Rust-style page table. Report the
  ## directly observable capacity invariants under distinct field names.
  let request = Request.new()
  let rows = request.getNat32(0)
  let writes = request.getNat32(1)
  if rows == 0 or not validateFixedBenchKeyRows(rows) or not validateFixedBenchKeyRows(writes):
    replyErr("invalid capacity guard range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let seeded = database.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
    let schema = conn.exec("DROP TABLE IF EXISTS growth_bench; CREATE TABLE growth_bench (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID")
    if not schema.isOk: return Result[bool, DbError](isOk: false, error: schema.error)
    for index in 0'u32 ..< rows:
      let inserted = conn.execValues("INSERT INTO growth_bench(key, value) VALUES (?, ?)",
        [sqlText(prefixedKey('g', index)), sqlText(growthValue(index))])
      if not inserted.isOk: return Result[bool, DbError](isOk: false, error: inserted.error)
    Result[bool, DbError](isOk: true, value: true)
  )
  if not seeded.isOk: replyErr(seeded.error.message); return
  let before = database.storageStats()
  let rawBeforePages = ic0_stable64_size()
  let start = ic0_performance_counter(0'u32)
  for index in 0'u32 ..< writes:
    let updated = database.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let result = conn.execValues("UPDATE growth_bench SET value = ? WHERE key = ?",
        [sqlText(writeValue(index)), sqlText(prefixedKey('g', index mod rows))])
      if not result.isOk: return Result[bool, DbError](isOk: false, error: result.error)
      if conn.changes() != 1: return Result[bool, DbError](isOk: false, error: DbError(message: "growth row missing"))
      Result[bool, DbError](isOk: true, value: true)
    )
    if not updated.isOk: replyErr(updated.error.message); return
  let instructions = ic0_performance_counter(0'u32) - start
  let after = database.storageStats()
  let rawAfterPages = ic0_stable64_size()
  if after.dbSize != before.dbSize or after.sqliteVirtualPages != before.sqliteVirtualPages or
      rawAfterPages != rawBeforePages:
    replyErr("existing-capacity update changed a storage high-water mark"); return
  replyOk(NimCapacityGrowthReport(rows: uint64(rows), writes: uint64(writes),
    instructions: instructions, checksum: uint64(writes),
    db_size_before: before.dbSize, db_size_after: after.dbSize,
    sqlite_virtual_pages_before: before.sqliteVirtualPages,
    sqlite_virtual_pages_after: after.sqliteVirtualPages,
    raw_stable_pages_before: rawBeforePages, raw_stable_pages_after: rawAfterPages,
    raw_stable_bytes_before: rawBeforePages * bench_spec.StablePageSize,
    raw_stable_bytes_after: rawAfterPages * bench_spec.StablePageSize))

proc bench_growth_profile() {.update.} =
  ## Nim-specific profile: timing and stable backend I/O are measured directly.
  let request = Request.new()
  let rows = request.getNat32(0)
  let writes = request.getNat32(1)
  if rows == 0 or not validateFixedBenchKeyRows(rows) or not validateFixedBenchKeyRows(writes):
    replyErr("invalid growth profile range"); return
  ## Reopen only this profiling request with its counting backend. Regular
  ## benchmark endpoints keep the direct stable backend in their hot path.
  database.close()
  databaseReady = false
  useMetricsBackend = true
  defer:
    stableIoMetricsEnabled = false
    useMetricsBackend = false
    database.close()
    databaseReady = false
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let seeded = database.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
    let schema = conn.exec("DROP TABLE IF EXISTS growth_bench; CREATE TABLE growth_bench (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID")
    if not schema.isOk: return Result[bool, DbError](isOk: false, error: schema.error)
    for index in 0'u32 ..< rows:
      let inserted = conn.execValues("INSERT INTO growth_bench(key, value) VALUES (?, ?)",
        [sqlText(prefixedKey('g', index)), sqlText(growthValue(index))])
      if not inserted.isOk: return Result[bool, DbError](isOk: false, error: inserted.error)
    Result[bool, DbError](isOk: true, value: true)
  )
  if not seeded.isOk: replyErr(seeded.error.message); return
  resetStableIoMetrics()
  stableIoMetricsEnabled = true
  let start = ic0_performance_counter(0'u32)
  var openInstructions = 0'u64
  var formatInstructions = 0'u64
  var executeInstructions = 0'u64
  for index in 0'u32 ..< writes:
    let updateStart = ic0_performance_counter(0'u32)
    let updated = database.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      openInstructions += ic0_performance_counter(0'u32) - updateStart
      let formatStart = ic0_performance_counter(0'u32)
      let value = writeValue(index)
      let key = prefixedKey('g', index mod rows)
      formatInstructions += ic0_performance_counter(0'u32) - formatStart
      let executeStart = ic0_performance_counter(0'u32)
      let result = conn.execValues("UPDATE growth_bench SET value = ? WHERE key = ?",
        [sqlText(value), sqlText(key)])
      executeInstructions += ic0_performance_counter(0'u32) - executeStart
      if not result.isOk: return Result[bool, DbError](isOk: false, error: result.error)
      if conn.changes() != 1: return Result[bool, DbError](isOk: false, error: DbError(message: "growth row missing"))
      Result[bool, DbError](isOk: true, value: true)
    )
    if not updated.isOk: replyErr(updated.error.message); return
  let stats = database.storageStats()
  replyOk(NimGrowthProfileReport(rows: uint64(rows), writes: uint64(writes),
    instructions: ic0_performance_counter(0'u32) - start, checksum: uint64(writes),
    db_size: stats.dbSize, stable_pages: stats.sqliteVirtualPages,
    stable_bytes: stats.sqliteVirtualPages * bench_spec.StablePageSize,
    update_open: openInstructions, key_value_format: formatInstructions,
    execute_total: executeInstructions, stable_read_calls: stableIoMetrics.readCalls,
    stable_read_bytes: stableIoMetrics.readBytes, stable_write_calls: stableIoMetrics.writeCalls,
    stable_write_bytes: stableIoMetrics.writeBytes, stable_grow_calls: stableIoMetrics.growCalls,
    stable_grow_pages: stableIoMetrics.growPages))

proc bench_read_profile() {.query.} =
  ## Profile a cached prepared point-read without instrumenting normal queries.
  let rows = Request.new().getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  database.close()
  databaseReady = false
  useMetricsBackend = true
  defer:
    stableIoMetricsEnabled = false
    useMetricsBackend = false
    database.close()
    databaseReady = false
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  resetStableIoMetrics()
  stableIoMetricsEnabled = true
  let start = ic0_performance_counter(0'u32)
  var prepareInstructions = 0'u64
  var bindInstructions = 0'u64
  var stepInstructions = 0'u64
  var columnInstructions = 0'u64
  let read = database.withQuery(proc(conn: var Connection): Result[uint64, DbError] =
    let prepareStart = ic0_performance_counter(0'u32)
    let prepared = conn.prepare("SELECT value FROM bench WHERE key = ?")
    prepareInstructions = ic0_performance_counter(0'u32) - prepareStart
    if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
    var statement = prepared.value
    defer: statement.finalize()
    var checksum = 0'u64
    for index in 0'u32 ..< rows:
      let bindStart = ic0_performance_counter(0'u32)
      let bound = statement.bind(1, sqlText(benchKey(index)))
      bindInstructions += ic0_performance_counter(0'u32) - bindStart
      if not bound.isOk: return Result[uint64, DbError](isOk: false, error: bound.error)
      let stepStart = ic0_performance_counter(0'u32)
      let stepped = statement.step()
      stepInstructions += ic0_performance_counter(0'u32) - stepStart
      if not stepped.isOk: return Result[uint64, DbError](isOk: false, error: stepped.error)
      if stepped.value == srRow:
        let columnStart = ic0_performance_counter(0'u32)
        checksum += uint64(statement.columnBytes(0))
        columnInstructions += ic0_performance_counter(0'u32) - columnStart
      let resetStart = ic0_performance_counter(0'u32)
      let reset = statement.reset()
      bindInstructions += ic0_performance_counter(0'u32) - resetStart
      if not reset.isOk: return Result[uint64, DbError](isOk: false, error: reset.error)
    Result[uint64, DbError](isOk: true, value: checksum)
  )
  if not read.isOk: replyErr(read.error.message); return
  let stats = database.storageStats()
  replyOk(NimReadProfileReport(rows: uint64(rows),
    instructions: ic0_performance_counter(0'u32) - start, checksum: read.value,
    db_size: stats.dbSize, stable_pages: stats.sqliteVirtualPages,
    stable_bytes: stats.sqliteVirtualPages * bench_spec.StablePageSize,
    prepare: prepareInstructions, reset_bind: bindInstructions, step: stepInstructions,
    column_read: columnInstructions, stable_read_calls: stableIoMetrics.readCalls,
    stable_read_bytes: stableIoMetrics.readBytes))

proc bench_write_profile() {.update.} =
  ## Mirrors Rust's write profile: one transaction of deterministic upserts.
  let rows = Request.new().getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  database.close()
  databaseReady = false
  useMetricsBackend = true
  defer:
    stableIoMetricsEnabled = false
    useMetricsBackend = false
    database.close()
    databaseReady = false
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  resetStableIoMetrics()
  stableIoMetricsEnabled = true
  let start = ic0_performance_counter(0'u32)
  var openInstructions = 0'u64
  var prepareInstructions = 0'u64
  var formatInstructions = 0'u64
  var executeInstructions = 0'u64
  let written = database.withUpdate(proc(conn: var UpdateConnection): Result[uint64, DbError] =
    openInstructions = ic0_performance_counter(0'u32) - start
    let prepareStart = ic0_performance_counter(0'u32)
    let prepared = conn.prepare("INSERT INTO bench(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
    prepareInstructions = ic0_performance_counter(0'u32) - prepareStart
    if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
    var statement = prepared.value
    defer: statement.finalize()
    for index in 0'u32 ..< rows:
      let formatStart = ic0_performance_counter(0'u32)
      let key = prefixedKey('w', index)
      let value = updatedValue(index)
      formatInstructions += ic0_performance_counter(0'u32) - formatStart
      let executeStart = ic0_performance_counter(0'u32)
      let boundKey = statement.bind(1, sqlText(key))
      if not boundKey.isOk: return Result[uint64, DbError](isOk: false, error: boundKey.error)
      let boundValue = statement.bind(2, sqlText(value))
      if not boundValue.isOk: return Result[uint64, DbError](isOk: false, error: boundValue.error)
      let stepped = statement.step()
      executeInstructions += ic0_performance_counter(0'u32) - executeStart
      if not stepped.isOk: return Result[uint64, DbError](isOk: false, error: stepped.error)
      let reset = statement.reset()
      if not reset.isOk: return Result[uint64, DbError](isOk: false, error: reset.error)
    Result[uint64, DbError](isOk: true, value: uint64(rows))
  )
  if not written.isOk: replyErr(written.error.message); return
  let stats = database.storageStats()
  replyOk(NimWriteProfileReport(rows: uint64(rows),
    instructions: ic0_performance_counter(0'u32) - start, checksum: written.value,
    db_size: stats.dbSize, stable_pages: stats.sqliteVirtualPages,
    stable_bytes: stats.sqliteVirtualPages * bench_spec.StablePageSize,
    update_open: openInstructions, prepare: prepareInstructions,
    key_value_format: formatInstructions, execute_total: executeInstructions,
    stable_read_calls: stableIoMetrics.readCalls, stable_read_bytes: stableIoMetrics.readBytes,
    stable_write_calls: stableIoMetrics.writeCalls, stable_write_bytes: stableIoMetrics.writeBytes,
    stable_grow_calls: stableIoMetrics.growCalls, stable_grow_pages: stableIoMetrics.growPages))

proc bench_get_many_in_profile() {.query.} =
  let rows = Request.new().getNat32(0)
  if rows == 0 or rows > 999 or not validateFixedBenchKeyRows(rows):
    replyErr("multi-get rows must be between 1 and 999"); return
  database.close(); databaseReady = false; useMetricsBackend = true
  defer:
    stableIoMetricsEnabled = false; useMetricsBackend = false
    database.close(); databaseReady = false
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  resetStableIoMetrics(); stableIoMetricsEnabled = true
  let start = ic0_performance_counter(0'u32)
  let sqlStart = ic0_performance_counter(0'u32)
  var sql = "SELECT value FROM bench WHERE key IN ("
  for index in 0'u32 ..< rows:
    if index > 0: sql.add(",")
    sql.add("?")
  sql.add(") ORDER BY key")
  let sqlBuild = ic0_performance_counter(0'u32) - sqlStart
  var keyBuild = 0'u64
  var prepareInstructions = 0'u64
  var bindInstructions = 0'u64
  var rowScan = 0'u64
  let read = database.withQuery(proc(conn: var Connection): Result[uint64, DbError] =
    let prepareStart = ic0_performance_counter(0'u32)
    let prepared = conn.prepare(sql)
    prepareInstructions = ic0_performance_counter(0'u32) - prepareStart
    if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
    var statement = prepared.value
    defer: statement.finalize()
    for index in 0'u32 ..< rows:
      let keyStart = ic0_performance_counter(0'u32)
      let key = benchKey(index)
      keyBuild += ic0_performance_counter(0'u32) - keyStart
      let bindStart = ic0_performance_counter(0'u32)
      let bound = statement.bind(int(index) + 1, sqlText(key))
      bindInstructions += ic0_performance_counter(0'u32) - bindStart
      if not bound.isOk: return Result[uint64, DbError](isOk: false, error: bound.error)
    var checksum = 0'u64
    while true:
      let rowStart = ic0_performance_counter(0'u32)
      let stepped = statement.step()
      rowScan += ic0_performance_counter(0'u32) - rowStart
      if not stepped.isOk: return Result[uint64, DbError](isOk: false, error: stepped.error)
      if stepped.value == srDone: break
      checksum += uint64(statement.columnBytes(0))
    Result[uint64, DbError](isOk: true, value: checksum)
  )
  if not read.isOk: replyErr(read.error.message); return
  let stats = database.storageStats()
  replyOk(NimGetManyProfileReport(rows: uint64(rows),
    instructions: ic0_performance_counter(0'u32) - start, checksum: read.value,
    db_size: stats.dbSize, stable_pages: stats.sqliteVirtualPages,
    stable_bytes: stats.sqliteVirtualPages * bench_spec.StablePageSize,
    sql_build: sqlBuild, key_build: keyBuild, prepare: prepareInstructions,
    bind_total: bindInstructions, row_scan: rowScan,
    stable_read_calls: stableIoMetrics.readCalls, stable_read_bytes: stableIoMetrics.readBytes))

proc db_stats() {.query.} =
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let stats = database.storageStats()
  let pageSize = scalar("PRAGMA page_size")
  if not pageSize.isOk: replyErr(pageSize.error.message); return
  let pageCount = scalar("PRAGMA page_count")
  if not pageCount.isOk: replyErr(pageCount.error.message); return
  let freeCount = scalar("PRAGMA freelist_count")
  if not freeCount.isOk: replyErr(freeCount.error.message); return
  let cache = database.cacheStats()
  if not cache.isOk: replyErr(cache.error.message); return
  replyOk(DbStatsReport(db_size: stats.dbSize, stable_pages: stats.sqliteVirtualPages,
    stable_bytes: stats.sqliteVirtualPages * bench_spec.StablePageSize, sqlite_page_size: pageSize.value,
    sqlite_page_count: pageCount.value, sqlite_freelist_count: freeCount.value,
    sqlite_cache_used_bytes: cache.value.cacheUsedBytes))

proc bench_host_stats_internal(): HostStatsReport =
  let rawPages = newIcStableBackend().sizePages()
  HostStatsReport(raw_stable_pages: rawPages, raw_stable_bytes: rawPages * bench_spec.StablePageSize)

proc bench_host_stats() {.query.} =
  replyOk(bench_host_stats_internal())

when defined(benchmarkProfile):
  proc cleanCacheUpsert(rows: uint32; cycles: uint32): Result[uint64, DbError] =
    ## Re-applies deterministic upserts against the seeded `bench` table.
    ## Each call runs inside one withUpdate transaction, so the update
    ## overlay (and the optional clean page cache) are active for every page
    ## touched by the write.
    var steps = 0'u64
    for cycleIndex in 0 ..< cycles:
      discard cycleIndex
      let updated = database.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
        let prepared = conn.prepare("INSERT INTO bench(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
        var statement = prepared.value
        defer: statement.finalize()
        for index in 0'u32 ..< rows:
          let key = prefixedKey('w', index)
          let value = "cc-" & key
          let boundKey = statement.bind(1, sqlText(key))
          if not boundKey.isOk: return Result[bool, DbError](isOk: false, error: boundKey.error)
          let boundValue = statement.bind(2, sqlText(value))
          if not boundValue.isOk: return Result[bool, DbError](isOk: false, error: boundValue.error)
          let stepped = statement.step()
          if not stepped.isOk: return Result[bool, DbError](isOk: false, error: stepped.error)
          let resetResult = statement.reset()
          if not resetResult.isOk: return Result[bool, DbError](isOk: false, error: resetResult.error)
        Result[bool, DbError](isOk: true, value: true)
      )
      if not updated.isOk: return Result[uint64, DbError](isOk: false, error: updated.error)
      inc steps, uint64(rows)
    Result[uint64, DbError](isOk: true, value: steps)

  proc collectCleanCacheProfile(rows: uint32; cycles: uint32; start: uint64;
                                stableReads: var StableIoMetrics): Result[NimCleanCacheProfileReport, DbError] =
    ## Runs the clean-cache upsert workload while the counting backend and
    ## the -d:benchmarkProfile counters run, then samples db/host stats in a
    ## fixed order (counters -> db stats -> host) so the per-variant numbers
    ## stay comparable. `sqlite_cache_used_bytes` is the SQLite pager cache and
    ## is never summed into raw stable or heap totals.
    let upserted = cleanCacheUpsert(rows, cycles)
    if not upserted.isOk: return Result[NimCleanCacheProfileReport, DbError](isOk: false, error: upserted.error)
    let profile = database.profileStats()
    if not profile.isOk: return Result[NimCleanCacheProfileReport, DbError](isOk: false, error: profile.error)
    let stats = database.storageStats()
    let pageCount = scalar("PRAGMA page_count")
    if not pageCount.isOk: return Result[NimCleanCacheProfileReport, DbError](isOk: false, error: pageCount.error)
    let cache = database.cacheStats()
    if not cache.isOk: return Result[NimCleanCacheProfileReport, DbError](isOk: false, error: cache.error)
    result.isOk = true
    result.value = NimCleanCacheProfileReport(
      rows: uint64(rows), writes: upserted.value,
      instructions: ic0_performance_counter(0'u32) - start,
      checksum: upserted.value, clean_cache_pages: dbCleanCachePages,
      dirty_pages_current: profile.value.dirtyPagesCurrent,
      dirty_pages_peak: profile.value.dirtyPagesPeak,
      dirty_pages_new: profile.value.dirtyPageNew,
      dirty_pages_new_bytes: profile.value.dirtyPageNewBytes,
      clean_cache_hits: profile.value.cleanCacheHits,
      clean_cache_misses: profile.value.cleanCacheMisses,
      clean_cache_evictions: profile.value.cleanCacheEvictions,
      clean_cache_bytes: profile.value.cleanCacheReadBytes,
      temp_buffer_allocs: profile.value.tempBufferAllocs,
      temp_buffer_alloc_bytes: profile.value.tempBufferAllocBytes,
      vfs_read_calls: profile.value.vfsReadCalls,
      vfs_write_calls: profile.value.vfsWriteCalls,
      vfs_short_reads: profile.value.vfsShortReads,
      vfs_truncate_calls: profile.value.vfsTruncateCalls,
      stable_read_calls: stableReads.readCalls, stable_read_bytes: stableReads.readBytes,
      stable_write_calls: stableReads.writeCalls, stable_write_bytes: stableReads.writeBytes,
      stable_grow_calls: stableReads.growCalls, stable_grow_pages: stableReads.growPages,
      db_size: stats.dbSize, sqlite_virtual_pages: stats.sqliteVirtualPages,
      sqlite_page_count: pageCount.value, sqlite_cache_used_bytes: cache.value.cacheUsedBytes)
    # Fixed observation order (counters -> db stats -> host memory) so the
    # per-A/B numbers stay comparable. Heap bytes are derived host-side the
    # same way as the core runner: canister status memory_size minus raw
    # stable bytes. `sqlite_cache_used_bytes` is the SQLite pager cache and
    # must never be summed into stable or heap totals.
    let host = bench_host_stats_internal()
    result.value.raw_stable_pages = host.raw_stable_pages
    result.value.raw_stable_bytes = host.raw_stable_bytes

  proc bench_set_experiment() {.update.} =
    ## Toggles the optional query-connection reuse and statement cache
    ## experiments (both disabled by default) and re-initializes the
    ## database so the new config takes effect. Existing stable data is
    ## reopened; the cached reader is invalidated per the update rule.
    let reuse = Request.new().getNat32(0)
    let stmtCache = Request.new().getNat32(1)
    if reuse > 1'u32 or stmtCache > 1'u32: replyErr("flags must be 0..1"); return
    databaseReady = false
    database.close()
    useMetricsBackend = false
    dbQueryReuse = reuse == 1'u32
    dbStatementCache = stmtCache == 1'u32
    let failure = ensureDatabase()
    if failure.len > 0: replyErr(failure); return
    replyOk(NimCapacityGrowthReport(rows: 0, writes: 0, instructions: 0,
      checksum: uint64(reuse) * 2 + uint64(stmtCache), db_size_before: 0,
      db_size_after: 0, sqlite_virtual_pages_before: 0, sqlite_virtual_pages_after: 0,
      raw_stable_pages_before: 0, raw_stable_pages_after: 0,
      raw_stable_bytes_before: 0, raw_stable_bytes_after: 0))

  proc bench_set_clean_cache() {.update.} =
    ## Switches the experimental clean page cache size and re-initializes the
    ## database so the change takes effect. Existing stable data is reopened.
    let pages = Request.new().getNat32(0)
    if pages > 8'u32: replyErr("clean cache pages must be 0..8"); return
    databaseReady = false
    database.close()
    useMetricsBackend = false
    dbCleanCachePages = uint64(pages)
    let failure = ensureDatabase()
    if failure.len > 0: replyErr(failure); return
    replyOk(NimCapacityGrowthReport(rows: 0, writes: 0, instructions: 0,
      checksum: uint64(pages), db_size_before: 0, db_size_after: 0,
      sqlite_virtual_pages_before: 0, sqlite_virtual_pages_after: 0,
      raw_stable_pages_before: 0, raw_stable_pages_after: 0,
      raw_stable_bytes_before: 0, raw_stable_bytes_after: 0))

  ## VFS/core workload: allocation-free fixed-length key/value buffers from
  ## `bench_spec` (benchKeyBuffer / updatedValueBuffer), one prepared statement,
  ## `rows` step / reset cycles, and a read-back checksum, all in a single
  ## transaction. This is the isolated VFS/core comparison series, deliberately
  ## separate from the public API series that formats strings.
  proc bench_vfs_core_profile() {.update.} =
    let rows = Request.new().getNat32(0)
    if rows == 0 or not validateFixedBenchKeyRows(rows) or rows > 10_000'u32:
      replyErr("vfs core rows must be 1..10000"); return
    database.close()
    databaseReady = false
    useMetricsBackend = true
    defer:
      stableIoMetricsEnabled = false
      useMetricsBackend = false
      database.close()
      databaseReady = false
    let failure = ensureDatabase()
    if failure.len > 0: replyErr(failure); return
    resetStableIoMetrics()
    stableIoMetricsEnabled = true
    let start = ic0_performance_counter(0'u32)
    let updated = database.withUpdate(proc(conn: var UpdateConnection): Result[uint64, DbError] =
      let prepared = conn.prepare("INSERT INTO bench(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
      if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
      var statement = prepared.value
      defer: statement.finalize()
      for index in 0'u32 ..< rows:
        let keyBuffer = benchKeyBuffer(index)
        ## `updatedValueBuffer` differs from the seeded `benchValueBuffer`, so
        ## this is a real UPDATE that dirties pages for the overlay/dirty-store
        ## measurement (an identical-value upsert would be a no-op).
        let valueBuffer = updatedValueBuffer(index)
        # `benchKeyBuffer` / `updatedValueBuffer` already encode the digits
        # into a fixed-width array; converting to string here is a
        # single bounded copy (not a format pass), which isolates the
        # VFS/core I/O from the public API's format-then-copy path.
        var keyStr = newString(keyBuffer.len)
        for p in 0 .. keyBuffer.high: keyStr[p] = keyBuffer[p]
        var valueStr = newString(valueBuffer.len)
        for p in 0 .. valueBuffer.high: valueStr[p] = valueBuffer[p]
        let boundKey = statement.bind(1, sqlText(keyStr))
        if not boundKey.isOk: return Result[uint64, DbError](isOk: false, error: boundKey.error)
        let boundValue = statement.bind(2, sqlText(valueStr))
        if not boundValue.isOk: return Result[uint64, DbError](isOk: false, error: boundValue.error)
        let stepped = statement.step()
        if not stepped.isOk: return Result[uint64, DbError](isOk: false, error: stepped.error)
        let resetResult = statement.reset()
        if not resetResult.isOk: return Result[uint64, DbError](isOk: false, error: resetResult.error)
      ## Content-derived checksum read back through the same open transaction.
      let reread = withUpdateQueryRead(conn.transactionLease(),
        proc(rconn: var Connection): Result[uint64, DbError] =
          let prepared = rconn.prepare("SELECT value FROM bench WHERE key = ?")
          if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
          var rstmt = prepared.value
          defer: rstmt.finalize()
          var sum = 0'u64
          for index in 0'u32 ..< rows:
            let bound = rstmt.bind(1, sqlText(benchKey(index)))
            if not bound.isOk: return Result[uint64, DbError](isOk: false, error: bound.error)
            let stepped = rstmt.step()
            if not stepped.isOk: return Result[uint64, DbError](isOk: false, error: stepped.error)
            if stepped.value == srRow: sum += uint64(rstmt.columnBytes(0))
            let resetResult = rstmt.reset()
            if not resetResult.isOk: return Result[uint64, DbError](isOk: false, error: resetResult.error)
          Result[uint64, DbError](isOk: true, value: sum)
      )
      if not reread.isOk: return Result[uint64, DbError](isOk: false, error: reread.error)
      Result[uint64, DbError](isOk: true, value: reread.value)
    )
    if not updated.isOk: replyErr(updated.error.message); return
    let stats = database.storageStats()
    let pageCount = scalar("PRAGMA page_count")
    if not pageCount.isOk: replyErr(pageCount.error.message); return
    let cache = database.cacheStats()
    if not cache.isOk: replyErr(cache.error.message); return
    let host = bench_host_stats_internal()
    let profile = database.profileStats()
    replyOk(NimVfsCoreProfileReport(
      rows: uint64(rows), instructions: ic0_performance_counter(0'u32) - start,
      checksum: updated.value, clean_cache_pages: dbCleanCachePages,
      dirty_pages_current: profile.value.dirtyPagesCurrent,
      dirty_pages_peak: profile.value.dirtyPagesPeak,
      dirty_pages_new: profile.value.dirtyPageNew,
      dirty_pages_new_bytes: profile.value.dirtyPageNewBytes,
      clean_cache_hits: profile.value.cleanCacheHits,
      clean_cache_misses: profile.value.cleanCacheMisses,
      clean_cache_evictions: profile.value.cleanCacheEvictions,
      clean_cache_bytes: profile.value.cleanCacheReadBytes,
      temp_buffer_allocs: profile.value.tempBufferAllocs,
      temp_buffer_alloc_bytes: profile.value.tempBufferAllocBytes,
      vfs_read_calls: profile.value.vfsReadCalls,
      vfs_write_calls: profile.value.vfsWriteCalls,
      vfs_short_reads: profile.value.vfsShortReads,
      vfs_truncate_calls: profile.value.vfsTruncateCalls,
      stable_read_calls: stableIoMetrics.readCalls,
      stable_read_bytes: stableIoMetrics.readBytes,
      stable_write_calls: stableIoMetrics.writeCalls,
      stable_write_bytes: stableIoMetrics.writeBytes,
      stable_grow_calls: stableIoMetrics.growCalls,
      stable_grow_pages: stableIoMetrics.growPages,
      db_size: stats.dbSize, sqlite_virtual_pages: stats.sqliteVirtualPages,
      sqlite_page_count: pageCount.value,
      sqlite_cache_used_bytes: cache.value.cacheUsedBytes,
      raw_stable_pages: host.raw_stable_pages, raw_stable_bytes: host.raw_stable_bytes))

  proc bench_clean_cache_write_profile() {.update.} =
    ## Update-transaction upsert workload with the overlay/VFS/profile
    ## counters active. Runs with the current `dbCleanCachePages` setting so
    ## the host can compare 0 / 2 / 4 / 8 clean-cache pages back to back on
    ## the same canister and stable image.
    let request = Request.new()
    let rows = request.getNat32(0)
    let cycles = request.getNat32(1)
    if rows == 0 or cycles == 0 or not validateFixedBenchKeyRows(rows) or cycles > 100'u32:
      replyErr("clean cache rows/cycles must be 1..max; cycles <= 100"); return
    database.close()
    databaseReady = false
    useMetricsBackend = true
    defer:
      stableIoMetricsEnabled = false
      useMetricsBackend = false
      database.close()
      databaseReady = false
    let failure = ensureDatabase()
    if failure.len > 0: replyErr(failure); return
    resetStableIoMetrics()
    stableIoMetricsEnabled = true
    let start = ic0_performance_counter(0'u32)
    let profiled = collectCleanCacheProfile(rows, cycles, start, stableIoMetrics)
    if not profiled.isOk: replyErr(profiled.error.message); return
    replyOk(profiled.value)

when defined(benchmarkFailpoint):
  proc bench_failpoint_update() {.update.} =
    ## The first dirty page reaches stable memory, then the second write fails.
    ## finishStableOperation traps after publication has started, so the IC
    ## rolls back the entire update message, including that first page write.
    let rows = Request.new().getNat32(0)
    if rows < 2 or not validateFixedBenchKeyRows(rows):
      replyErr("invalid failpoint row count"); return
    let failure = ensureDatabase()
    if failure.len > 0: replyErr(failure); return
    failAfterStableWrites = 1
    let updated = insertRows("bench", 0, rows, "update")
    failAfterStableWrites = -1
    if not updated.isOk: replyErr(updated.error.message); return
    replyErr("failpoint did not reach a second stable write")

proc churnReport(cycle: uint32; phase: string; rows: uint32; start: uint64): Result[BenchChurnStepReport, DbError] =
  let pageSize = scalar("PRAGMA page_size")
  if not pageSize.isOk: return Result[BenchChurnStepReport, DbError](isOk: false, error: pageSize.error)
  let pageCount = scalar("PRAGMA page_count")
  if not pageCount.isOk: return Result[BenchChurnStepReport, DbError](isOk: false, error: pageCount.error)
  let freeCount = scalar("PRAGMA freelist_count")
  if not freeCount.isOk: return Result[BenchChurnStepReport, DbError](isOk: false, error: freeCount.error)
  let count = scalar("SELECT COUNT(*) FROM churn_bench")
  if not count.isOk: return Result[BenchChurnStepReport, DbError](isOk: false, error: count.error)
  let storage = database.storageStats()
  Result[BenchChurnStepReport, DbError](isOk: true, value: BenchChurnStepReport(
    cycle: uint64(cycle), phase: phase, rows: uint64(rows),
    instructions: ic0_performance_counter(0'u32) - start, row_count: count.value,
    db_size: storage.dbSize, stable_pages: storage.sqliteVirtualPages,
    stable_bytes: storage.sqliteVirtualPages * bench_spec.StablePageSize,
    sqlite_page_size: pageSize.value, sqlite_page_count: pageCount.value,
    sqlite_freelist_count: freeCount.value))

proc bench_churn_reset() {.update.} =
  let rows = Request.new().getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let start = ic0_performance_counter(0'u32)
  let inserted = insertRows("churn_bench", 0, rows, "insert", resetTable = true)
  if not inserted.isOk: replyErr(inserted.error.message); return
  let observed = churnReport(0, "reset", rows, start)
  if not observed.isOk: replyErr(observed.error.message); return
  replyOk(observed.value)

proc churnStep(operation: string) =
  let request = Request.new()
  let startIndex = request.getNat32(0)
  let rows = request.getNat32(1)
  let cycle = request.getNat32(2)
  if rows == 0 or not validateFixedBenchKeyRange(startIndex, rows):
    replyErr("invalid churn range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let start = ic0_performance_counter(0'u32)
  let written = insertRows("churn_bench", startIndex, rows, operation)
  if not written.isOk: replyErr(written.error.message); return
  let observed = churnReport(cycle, operation, rows, start)
  if not observed.isOk: replyErr(observed.error.message); return
  replyOk(observed.value)

proc bench_churn_delete() {.update.} = churnStep("delete")
proc bench_churn_insert() {.update.} = churnStep("insert")

proc churnStepBorrowed(operation: string) =
  let request = Request.new()
  let startIndex = request.getNat32(0)
  let rows = request.getNat32(1)
  let cycle = request.getNat32(2)
  if rows == 0 or not validateFixedBenchKeyRange(startIndex, rows):
    replyErr("invalid churn range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let start = ic0_performance_counter(0'u32)
  let written = insertRowsBorrowed("churn_bench", startIndex, rows, operation)
  if not written.isOk: replyErr(written.error.message); return
  let observed = churnReport(cycle, operation, rows, start)
  if not observed.isOk: replyErr(observed.error.message); return
  replyOk(observed.value)

proc bench_churn_reset_borrowed() {.update.} =
  let rows = Request.new().getNat32(0)
  if not validateFixedBenchKeyRows(rows): replyErr("rows exceeds fixed key range"); return
  let failure = ensureDatabase()
  if failure.len > 0: replyErr(failure); return
  let start = ic0_performance_counter(0'u32)
  let inserted = insertRowsBorrowed("churn_bench", 0, rows, "insert", resetTable = true)
  if not inserted.isOk: replyErr(inserted.error.message); return
  let observed = churnReport(0, "reset", rows, start)
  if not observed.isOk: replyErr(observed.error.message); return
  replyOk(observed.value)

proc bench_churn_delete_borrowed() {.update.} = churnStepBorrowed("delete")
proc bench_churn_insert_borrowed() {.update.} = churnStepBorrowed("insert")
