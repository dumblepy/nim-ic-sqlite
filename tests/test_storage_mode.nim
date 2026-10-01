## Storage-mode and open-intent tests (design 19-use-nicp_cdk-memory-management).
##
## These cover the negative paths that must fail closed: a wrong or empty
## `MemoryId` during `post_upgrade`, coexistence with an explicit exclusive
## backend, and the guarantee that rejected opens leave the target bytes
## unchanged. `MemoryManager` / `MemoryId` are owned by `nicp_cdk`.
import std/[options, strutils, unittest]
import nicp_cdk/storage/memory_manager
import ic_sqlite

const
  SqliteMemory = 8'u8
  OtherMemory = 9'u8

proc readBytes(raw: StableBackend; offset: uint64; size: int): seq[byte] =
  result = newSeq[byte](size)
  raw.read(offset, addr result[0], uint64(size))

const migrations = [
  Migration(version: 1,
    sql: "CREATE TABLE kv (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)"),
  Migration(version: 2,
    sql: "CREATE INDEX kv_value_idx ON kv(value)")
]

suite "Db storage mode and open intent":
  test "T05/T06 same manager base and MemoryId reopen the same database":
    let raw = newVecStableBackend()
    var manager = createMemoryManagerStrict(raw)
    var db: Db
    check db.initDatabaseManaged(manager, newMemoryId(SqliteMemory), migrations,
      doiCreateOnly).isOk
    check db.execText("INSERT INTO kv(key, value) VALUES (?, ?)",
      ["alpha", "first"]).isOk
    db.close()

    # Re-open the manager strictly (post_upgrade path) and the same slot.
    manager = openExistingMemoryManagerStrict(raw)
    check manager.memorySizePages(newMemoryId(SqliteMemory)) > 0
    # The slot was not silently relocated to a new example id (120).
    check manager.memorySizePages(newMemoryId(120'u8)) == 0

    var reopened: Db
    check reopened.initDatabaseManaged(manager, newMemoryId(SqliteMemory),
      migrations, doiOpenExisting).isOk
    let row = reopened.queryOneText("SELECT value FROM kv WHERE key = ?", ["alpha"])
    check row.isOk
    check row.value.isSome
    check row.value.get == "first"
    reopened.close()

  test "T07 post_upgrade with an empty MemoryId fails and writes nothing":
    let raw = newVecStableBackend()
    var manager = createMemoryManagerStrict(raw)
    var db: Db
    check db.initDatabaseManaged(manager, newMemoryId(SqliteMemory), migrations,
      doiCreateOnly).isOk
    check db.execText("INSERT INTO kv(key, value) VALUES (?, ?)",
      ["alpha", "first"]).isOk
    db.close()

    manager = openExistingMemoryManagerStrict(raw)
    let allocatedBefore = manager.allocatedBucketCount
    let wrongVm = manager.getMemory(newMemoryId(OtherMemory))
    check wrongVm.sizePages == 0

    var wrong: Db
    let opened = wrong.initDatabaseManaged(manager, newMemoryId(OtherMemory),
      migrations, doiOpenExisting)
    check not opened.isOk
    check opened.error.kind == dekMissingDatabase
    # The wrong slot stayed empty and no manager bucket was allocated.
    check manager.memorySizePages(newMemoryId(OtherMemory)) == 0
    check manager.allocatedBucketCount == allocatedBefore

    # The original database is still intact.
    var stillThere: Db
    check stillThere.initDatabaseManaged(manager, newMemoryId(SqliteMemory),
      migrations, doiOpenExisting).isOk
    let row = stillThere.queryOneText("SELECT value FROM kv WHERE key = ?", ["alpha"])
    check row.isOk and row.value.isSome and row.value.get == "first"
    stillThere.close()

  test "T09 a VirtualStableBackend uses its offset 0 as the superblock":
    let raw = newVecStableBackend()
    let manager = createMemoryManagerStrict(raw)
    let vm = manager.getMemory(newMemoryId(SqliteMemory))
    check vm.grow(4)

    var db: Db
    check db.init(vm).isOk
    check db.exec("CREATE TABLE items (id INTEGER, name TEXT)").isOk
    check db.execText("INSERT INTO items(id, name) VALUES (?, ?)", ["1", "one"]).isOk
    db.close()

    var reopened: Db
    check reopened.init(vm).isOk
    let row = reopened.queryOneText("SELECT name FROM items WHERE id = ?", ["1"])
    check row.isOk and row.value.isSome and row.value.get == "one"
    reopened.close()

  test "T13 init/update/upgrade/openExisting/query keeps records and migrations":
    let raw = newVecStableBackend()
    var manager = createMemoryManagerStrict(raw)
    var db: Db
    check db.initDatabaseManaged(manager, newMemoryId(SqliteMemory), migrations,
      doiCreateOnly).isOk
    check db.execText("INSERT INTO kv(key, value) VALUES (?, ?)",
      ["cycle", "one"]).isOk
    check db.execText("UPDATE kv SET value = ? WHERE key = ?",
      ["two", "cycle"]).isOk
    db.close()

    # Canister upgrade: heap state is recreated, stable memory survives.
    manager = openExistingMemoryManagerStrict(raw)
    var upgraded: Db
    check upgraded.initDatabaseManaged(manager, newMemoryId(SqliteMemory),
      migrations, doiOpenExisting).isOk
    let row = upgraded.queryOneText("SELECT value FROM kv WHERE key = ?", ["cycle"])
    check row.isOk and row.value.isSome and row.value.get == "two"
    let migrationRows = upgraded.queryOneText(
      "SELECT CAST(count(*) AS TEXT) FROM __nim_ic_sqlite_migrations", [])
    check migrationRows.isOk and migrationRows.value.isSome
    check migrationRows.value.get == "2"
    upgraded.close()

  test "T15 rejected intents never modify the existing storage bytes":
    let raw = newVecStableBackend()
    var manager = createMemoryManagerStrict(raw)
    var db: Db
    check db.initDatabaseManaged(manager, newMemoryId(SqliteMemory), migrations,
      doiCreateOnly).isOk
    check db.execText("INSERT INTO kv(key, value) VALUES (?, ?)",
      ["sentinel", "value"]).isOk
    db.close()

    # Capture the whole virtual slot image across the negative creates.
    manager = openExistingMemoryManagerStrict(raw)
    let vm = manager.getMemory(newMemoryId(SqliteMemory))
    let slotPagesBefore = vm.sizePages
    let allocatedBefore = manager.allocatedBucketCount
    let rawPagesBefore = raw.sizePages

    # createOnly on an occupied slot must fail before any metadata write.
    var wrong: Db
    let createRejected = wrong.initDatabaseManaged(manager,
      newMemoryId(SqliteMemory), migrations, doiCreateOnly)
    check not createRejected.isOk
    check createRejected.error.kind == dekStorageMode

    # openExisting on an empty slot must fail without growing it.
    let emptyRejected = wrong.initDatabaseManaged(manager,
      newMemoryId(OtherMemory), migrations, doiOpenExisting)
    check not emptyRejected.isOk
    check emptyRejected.error.kind == dekMissingDatabase

    check raw.sizePages == rawPagesBefore
    check vm.sizePages == slotPagesBefore
    check manager.allocatedBucketCount == allocatedBefore
    check manager.memorySizePages(newMemoryId(OtherMemory)) == 0

    # A foreign raw region is rejected without modification by every intent.
    let foreign = newVecStableBackend()
    check foreign.grow(1)
    var marker = [byte 1, 2, 3, 4, 5, 6, 7, 8]
    foreign.write(0, addr marker[0], uint64(marker.len))
    for intent in [doiCreateOnly, doiOpenExisting, doiOpenOrCreate]:
      var foreignDb: Db
      let rejected = foreignDb.init(foreign, intent = intent)
      check not rejected.isOk
    check foreign.sizePages == 1
    check readBytes(foreign, 0, marker.len) == @marker

  test "exclusive mode owns the whole raw region":
    let raw = newVecStableBackend()
    var db: Db
    check db.initDatabaseExclusive(raw, migrations, doiCreateOnly).isOk
    check db.execText("INSERT INTO kv(key, value) VALUES (?, ?)",
      ["solo", "exclusive"]).isOk
    let mode = storageMode(exclusiveDbStorage(raw))
    check mode == dsmExclusive
    db.close()

    # The superblock lives at the raw region's logical offset 0.
    check raw.sizePages >= 1
    check readBytes(raw, 0, 8) == @[byte('N'), byte('I'), byte('M'),
      byte('S'), byte('Q'), byte('L'), byte('V'), byte('1')]

    var reopened: Db
    check reopened.initDatabaseExclusive(raw, migrations, doiOpenExisting).isOk
    let row = reopened.queryOneText("SELECT value FROM kv WHERE key = ?", ["solo"])
    check row.isOk and row.value.isSome and row.value.get == "exclusive"
    reopened.close()
