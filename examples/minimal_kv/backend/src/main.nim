import nicp_cdk
import nicp_cdk/ic0/ic0
import nicp_cdk/storage/memory_manager
import std/options
import ic_sqlite

var database: Db
var databaseReady = false

const
  SqliteMemoryId = newMemoryId(40'u8)
  migrations = [
    Migration(version: 1,
      sql: "CREATE TABLE kv (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
  ]

proc initializeDatabase(isUpgrade: bool) =
  ## The application owns one `MemoryManager` after the WASI-reserved prefix and
  ## stores SQLite in a single fixed `MemoryId`. `SqliteMemoryId` is part of the
  ## application's stable schema; never change it after a deploy.
  database.close()
  let raw = newIcStableBackend()
  let applicationMemory = newIcOffsetBackend(raw)
  let manager =
    if isUpgrade:
      openExistingMemoryManagerStrict(applicationMemory)
    else:
      createMemoryManagerStrict(applicationMemory)
  let storage = managedDbStorage(manager, SqliteMemoryId)
  let intent = if isUpgrade: doiOpenExisting else: doiCreateOnly
  let initialized = database.initDatabase(storage, migrations, intent)
  if not initialized.isOk:
    let message = "minimal_kv database initialization failed: " & initialized.error.message
    ic0_trap(cast[int](message.cstring), message.len)
  databaseReady = true

proc canister_init() {.exportwasm.} =
  initializeDatabase(false)

proc canister_post_upgrade() {.exportwasm.} =
  initializeDatabase(true)

proc put() {.update.} =
  let request = Request.new()
  if not databaseReady:
    initializeDatabase(true)
  let saved = database.execText(
    "INSERT INTO kv(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    [request.getStr(0), request.getStr(1)])
  if saved.isOk:
    reply("ok")
  else:
    reply("error: " & saved.error.message)

proc get() {.query.} =
  let request = Request.new()
  if not databaseReady:
    reply("not_ready")
    return
  let found = database.queryOneText("SELECT value FROM kv WHERE key = ?", [request.getStr(0)])
  if not found.isOk:
    reply("error: " & found.error.message)
  elif found.value.isSome:
    reply(found.value.get)
  else:
    reply("not_found")
