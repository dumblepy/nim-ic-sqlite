## Shared canister lifecycle initialization.
##
## Call `initDatabase` from both the canister's init and post-upgrade hooks.
## It deliberately recreates only heap state: the SQLite image, metadata, and
## migrations remain in stable memory.
import ./db
import ./stable/backend
import ./stable/superblock

proc initDatabase*(db: var Db; backend: StableBackend;
                   migrations: openArray[Migration] = [];
                   config = defaultDbConfig()): Result[bool, DbError] =
  let opened = db.init(backend, config = config)
  if not opened.isOk:
    return opened
  let migrated = db.migrate(migrations)
  if migrated.isOk:
    return migrated
  db.close()
  Result[bool, DbError](isOk: false, error: migrated.error)

proc reopenDatabaseAfterUpgrade*(db: var Db; backend: StableBackend;
                                 migrations: openArray[Migration] = [];
                                 config = defaultDbConfig()): Result[bool, DbError] =
  ## The implementation intentionally matches init; only its call site differs.
  db.initDatabase(backend, migrations, config)
