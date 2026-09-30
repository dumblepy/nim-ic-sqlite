## Shared canister lifecycle initialization.
##
## Prefer the explicit `DbStorage` / `DbOpenIntent` entry points so that
## `init` (create) and `post_upgrade` (open existing) cannot silently pick the
## wrong behaviour. The plain `initDatabase(db, backend, ...)` overload is kept
## as a compatibility shim and behaves as `doiOpenOrCreate`.
import ./db
import ./stable/backend
import ./stable/superblock
import ./stable/memory_manager

proc initDatabase*(db: var Db; storage: DbStorage;
                   migrations: openArray[Migration] = [];
                   intent: DbOpenIntent;
                   config = defaultDbConfig()): Result[bool, DbError] =
  ## Opens the resolved storage with an explicit intent, then applies migrations.
  ##
  ## The intent is validated before SQLite touches the storage, so an empty or
  ## wrong `MemoryId` passed with `doiOpenExisting` fails without creating a DB.
  let opened = db.init(storage, config = config, intent = intent)
  if not opened.isOk:
    return opened
  let migrated = db.migrate(migrations)
  if migrated.isOk:
    return migrated
  db.close()
  Result[bool, DbError](isOk: false, error: migrated.error)

proc initDatabase*(db: var Db; backend: StableBackend;
                   migrations: openArray[Migration] = [];
                   config = defaultDbConfig()): Result[bool, DbError] =
  ## Backward-compatible entry point. It is equivalent to
  ## `exclusiveDbStorage(backend)` plus `doiOpenOrCreate`; new code should pass
  ## an explicit `DbStorage` and `DbOpenIntent` instead.
  db.initDatabase(exclusiveDbStorage(backend), migrations, doiOpenOrCreate, config)

proc initDatabaseManaged*(db: var Db; manager: MemoryManager; id: MemoryId;
                          migrations: openArray[Migration] = [];
                          intent: DbOpenIntent;
                          config = defaultDbConfig()): Result[bool, DbError] =
  ## Convenience overload: SQLite in one virtual `MemoryId` of `manager`.
  db.initDatabase(managedDbStorage(manager, id), migrations, intent, config)

proc initDatabaseExclusive*(db: var Db; raw: StableBackend;
                            migrations: openArray[Migration] = [];
                            intent: DbOpenIntent;
                            config = defaultDbConfig()): Result[bool, DbError] =
  ## Convenience overload: SQLite owns the whole raw region.
  db.initDatabase(exclusiveDbStorage(raw), migrations, intent, config)

proc reopenDatabaseAfterUpgrade*(db: var Db; storage: DbStorage;
                                 migrations: openArray[Migration] = [];
                                 config = defaultDbConfig()): Result[bool, DbError] =
  ## `post_upgrade` must only load an existing image. A missing/empty slot (for
  ## example a wrong `MemoryId`) fails instead of creating a fresh database.
  db.initDatabase(storage, migrations, doiOpenExisting, config)

proc reopenDatabaseAfterUpgrade*(db: var Db; backend: StableBackend;
                                 migrations: openArray[Migration] = [];
                                 config = defaultDbConfig()): Result[bool, DbError] =
  ## Compatibility shim: opens `backend` as exclusive existing-only storage.
  db.reopenDatabaseAfterUpgrade(exclusiveDbStorage(backend), migrations, config)
