## Tests for internal-only borrowed (SQLITE_STATIC) binding helpers.
##
## These helpers are NOT part of the public API. The caller MUST guarantee
## pointer validity until reset/clear_bindings/finalize, and MUST call reset
## on every path (success, error, early return).
import std/[options, unittest]
import ic_sqlite
import ic_sqlite/db

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