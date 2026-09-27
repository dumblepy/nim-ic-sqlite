import nicp_cdk
import nicp_cdk/ic0/ic0
import std/options
import ic_sqlite
import ic_sqlite/stable/ic_backend

var database: Db
var databaseReady = false

const migrations = [
  Migration(version: 1,
    sql: "CREATE TABLE kv (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)"),
  Migration(version: 2,
    sql: "CREATE INDEX kv_value_idx ON kv(value)")
]

proc greet() {.query.} =
  let request = Request.new()
  reply("Hello, " & request.getStr(0) & "!")

proc initializeDatabase() =
  ## Both lifecycle hooks recreate transient SQLite/VFS state from the stable
  ## image. A failure must reject install/upgrade rather than leave a canister
  ## that might later overwrite a foreign stable-memory image.
  database.close()
  let initialized = database.initDatabase(newIcStableBackend(), migrations)
  if not initialized.isOk:
    let message = "ic-sqlite initialization failed: " & initialized.error.message
    ic0_trap(cast[int](message.cstring), message.len)
  databaseReady = true

proc canister_init() {.exportwasm.} =
  initializeDatabase()

proc canister_post_upgrade() {.exportwasm.} =
  initializeDatabase()

proc ensureDatabase(): string =
  if databaseReady: return ""
  initializeDatabase()
  ""

proc selectOne() {.update.} =
  ## Intentionally fixed SQL: the example must not expose arbitrary SQL over
  ## the public canister interface.
  let setupError = ensureDatabase()
  if setupError.len > 0:
    reply("error: " & setupError)
    return
  let executed = database.exec("SELECT 1")
  if not executed.isOk:
    reply("error: " & executed.error.message)
    return
  reply("ok")

proc createTable() {.update.} =
  let setupError = ensureDatabase()
  if setupError.len > 0:
    reply("error: " & setupError)
    return
  let created = database.exec("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
  if not created.isOk:
    reply("error: " & created.error.message)
    return
  reply("ok")

proc put() {.update.} =
  let request = Request.new()
  let setupError = ensureDatabase()
  if setupError.len > 0:
    reply("error: " & setupError)
    return
  let saved = database.execText(
    "INSERT INTO kv(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    [request.getStr(0), request.getStr(1)])
  if not saved.isOk:
    reply("error: " & saved.error.message)
    return
  reply("ok")

proc get() {.query.} =
  let request = Request.new()
  let setupError = ensureDatabase()
  if setupError.len > 0:
    reply("error: " & setupError)
    return
  let found = database.queryOneText("SELECT value FROM kv WHERE key = ?", [request.getStr(0)])
  if not found.isOk:
    reply("error: " & found.error.message)
  elif found.value.isSome:
    reply(found.value.get)
  else:
    reply("not_found")

proc migrationCount() {.query.} =
  let found = database.queryOneText(
    "SELECT CAST(count(*) AS TEXT) FROM __nim_ic_sqlite_migrations", [])
  if not found.isOk:
    reply("error: " & found.error.message)
  elif found.value.isSome:
    reply(found.value.get)
  else:
    reply("0")

proc update() {.update.} =
  let request = Request.new()
  let setupError = ensureDatabase()
  if setupError.len > 0:
    reply("error: " & setupError)
    return
  let changed = database.execText("UPDATE kv SET value = ? WHERE key = ?", [request.getStr(1), request.getStr(0)])
  if not changed.isOk:
    reply("error: " & changed.error.message)
  elif changed.value == 1:
    reply("ok")
  else:
    reply("not_found")

proc deleteValue() {.update.} =
  let request = Request.new()
  let setupError = ensureDatabase()
  if setupError.len > 0:
    reply("error: " & setupError)
    return
  let changed = database.execText("DELETE FROM kv WHERE key = ?", [request.getStr(0)])
  if not changed.isOk:
    reply("error: " & changed.error.message)
  elif changed.value == 1:
    reply("ok")
  else:
    reply("not_found")
