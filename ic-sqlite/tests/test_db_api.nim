import std/[options, unittest]
import ic_sqlite
import ic_sqlite/stable/superblock

suite "Db facade API":
  test "executes a SELECT through the high-level API":
    var db: Db
    check db.initMemoryForTest().isOk
    let result = db.exec("SELECT 1")
    check result.isOk
    check result.value == 0
    db.close()

  test "creates and reads parameterized text values":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)").isOk
    let inserted = db.execText("INSERT INTO kv(key, value) VALUES (?, ?)", ["greeting", "hello"])
    check inserted.isOk
    check inserted.value == 1
    let selected = db.queryOneText("SELECT value FROM kv WHERE key = ?", ["greeting"])
    check selected.isOk
    check selected.value.isSome
    check selected.value.get == "hello"
    let updated = db.execText("UPDATE kv SET value = ? WHERE key = ?", ["bonjour", "greeting"])
    check updated.isOk
    check updated.value == 1
    let afterUpdate = db.queryOneText("SELECT value FROM kv WHERE key = ?", ["greeting"])
    check afterUpdate.isOk
    check afterUpdate.value.get == "bonjour"
    let deleted = db.execText("DELETE FROM kv WHERE key = ?", ["greeting"])
    check deleted.isOk
    check deleted.value == 1
    let afterDelete = db.queryOneText("SELECT value FROM kv WHERE key = ?", ["greeting"])
    check afterDelete.isOk
    check afterDelete.value.isNone
    let missing = db.queryOneText("SELECT value FROM kv WHERE key = ?", ["missing"])
    check missing.isOk
    check missing.value.isNone
    db.close()

  test "withUpdate rolls back when its synchronous body returns an error":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)").isOk
    let failed = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let inserted = conn.execText("INSERT INTO kv(key, value) VALUES (?, ?)", ["rollback", "value"])
      if not inserted.isOk: return Result[bool, DbError](isOk: false, error: inserted.error)
      Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "intentional rollback"))
    )
    check not failed.isOk
    let absent = db.queryOneText("SELECT value FROM kv WHERE key = ?", ["rollback"])
    check absent.isOk
    check absent.value.isNone
    db.close()

  test "withUpdate commits all work after a successful body":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL)").isOk
    let committed = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let inserted = conn.execText("INSERT INTO kv(key, value) VALUES (?, ?)", ["commit", "value"])
      if not inserted.isOk: return Result[bool, DbError](isOk: false, error: inserted.error)
      Result[bool, DbError](isOk: true, value: true)
    )
    check committed.isOk
    let present = db.queryOneText("SELECT value FROM kv WHERE key = ?", ["commit"])
    check present.isOk
    check present.value.get == "value"
    db.close()

  test "rejects SQL and bound values beyond configured limits":
    var config = defaultDbConfig()
    config.maxSqlBytes = 8
    config.maxBlobBytes = 3
    var db: Db
    check db.initMemoryForTest(config).isOk
    let longSql = db.exec("SELECT 123")
    check not longSql.isOk
    let bound = db.execText("SELECT ?", ["four"])
    check not bound.isOk
    db.close()

  test "uses typed statements through a synchronous query connection":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE values_test (n INTEGER, f REAL, t TEXT, b BLOB)").isOk
    let inserted = db.exec("INSERT INTO values_test VALUES (7, 1.5, 'hello', x'0102')")
    check inserted.isOk
    let queried = db.withQuery(proc(conn: var Connection): Result[bool, DbError] =
      let prepared = conn.prepare("SELECT n, f, t, b FROM values_test WHERE n = ?")
      if not prepared.isOk:
        return Result[bool, DbError](isOk: false, error: prepared.error)
      var statement = prepared.value
      defer: statement.finalize()
      let bound = statement.bind(1, sqlInt(7))
      if not bound.isOk:
        return Result[bool, DbError](isOk: false, error: bound.error)
      let stepped = statement.step()
      if not stepped.isOk:
        return Result[bool, DbError](isOk: false, error: stepped.error)
      if stepped.value != srRow:
        return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "row missing"))
      check statement.columnInt64(0) == 7
      check statement.columnFloat64(1) == 1.5
      check statement.columnText(2) == "hello"
      check statement.columnBlob(3) == @[byte 1, 2]
      Result[bool, DbError](isOk: true, value: true)
    )
    check queried.isOk
    db.close()

  test "rejects writes from a query connection":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE query_only_test (value TEXT)").isOk
    let attemptedWrite = db.withQuery(proc(conn: var Connection): Result[bool, DbError] =
      let prepared = conn.prepare("INSERT INTO query_only_test(value) VALUES ('must fail')")
      if not prepared.isOk:
        return Result[bool, DbError](isOk: false, error: prepared.error)
      var statement = prepared.value
      defer: statement.finalize()
      let stepped = statement.step()
      if stepped.isOk:
        return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "query write unexpectedly succeeded"))
      Result[bool, DbError](isOk: true, value: true)
    )
    check attemptedWrite.isOk
    check db.queryOneText("SELECT value FROM query_only_test", []).value.isNone
    db.close()

  test "applies ordered trusted migrations once":
    var db: Db
    check db.initMemoryForTest().isOk
    let migrations = [
      Migration(version: 1, sql: "CREATE TABLE migrated (value TEXT NOT NULL)"),
      Migration(version: 2, sql: "INSERT INTO migrated(value) VALUES ('applied once')")
    ]
    check db.migrate(migrations).isOk
    check db.migrate(migrations).isOk
    let value = db.queryOneText("SELECT value FROM migrated", [])
    check value.isOk
    check value.value.get == "applied once"
    let invalid = db.migrate([Migration(version: 2, sql: "SELECT 1"), Migration(version: 1, sql: "SELECT 1")])
    check not invalid.isOk
    db.close()
