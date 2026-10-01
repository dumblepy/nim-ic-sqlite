## Coexistence test (design 19-use-nicp_cdk-memory-management, task T4).
##
## A single `MemoryManager` hosts an application-owned sentinel structure in one
## `MemoryId` and SQLite in another. Updating SQLite must never touch the other
## `MemoryId`'s bytes or its allocation.
import std/[options, unittest]
import nicp_cdk/storage/memory_manager
import ic_sqlite

suite "MemoryManager coexistence":
  test "SQLite update leaves another MemoryId untouched":
    let raw = newVecStableBackend()
    var manager = createMemoryManagerStrict(raw)

    const Sentinels = [byte 0xA5, 0x5A, 0x19, 0xE7, 0x00, 0xFF, 0x42, 0x24]
    const SentinelMemory = 7'u8
    const SqliteMemory = 8'u8

    let sentinel = manager.getMemory(newMemoryId(SentinelMemory))
    check sentinel.grow(1)
    sentinel.write(0, unsafeAddr Sentinels[0], uint64(Sentinels.len))
    let sentinelPagesBefore = sentinel.sizePages
    let allocatedBefore = manager.allocatedBucketCount

    var database: Db
    check database.initDatabaseManaged(manager, newMemoryId(SqliteMemory),
      [Migration(version: 1,
        sql: "CREATE TABLE isolated (key TEXT PRIMARY KEY, value TEXT)")],
      doiCreateOnly).isOk
    check database.execText("INSERT INTO isolated(key, value) VALUES (?, ?)",
      ["a", "b"]).isOk
    database.close()

    # SQLite allocated its own bucket(s) without disturbing the sentinel memory.
    check manager.allocatedBucketCount >= allocatedBefore
    check manager.memorySizePages(newMemoryId(SentinelMemory)) == sentinelPagesBefore
    var after: array[Sentinels.len, byte]
    sentinel.read(0, addr after[0], uint64(after.len))
    check after == Sentinels

    # Reopen the manager and both memories survive.
    manager = openExistingMemoryManagerStrict(raw)
    var reopened: Db
    check reopened.initDatabaseManaged(manager, newMemoryId(SqliteMemory), [],
      doiOpenExisting).isOk
    let row = reopened.queryOneText("SELECT value FROM isolated WHERE key = ?", ["a"])
    check row.isOk and row.value.isSome and row.value.get == "b"
    reopened.close()
    let sentinel2 = manager.getMemory(newMemoryId(SentinelMemory))
    var after2: array[Sentinels.len, byte]
    sentinel2.read(0, addr after2[0], uint64(after2.len))
    check after2 == Sentinels
