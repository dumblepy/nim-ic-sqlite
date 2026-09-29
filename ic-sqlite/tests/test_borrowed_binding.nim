## Tests for internal-only borrowed (SQLITE_STATIC) binding helpers.
##
## These helpers are NOT part of the public API. The caller MUST guarantee
## pointer validity until reset/clear_bindings/finalize, and MUST call reset
## on every path (success, error, early return).
import std/[options, unittest]
import ic_sqlite
import ic_sqlite/db
import ../benchmarks/comparison/shared/bench_spec

suite "borrowed (SQLITE_STATIC) binding":
  test "bindStaticText inserts and reads back correctly":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE t (k INTEGER PRIMARY KEY, v TEXT NOT NULL)").isOk
    let inserted = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let prepared = conn.prepare("INSERT INTO t(k, v) VALUES (?, ?)")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      let boundK = stmt.bind(1, sqlInt(1))
      if not boundK.isOk: return Result[bool, DbError](isOk: false, error: boundK.error)
      let textVal = "hello borrowed"
      let boundV = stmt.bindStaticText(2, textVal.cstring, textVal.len)
      if not boundV.isOk: return Result[bool, DbError](isOk: false, error: boundV.error)
      let stepped = stmt.step()
      if not stepped.isOk: return Result[bool, DbError](isOk: false, error: stepped.error)
      let resetResult = stmt.reset()
      if not resetResult.isOk: return Result[bool, DbError](isOk: false, error: resetResult.error)
      Result[bool, DbError](isOk: true, value: true)
    )
    check inserted.isOk
    let read = db.queryOneText("SELECT v FROM t WHERE k = 1", [])
    check read.isOk
    check read.value.isSome
    check read.value.get == "hello borrowed"
    db.close()

  test "bindStaticBlob inserts and reads back correctly":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE t (k INTEGER PRIMARY KEY, v BLOB NOT NULL)").isOk
    let inserted = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let prepared = conn.prepare("INSERT INTO t(k, v) VALUES (?, ?)")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      let boundK = stmt.bind(1, sqlInt(1))
      if not boundK.isOk: return Result[bool, DbError](isOk: false, error: boundK.error)
      var blobData = @[0xde'u8, 0xad, 0xbe, 0xef]
      let boundV = stmt.bindStaticBlob(2, addr blobData[0], blobData.len)
      if not boundV.isOk: return Result[bool, DbError](isOk: false, error: boundV.error)
      let stepped = stmt.step()
      if not stepped.isOk: return Result[bool, DbError](isOk: false, error: stepped.error)
      let resetResult = stmt.reset()
      if not resetResult.isOk: return Result[bool, DbError](isOk: false, error: resetResult.error)
      Result[bool, DbError](isOk: true, value: true)
    )
    check inserted.isOk
    let read = db.withQuery(proc(conn: var Connection): Result[bool, DbError] =
      let prepared = conn.prepare("SELECT v FROM t WHERE k = 1")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      let stepped = stmt.step()
      if not stepped.isOk: return Result[bool, DbError](isOk: false, error: stepped.error)
      if stepped.value != srRow: return Result[bool, DbError](isOk: false, error: DbError(message: "no row"))
      let blobLen = stmt.columnBytes(0)
      check blobLen == 4
      let blobData = stmt.columnBlob(0)
      check blobData == @[0xde'u8, 0xad, 0xbe, 0xef]
      Result[bool, DbError](isOk: true, value: true)
    )
    check read.isOk
    db.close()

  test "bindStaticText with reset on error path":
    ## Verify that reset is safe after a failed bindStaticText call.
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE t (k INTEGER PRIMARY KEY, v TEXT NOT NULL)").isOk
    let result = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let prepared = conn.prepare("INSERT INTO t(k, v) VALUES (?, ?)")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      # Bind with index 0 (invalid) to trigger error
      let bound = stmt.bindStaticText(0, "test".cstring, 4)
      if bound.isOk:
        # Should not reach here, but reset anyway for safety
        discard stmt.reset()
        return Result[bool, DbError](isOk: false, error: DbError(message: "expected error"))
      # Reset is safe even after a failed bind
      let resetResult = stmt.reset()
      if not resetResult.isOk: return Result[bool, DbError](isOk: false, error: resetResult.error)
      Result[bool, DbError](isOk: true, value: true)
    )
    check result.isOk
    db.close()

  test "bindStaticText with reset on early return":
    ## Verify that reset is called on early return after a successful bind.
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE t (k INTEGER PRIMARY KEY, v TEXT NOT NULL)").isOk
    let result = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let prepared = conn.prepare("INSERT INTO t(k, v) VALUES (?, ?)")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      let boundK = stmt.bind(1, sqlInt(1))
      if not boundK.isOk: return Result[bool, DbError](isOk: false, error: boundK.error)
      let textVal = "early return test"
      let boundV = stmt.bindStaticText(2, textVal.cstring, textVal.len)
      if not boundV.isOk: return Result[bool, DbError](isOk: false, error: boundV.error)
      # Early return: must reset before returning
      let resetResult = stmt.reset()
      if not resetResult.isOk: return Result[bool, DbError](isOk: false, error: resetResult.error)
      Result[bool, DbError](isOk: true, value: true)
    )
    check result.isOk
    db.close()

  test "bindStaticText multiple rows in a loop":
    ## Verify that bindStaticText works correctly in a step/reset loop.
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE t (k INTEGER PRIMARY KEY, v TEXT NOT NULL)").isOk
    let inserted = db.withUpdate(proc(conn: var UpdateConnection): Result[uint64, DbError] =
      let prepared = conn.prepare("INSERT INTO t(k, v) VALUES (?, ?)")
      if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      for i in 1 .. 10:
        let boundK = stmt.bind(1, sqlInt(i))
        if not boundK.isOk: return Result[uint64, DbError](isOk: false, error: boundK.error)
        let textVal = "row-" & $i
        let boundV = stmt.bindStaticText(2, textVal.cstring, textVal.len)
        if not boundV.isOk: return Result[uint64, DbError](isOk: false, error: boundV.error)
        let stepped = stmt.step()
        if not stepped.isOk: return Result[uint64, DbError](isOk: false, error: stepped.error)
        let resetResult = stmt.reset()
        if not resetResult.isOk: return Result[uint64, DbError](isOk: false, error: resetResult.error)
      Result[uint64, DbError](isOk: true, value: 10'u64)
    )
    check inserted.isOk
    check inserted.value == 10
    let count = db.withQuery(proc(conn: var Connection): Result[uint64, DbError] =
      let prepared = conn.prepare("SELECT COUNT(*) FROM t")
      if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      let stepped = stmt.step()
      if not stepped.isOk: return Result[uint64, DbError](isOk: false, error: stepped.error)
      if stepped.value != srRow: return Result[uint64, DbError](isOk: false, error: DbError(message: "no row"))
      Result[uint64, DbError](isOk: true, value: uint64(stmt.columnInt64(0)))
    )
    check count.isOk
    check count.value == 10
    db.close()

  test "executeTextTextBorrowed updates from fixed-length buffers":
    ## A2 path: exactly the benchmark update SQL with stack/array inputs.
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec(BenchSchemaSql).isOk
    check db.execText("INSERT INTO bench(key, value) VALUES (?, ?)",
      ["k00000000", "seed"]).isOk
    let updated = db.withUpdate(proc(conn: var UpdateConnection): Result[uint64, DbError] =
      let prepared = conn.prepare("UPDATE bench SET value = ? WHERE key = ?")
      if not prepared.isOk: return Result[uint64, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      var executed = 0'u64
      for i in 0'u32 ..< 3'u32:
        let valueBuffer = updatedValueBuffer(i)
        let keyBuffer = benchKeyBuffer(i)
        let result = stmt.executeTextTextBorrowed(valueBuffer, keyBuffer)
        if not result.isOk: return Result[uint64, DbError](isOk: false, error: result.error)
        executed += 1
      Result[uint64, DbError](isOk: true, value: executed)
    )
    check updated.isOk
    check updated.value == 3
    let read = db.queryOneText("SELECT value FROM bench WHERE key = ?", ["k00000000"])
    check read.isOk
    check read.value.isSome
    check read.value.get == updatedValue(0)
    db.close()

  test "executeTextTextBorrowed clears bindings on the constraint error path":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE u (k INTEGER PRIMARY KEY, v TEXT NOT NULL UNIQUE)").isOk
    check db.execText("INSERT INTO u(k, v) VALUES (?, ?)", ["1", "dup"]).isOk
    let result = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let prepared = conn.prepare("INSERT INTO u(k, v) VALUES (?, ?)")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      # First row violates the UNIQUE constraint.
      let failed = stmt.executeTextTextBorrowed("2", "dup")
      if failed.isOk:
        return Result[bool, DbError](isOk: false, error: DbError(message: "expected constraint error"))
      # A later call must succeed: bindings were cleared, no stale pointer.
      let recovered = stmt.executeTextTextBorrowed("3", "fresh")
      if not recovered.isOk: return Result[bool, DbError](isOk: false, error: recovered.error)
      Result[bool, DbError](isOk: true, value: true)
    )
    check result.isOk
    let fresh = db.queryOneText("SELECT v FROM u WHERE k = ?", ["3"])
    check fresh.isOk and fresh.value.isSome and fresh.value.get == "fresh"
    db.close()

  test "executeTextTextBorrowed rejects statements with other parameter counts":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE p (k INTEGER PRIMARY KEY, v TEXT)").isOk
    let result = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let prepared = conn.prepare("INSERT INTO p(k) VALUES (?)")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      let rejected = stmt.executeTextTextBorrowed("only-one", "")
      if rejected.isOk:
        return Result[bool, DbError](isOk: false, error: DbError(message: "expected parameter count error"))
      Result[bool, DbError](isOk: true, value: true)
    )
    check result.isOk
    db.close()

  test "executeTextTextBorrowed handles empty texts":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE e (k INTEGER PRIMARY KEY, a TEXT NOT NULL, b TEXT NOT NULL)").isOk
    let result = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let prepared = conn.prepare("INSERT INTO e(k, a, b) VALUES (1, ?, ?)")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      let empty = newSeq[char](0)
      let inserted = stmt.executeTextTextBorrowed(empty, empty)
      if not inserted.isOk: return Result[bool, DbError](isOk: false, error: inserted.error)
      Result[bool, DbError](isOk: true, value: true)
    )
    check result.isOk
    let row = db.queryOneText("SELECT a || '|' || b FROM e WHERE k = 1", [])
    check row.isOk and row.value.isSome and row.value.get == "|"
    db.close()

  test "executeBorrowed binds mixed types with N parameters":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE m (id INTEGER PRIMARY KEY, t TEXT NOT NULL, b BLOB NOT NULL, n TEXT, f REAL NOT NULL)").isOk
    let inserted = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let prepared = conn.prepare("INSERT INTO m(id, t, b, n, f) VALUES (?, ?, ?, ?, ?)")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      var blob = @[byte 0xDE, 0xAD, 0xBE, 0xEF]
      let values = [sqlInt(7), sqlText("mixed"), sqlBlob(blob), sqlNull(), sqlFloat(1.5)]
      let executed = stmt.executeBorrowed(values)
      if not executed.isOk: return Result[bool, DbError](isOk: false, error: executed.error)
      Result[bool, DbError](isOk: true, value: true)
    )
    check inserted.isOk
    let read = db.withQuery(proc(conn: var Connection): Result[bool, DbError] =
      let prepared = conn.prepare("SELECT id, t, b, n, f FROM m WHERE id = 7")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      let stepped = stmt.step()
      if not stepped.isOk or stepped.value != srRow:
        return Result[bool, DbError](isOk: false, error: DbError(message: "row missing"))
      check stmt.columnInt64(0) == 7
      check stmt.columnText(1) == "mixed"
      check stmt.columnBlob(2) == @[byte 0xDE, 0xAD, 0xBE, 0xEF]
      check stmt.columnIsNull(3)
      check stmt.columnFloat64(4) == 1.5
      Result[bool, DbError](isOk: true, value: true)
    )
    check read.isOk
    db.close()

  test "executeBorrowed clears bindings on constraint errors and empty blobs":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE b (k INTEGER PRIMARY KEY, v TEXT NOT NULL UNIQUE, data BLOB NOT NULL)").isOk
    check db.execText("INSERT INTO b(k, v, data) VALUES (?, ?, ?)", ["0", "dup", ""]).isOk
    let result = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let prepared = conn.prepare("INSERT INTO b(k, v, data) VALUES (?, ?, ?)")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      let empty = newSeq[byte](0)
      let failed = stmt.executeBorrowed([sqlInt(1), sqlText("dup"), sqlBlob(empty)])
      if failed.isOk:
        return Result[bool, DbError](isOk: false, error: DbError(message: "expected constraint error"))
      # Bindings were cleared; a fresh call must succeed.
      let recovered = stmt.executeBorrowed([sqlInt(2), sqlText("fresh"), sqlBlob(empty)])
      if not recovered.isOk: return Result[bool, DbError](isOk: false, error: recovered.error)
      Result[bool, DbError](isOk: true, value: true)
    )
    check result.isOk
    let count = db.withQuery(proc(conn: var Connection): Result[int64, DbError] =
      let prepared = conn.prepare("SELECT COUNT(*) FROM b")
      if not prepared.isOk: return Result[int64, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      discard stmt.step()
      Result[int64, DbError](isOk: true, value: stmt.columnInt64(0))
    )
    check count.isOk and count.value == 2
    db.close()

  test "executeBorrowed rejects row statements and parameter mismatches":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE r (k INTEGER PRIMARY KEY)").isOk
    let result = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let prepared = conn.prepare("INSERT INTO r(k) VALUES (?)")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      let mismatch = stmt.executeBorrowed([sqlInt(1), sqlInt(2)])
      if mismatch.isOk:
        return Result[bool, DbError](isOk: false, error: DbError(message: "expected parameter mismatch"))
      Result[bool, DbError](isOk: true, value: true)
    )
    check result.isOk
    let select = db.withQuery(proc(conn: var Connection): Result[bool, DbError] =
      let prepared = conn.prepare("SELECT 1")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      let rejected = stmt.executeBorrowed([])
      if rejected.isOk:
        return Result[bool, DbError](isOk: false, error: DbError(message: "expected row-statement rejection"))
      Result[bool, DbError](isOk: true, value: true)
    )
    check select.isOk
    db.close()

  test "empty blob binds as a zero-length blob, not NULL":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE z (k INTEGER PRIMARY KEY, b BLOB NOT NULL)").isOk
    let inserted = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let prepared = conn.prepare("INSERT INTO z(k, b) VALUES (?, ?)")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      let empty = newSeq[byte](0)
      let boundK = stmt.bind(1, sqlInt(1))
      if not boundK.isOk: return Result[bool, DbError](isOk: false, error: boundK.error)
      let boundB = stmt.bind(2, sqlBlob(empty))
      if not boundB.isOk: return Result[bool, DbError](isOk: false, error: boundB.error)
      let stepped = stmt.step()
      if not stepped.isOk: return Result[bool, DbError](isOk: false, error: stepped.error)
      let resetResult = stmt.reset()
      if not resetResult.isOk: return Result[bool, DbError](isOk: false, error: resetResult.error)
      Result[bool, DbError](isOk: true, value: true)
    )
    check inserted.isOk
    let checkRow = db.withQuery(proc(conn: var Connection): Result[bool, DbError] =
      let prepared = conn.prepare("SELECT b IS NULL, length(b) FROM z WHERE k = 1")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      let stepped = stmt.step()
      if not stepped.isOk or stepped.value != srRow:
        return Result[bool, DbError](isOk: false, error: DbError(message: "row missing"))
      check stmt.columnInt64(0) == 0
      check stmt.columnInt64(1) == 0
      Result[bool, DbError](isOk: true, value: true)
    )
    check checkRow.isOk
    db.close()