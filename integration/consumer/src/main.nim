## Dummy consumer canister for the CI linkage test.
##
## It deliberately keeps to `import ic_sqlite` plus one shim symbol reference so
## the link step must pull the prebuilt SQLite archive and the IC VFS shim from
## the installed package. See 17-fix-dir branch rule section 14.4.
import ic_sqlite

proc icSqliteRegisterVfs(): cint
  {.importc: "ic_sqlite_register_vfs", cdecl.}

proc icSqliteConsumerSmoke*(): cint
  {.cdecl, exportc: "ic_sqlite_consumer_smoke".} =
  discard IcSqliteVersion
  icSqliteRegisterVfs()
