## Managed multi-bucket growth and rollback tests
## (design 19-use-nicp_cdk-memory-management, tasks T5/T6).
##
## A SQLite `MemoryId` must be able to grow across several MemoryManager buckets
## and still reopen through the strict post_upgrade path. Because the manager
## owns physical capacity outside the SQLite transaction, a rolled-back update
## may leave extra buckets allocated, but it must never change the committed
## SQLite logical state.
import std/[options, unittest]
import nicp_cdk/storage/memory_manager
import ic_sqlite

const
  SqliteMemory = 8'u8
  Rows = 800

proc valueFor(index: int): string =
  result = newString(256)
  for offset in 0 ..< result.len:
    result[offset] = char(ord('a') + (index + offset) mod 26)

const migrations = [
  Migration(version: 1,
    sql: "CREATE TABLE kv (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
]

suite "Managed SQLite growth":
  test "T5 MemoryId grows across buckets and survives reopen":
    let raw = newVecStableBackend()
    var manager = createMemoryManagerStrict(raw, bucketSizeInPages = 1)
    var db: Db
    check db.initDatabaseManaged(manager, newMemoryId(SqliteMemory), migrations,
      doiCreateOnly).isOk

    let seeded = db.withUpdate(proc(conn: var UpdateConnection): Result[int, DbError] =
      for index in 0 ..< Rows:
        let inserted = conn.execText("INSERT INTO kv(key, value) VALUES (?, ?)",
          ["k" & $index, valueFor(index)])
        if not inserted.isOk:
          return Result[int, DbError](isOk: false, error: inserted.error)
      Result[int, DbError](isOk: true, value: Rows))
    check seeded.isOk

    # A 1-page bucket forces a single MemoryId to span more than one bucket.
    check manager.memoryBucketCount(newMemoryId(SqliteMemory)) > 1
    db.close()

    # post_upgrade path: strict reopen of the same manager and MemoryId.
    manager = openExistingMemoryManagerStrict(raw)
    check manager.memoryBucketCount(newMemoryId(SqliteMemory)) > 1
    var reopened: Db
    check reopened.initDatabaseManaged(manager, newMemoryId(SqliteMemory), [],
      doiOpenExisting).isOk
    let counted = reopened.queryOneText("SELECT CAST(count(*) AS TEXT) FROM kv", [])
    check counted.isOk and counted.value.isSome and counted.value.get == $Rows
    let spot = reopened.queryOneText("SELECT value FROM kv WHERE key = ?", ["k799"])
    check spot.isOk and spot.value.isSome and spot.value.get == valueFor(799)
    reopened.close()

  test "T6 rollback never changes the committed SQLite state":
    let raw = newVecStableBackend()
    let manager = createMemoryManagerStrict(raw, bucketSizeInPages = 1)
    var db: Db
    check db.initDatabaseManaged(manager, newMemoryId(SqliteMemory), migrations,
      doiCreateOnly).isOk
    check db.execText("INSERT INTO kv(key, value) VALUES (?, ?)",
      ["seed", "original"]).isOk

    let outcome = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      for index in 0 ..< Rows:
        let inserted = conn.execText("INSERT INTO kv(key, value) VALUES (?, ?)",
          ["r" & $index, valueFor(index)])
        if not inserted.isOk:
          return Result[bool, DbError](isOk: false, error: inserted.error)
      Result[bool, DbError](isOk: false,
        error: DbError(code: -1, message: "forced rollback")))
    check not outcome.isOk

    # Only the pre-transaction row is visible; growth may have been retained.
    let counted = db.queryOneText("SELECT CAST(count(*) AS TEXT) FROM kv", [])
    check counted.isOk and counted.value.isSome and counted.value.get == "1"
    let spot = db.queryOneText("SELECT value FROM kv WHERE key = ?", ["seed"])
    check spot.isOk and spot.value.isSome and spot.value.get == "original"
    db.close()
