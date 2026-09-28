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
  BenchChurnStepReport = object
    cycle, rows, instructions, row_count, db_size, stable_pages, stable_bytes: uint64
    sqlite_page_size, sqlite_page_count, sqlite_freelist_count: uint64
    phase: string
  HostStatsReport = object
    raw_stable_pages, raw_stable_bytes: uint64

var database: Db
var databaseReady = false

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
  when defined(benchmarkFailpoint):
    let opened = database.init(newFaultInjectingBackend())
  else:
    let opened = database.init(newIcStableBackend())
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
      let inserted = conn.execValues("INSERT INTO growth_bench(key, value) VALUES (?, ?)", [sqlText(prefixedKey('g', index)), sqlText("seed-" & $index)])
      if not inserted.isOk: return Result[bool, DbError](isOk: false, error: inserted.error)
    Result[bool, DbError](isOk: true, value: true)
  )
  if not seeded.isOk: replyErr(seeded.error.message); return
  let start = ic0_performance_counter(0'u32)
  for index in 0'u32 ..< writes:
    let updated = database.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let result = conn.execValues("UPDATE growth_bench SET value = ? WHERE key = ?",
        [sqlText("write-" & $index), sqlText(prefixedKey('g', index mod rows))])
      if not result.isOk: return Result[bool, DbError](isOk: false, error: result.error)
      if conn.changes() != 1: return Result[bool, DbError](isOk: false, error: DbError(message: "growth row missing"))
      Result[bool, DbError](isOk: true, value: true)
    )
    if not updated.isOk: replyErr(updated.error.message); return
  replyOk(report(rows, start, uint64(writes)))

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
  replyOk(DbStatsReport(db_size: stats.dbSize, stable_pages: stats.sqliteVirtualPages,
    stable_bytes: stats.sqliteVirtualPages * bench_spec.StablePageSize, sqlite_page_size: pageSize.value,
    sqlite_page_count: pageCount.value, sqlite_freelist_count: freeCount.value))

proc bench_host_stats() {.query.} =
  let rawPages = newIcStableBackend().sizePages()
  replyOk(HostStatsReport(raw_stable_pages: rawPages, raw_stable_bytes: rawPages * bench_spec.StablePageSize))

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
