## Dummy consumer canister for the CI linkage test.
##
## It deliberately keeps to `import ic_sqlite` plus one shim symbol reference so
## the link step must pull the prebuilt SQLite archive and the IC VFS shim from
## the installed package. It also proves the recommended external-consumer
## stable-memory composition compiles: `MemoryManager` / `MemoryId` come from
## nicp_cdk and SQLite is selected with `managedDbStorage`.
import nicp_cdk/storage/memory_manager
import ic_sqlite

proc icSqliteRegisterVfs(): cint
  {.importc: "ic_sqlite_register_vfs", cdecl.}

const SqliteMemoryId = newMemoryId(40'u8)

proc buildStorage(manager: MemoryManager): DbStorage =
  managedDbStorage(manager, SqliteMemoryId)

proc icSqliteConsumerSmoke*(): cint
  {.cdecl, exportc: "ic_sqlite_consumer_smoke".} =
  discard IcSqliteVersion
  icSqliteRegisterVfs()
