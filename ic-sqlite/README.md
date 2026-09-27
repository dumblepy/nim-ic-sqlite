# ic_sqlite

`ic_sqlite` is a Nim SQLite library for Internet Computer (IC) canisters. It
stores the SQLite database image in IC stable memory, so data survives canister
upgrades. The public API is `import ic_sqlite`; SQLite C pointers and VFS
details stay internal to the library.

## What it provides

- SQLite backed by IC stable memory through a custom VFS.
- Atomic update operations and rollback through `withUpdate`.
- Versioned, idempotent migrations.
- Prepared-statement binding for text, integers, floating-point values, booleans,
  blobs, `Option[T]`, and explicit `SqlValue` values.
- A typed, immutable Query Builder with direct row decoding into Nim objects.
- Native test helpers (`initMemoryForTest`) and a deployed-canister integration
  test.

## Requirements

For native development, install Nim 2.2.12 or later. Building the IC canister
example additionally requires:

- [`nicp_cdk`](https://github.com/dumblepy/nicp_cdk)
- WASI SDK (`WASI_SDK_PATH`)
- `ic-wasi-polyfill` (`IC_WASI_POLYFILL_PATH`)
- `wasi2ic`, `ic-wasm`, and the `icp` CLI

The repository Dockerfile contains the complete toolchain used by CI.

Before compiling a canister, build the target-specific SQLite link inputs:

```sh
WASI_SDK_PATH=/root/.wasi-sdk ./scripts/build_sqlite.sh
```

This creates the SQLite archive and C shim objects under
`vendor/sqlite/wasm32-wasi/`. The example canister configurations link from
that directory, so they do not depend on transient files in `build/`.

## Install for local development

Clone this repository and register the package with Nimble:

```sh
git clone --recurse-submodules https://github.com/dumblepy/nim-ic-sqlite.git
cd nim-ic-sqlite/ic-sqlite
nimble develop
```

Your Nim project can then import the public module:

```nim
import ic_sqlite
```

## Database initialization and migrations

On an IC canister, initialize the database in both the init and post-upgrade
hooks. Migrations are trusted, static SQL statements. They are recorded in the
database and each version is applied at most once.

```nim
import ic_sqlite
import ic_sqlite/stable/ic_backend
import nicp_cdk/ic0/ic0

var database: Db

const migrations = [
  Migration(version: 1,
    sql: "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, active INTEGER NOT NULL)"),
  Migration(version: 2,
    sql: "CREATE INDEX users_active_idx ON users(active)")
]

proc initializeDatabase() =
  database.close()
  let initialized = database.initDatabase(newIcStableBackend(), migrations)
  if not initialized.isOk:
    let message = "database initialization failed: " & initialized.error.message
    ic0_trap(cast[int](message.cstring), message.len)

proc canister_init() {.exportwasm.} =
  initializeDatabase()

proc canister_post_upgrade() {.exportwasm.} =
  initializeDatabase()
```

`newIcStableBackend()` is available only in a wasm32 IC canister. For native
unit tests, use `db.initMemoryForTest()` instead.

## Safe SQL execution

Use `execText` or `execValues` whenever values originate outside the program.
Values are bound as prepared-statement parameters; they are never interpolated
into SQL text.

```nim
let created = database.execText(
  "INSERT INTO users(id, name, active) VALUES (?, ?, ?)",
  ["1", "Ada", "1"])

let found = database.queryOneText(
  "SELECT name FROM users WHERE id = ?", ["1"])
```

For non-text values, use `SqlValue`:

```nim
let changed = database.execValues(
  "UPDATE users SET active = ? WHERE id = ?",
  [sqlInt(0), sqlInt(1)])
```

`exec(sql)` is intended for trusted static SQL, such as schema migrations. Do
not build its SQL string from user input.

## Typed Query Builder

The Query Builder quotes identifiers, validates supported operators, and binds
values. Query values are immutable: deriving a new query does not mutate the
original query.

```nim
import std/options
import ic_sqlite

type
  User = object
    id: int64
    name: string
    active: bool

  NewUser = object
    id: int64
    name: string
    active: bool

  UserPatch = object
    active: bool

let inserted = database.table("users").insert(
  NewUser(id: 1, name: "Ada", active: true))

let users = database
  .table("users")
  .select("id", "name", "active")
  .where("active", "=", true)
  .orderBy("id", Desc)
  .limit(20)
  .get(User)

if users.isOk:
  for user in users.value:
    echo user.name

let oneUser = database.table("users").find(1'i64, User)
let updated = database.table("users").where("id", "=", 1).update(UserPatch(active: false))
let deleted = database.table("users").where("id", "=", 1).delete()
```

`get(User)` returns `Result[seq[User], DbError]`; `first(User)` and `find(...)`
return `Result[Option[User], DbError]`. A selected column name must match an
object field name. SQLite `NULL` maps to `Option[T]`:

```nim
type UserSummary = object
  id: int64
  nickname: Option[string]
```

The builder also supports `orWhere`, `whereGroup`, `whereIn`, `whereNotIn`,
`whereBetween`, `whereNull`, `whereNotNull`, `join`, `leftJoin`, `groupBy`, and
`having`.

## Transactions

Use `withUpdate` when several writes must commit or roll back together. A
Query Builder created from `UpdateConnection` uses the same SQLite transaction,
so it can read rows written earlier in that transaction.

```nim
let result = database.withUpdate(
  proc(conn: var UpdateConnection): Result[bool, DbError] =
    let inserted = conn.table("users").insert(
      NewUser(id: 2, name: "Grace", active: true))
    if not inserted.isOk:
      return Result[bool, DbError](isOk: false, error: inserted.error)

    let visible = conn.table("users").where("id", "=", 2).first(User)
    if not visible.isOk:
      return Result[bool, DbError](isOk: false, error: visible.error)

    Result[bool, DbError](isOk: true, value: true)
)
```

Returning an error or raising a catchable exception rolls the transaction back.
Do not keep a `Query` derived from `UpdateConnection` after the `withUpdate`
body returns; executing it later returns `dekInvalidState`.

## Resource limits and codecs

`DbConfig` protects canisters from unbounded statements and results. The
defaults limit result rows, result bytes, and bound parameters. Configure them
at initialization time when an application needs stricter limits.

```nim
var config = defaultDbConfig()
config.maxResultRows = 100
config.maxResultBytes = 1'u64 * 1024 * 1024
config.maxQueryParams = 100
```

Standard row codecs support integer types, floats, `bool`, `string`,
`seq[byte]`, and `Option[T]`. For an application-specific type, create an
explicit `SqlCodec[T]` with `encode` and `decode` procedures, then use
`toSqlValue(value, codec)` and `readColumn(statement, index, codec)`.

## Complete canister example

[`example/`](./example/) is a deployable Nim canister. It runs migrations,
implements `put`, `get`, `update`, and `deleteValue`, and preserves its SQLite
image across upgrades.

```sh
cd example
icp network start -d
icp deploy -y
icp canister call backend migrationCount '()' --query
icp canister call backend put '("hello", "world")'
icp canister call backend get '("hello")' --query
icp canister call backend update '("hello", "updated")'
icp canister call backend deleteValue '("hello")'
icp network stop
```

The local network uses an OS-assigned port, so it can run beside other IC
projects without a fixed gateway-port conflict.

## Testing

Run the full suite from `ic-sqlite/`:

```sh
nimble test
```

This runs native unit tests, builds the wasm32-wasi SQLite archive, and starts
the local IC network for the example-canister integration test. The integration
test verifies migrations, CRUD calls, and data persistence through a canister
upgrade.

To build only the SQLite archive:

```sh
./scripts/build_sqlite.sh
```

Set `WASI_SDK_PATH` before running that command.
