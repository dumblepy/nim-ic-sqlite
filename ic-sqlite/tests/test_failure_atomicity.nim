import std/[options, unittest]
import ic_sqlite
import ic_sqlite/stable/backend

suite "benchmark transaction failure":
  test "body error rolls back both SQLite rows and stable publish":
    let backend: StableBackend = newVecStableBackend()
    var database: Db
    check database.init(backend).isOk
    check database.exec("CREATE TABLE bench (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID").isOk
    let beforePages = backend.sizePages()
    let outcome = database.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let inserted = conn.execText("INSERT INTO bench(key, value) VALUES (?, ?)",
        ["k00000000", "value-00000000-stable-vfs"])
      if not inserted.isOk:
        return Result[bool, DbError](isOk: false, error: inserted.error)
      Result[bool, DbError](isOk: false, error: DbError(message: "injected failure"))
    )
    check not outcome.isOk
    check outcome.error.message == "injected failure"
    let row = database.queryOneText("SELECT value FROM bench WHERE key = ?", ["k00000000"])
    check row.isOk
    check row.value.isNone
    check backend.sizePages() == beforePages
    database.close()
