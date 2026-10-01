## Tests for the opt-in update-connection statement cache (PR-6).
##
## The cache reuses prepared statements on the persistent write connection
## across update messages. It is disabled by default; these tests enable it and
## check reuse, lease-escape rejection, error eviction and schema changes.
import std/[options, unittest]
import ic_sqlite
import ic_sqlite/db

proc cachedConfig(): DbConfig =
  result = defaultDbConfig()
  result.statementCacheEnabled = true

suite "update statement cache":
  test "reuses a cached update statement across transactions":
    var db: Db
    check db.initMemoryForTest(cachedConfig()).isOk
    check db.exec("CREATE TABLE t (k INTEGER PRIMARY KEY, v TEXT NOT NULL)").isOk
    for round in 1 .. 3:
      let inserted = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
        let prepared = conn.prepare("INSERT INTO t(k, v) VALUES (?, ?)")
        if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
        var stmt = prepared.value
        defer: stmt.finalize()
        let boundK = stmt.bind(1, sqlInt(int64(round)))
        if not boundK.isOk: return Result[bool, DbError](isOk: false, error: boundK.error)
        let boundV = stmt.bind(2, sqlText("v" & $round))
        if not boundV.isOk: return Result[bool, DbError](isOk: false, error: boundV.error)
        let stepped = stmt.step()
        if not stepped.isOk: return Result[bool, DbError](isOk: false, error: stepped.error)
        Result[bool, DbError](isOk: true, value: true)
      )
      check inserted.isOk
    let stats = db.statementCacheStats()
    # One miss (first prepare) then hits for the reused prepared statement.
    check stats.misses == 1
    check stats.hits == 2
    let count = db.queryOneText("SELECT CAST(COUNT(*) AS TEXT) FROM t", [])
    check count.isOk and count.value.isSome and count.value.get == "3"
    db.close()

  test "a cached update handle is rejected after its lease ends":
    var db: Db
    check db.initMemoryForTest(cachedConfig()).isOk
    check db.exec("CREATE TABLE t (k INTEGER PRIMARY KEY, v TEXT NOT NULL)").isOk
    var leaked: Statement
    let result = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let prepared = conn.prepare("INSERT INTO t(k, v) VALUES (?, ?)")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      leaked = prepared.value
      let boundK = leaked.bind(1, sqlInt(1))
      if not boundK.isOk: return Result[bool, DbError](isOk: false, error: boundK.error)
      let boundV = leaked.bind(2, sqlText("x"))
      if not boundV.isOk: return Result[bool, DbError](isOk: false, error: boundV.error)
      let stepped = leaked.step()
      if not stepped.isOk: return Result[bool, DbError](isOk: false, error: stepped.error)
      Result[bool, DbError](isOk: true, value: true)
    )
    check result.isOk
    # The transaction has ended: the leaked cached handle must not execute.
    let afterLease = leaked.step()
    check not afterLease.isOk
    let rebind = leaked.bind(1, sqlInt(2))
    check not rebind.isOk
    leaked.finalize()
    db.close()

  test "evicts a cached statement after a SQLite error":
    var db: Db
    check db.initMemoryForTest(cachedConfig()).isOk
    check db.exec("CREATE TABLE u (k INTEGER PRIMARY KEY, v TEXT NOT NULL UNIQUE)").isOk
    check db.execText("INSERT INTO u(k, v) VALUES (?, ?)", ["1", "dup"]).isOk
    # First transaction: the cached INSERT hits a UNIQUE violation and must be
    # evicted, then a valid row is inserted.
    let first = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let prepared = conn.prepare("INSERT INTO u(k, v) VALUES (?, ?)")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      let failed = stmt.executeTextTextBorrowed("2", "dup")
      if failed.isOk:
        return Result[bool, DbError](isOk: false, error: DbError(message: "expected constraint error"))
      let recovered = stmt.executeTextTextBorrowed("3", "fresh")
      if not recovered.isOk: return Result[bool, DbError](isOk: false, error: recovered.error)
      Result[bool, DbError](isOk: true, value: true)
    )
    check first.isOk
    let missesAfterError = db.statementCacheStats().misses
    # Second transaction: the evicted entry is prepared again (a new miss).
    let second = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let prepared = conn.prepare("INSERT INTO u(k, v) VALUES (?, ?)")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      let inserted = stmt.executeTextTextBorrowed("4", "more")
      if not inserted.isOk: return Result[bool, DbError](isOk: false, error: inserted.error)
      Result[bool, DbError](isOk: true, value: true)
    )
    check second.isOk
    check db.statementCacheStats().misses == missesAfterError + 1
    let count = db.queryOneText("SELECT CAST(COUNT(*) AS TEXT) FROM u", [])
    check count.isOk and count.value.isSome and count.value.get == "3"
    db.close()

  test "a cached statement survives a schema-compatible change":
    var db: Db
    check db.initMemoryForTest(cachedConfig()).isOk
    check db.exec("CREATE TABLE s (k INTEGER PRIMARY KEY, v TEXT NOT NULL)").isOk
    let first = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let prepared = conn.prepare("INSERT INTO s(k, v) VALUES (?, ?)")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      let inserted = stmt.executeTextTextBorrowed("1", "a")
      if not inserted.isOk: return Result[bool, DbError](isOk: false, error: inserted.error)
      Result[bool, DbError](isOk: true, value: true)
    )
    check first.isOk
    # A schema-compatible DDL (add a nullable column) must not break reuse.
    check db.exec("ALTER TABLE s ADD COLUMN extra TEXT").isOk
    let second = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let prepared = conn.prepare("INSERT INTO s(k, v) VALUES (?, ?)")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var stmt = prepared.value
      defer: stmt.finalize()
      let inserted = stmt.executeTextTextBorrowed("2", "b")
      if not inserted.isOk: return Result[bool, DbError](isOk: false, error: inserted.error)
      Result[bool, DbError](isOk: true, value: true)
    )
    check second.isOk
    let count = db.queryOneText("SELECT CAST(COUNT(*) AS TEXT) FROM s", [])
    check count.isOk and count.value.isSome and count.value.get == "2"
    db.close()

  test "the cache is disabled by default":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE d (k INTEGER PRIMARY KEY)").isOk
    for round in 1 .. 2:
      discard db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
        let prepared = conn.prepare("INSERT INTO d(k) VALUES (?)")
        if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
        var stmt = prepared.value
        defer: stmt.finalize()
        let bound = stmt.bind(1, sqlInt(int64(round)))
        if not bound.isOk: return Result[bool, DbError](isOk: false, error: bound.error)
        let stepped = stmt.step()
        if not stepped.isOk: return Result[bool, DbError](isOk: false, error: stepped.error)
        Result[bool, DbError](isOk: true, value: true)
      )
    check db.statementCacheStats().hits == 0
    check db.statementCacheStats().misses == 0
    db.close()