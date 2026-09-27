import nicp_cdk
import nicp_cdk/ic0/ic0
import std/options
import ic_sqlite
import ic_sqlite/stable/ic_backend

var database: Db
var databaseReady = false

const migrations = [
  Migration(version: 1,
    sql: "CREATE TABLE kv (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
]

proc initializeDatabase() =
  database.close()
  let initialized = database.initDatabase(newIcStableBackend(), migrations)
  if not initialized.isOk:
    let message = "minimal_kv database initialization failed: " & initialized.error.message
    ic0_trap(cast[int](message.cstring), message.len)
  databaseReady = true

proc canister_init() {.exportwasm.} =
  initializeDatabase()

proc canister_post_upgrade() {.exportwasm.} =
  initializeDatabase()

proc put() {.update.} =
  let request = Request.new()
  if not databaseReady:
    initializeDatabase()
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
