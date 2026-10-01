import std/unittest
import ic_sqlite
import nicp_cdk/storage/stable_backend

suite "benchmark storage observations":
  test "SQLite virtual pages are reported independently from DB bytes":
    let backend: StableBackend = newVecStableBackend()
    var database: Db
    check database.init(backend).isOk
    let initial = database.storageStats()
    check initial.sqliteVirtualPages >= 1
    check database.exec("CREATE TABLE bench (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID").isOk
    check database.execText("INSERT INTO bench(key, value) VALUES (?, ?)", ["k00000000", "value-00000000-stable-vfs"]).isOk
    let current = database.storageStats()
    check current.dbSize > 0
    check current.sqliteVirtualPages >= initial.sqliteVirtualPages
    database.close()
