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

## Sharing stable memory with a MemoryManager

By default `initDatabase(newIcStableBackend(), ...)` uses **exclusive stable
memory**: SQLite owns the whole raw region (superblock at offset 0, DB image
from 64 KiB). In that mode you must not place `IcStableSeq`, `IcStableTable`,
or `IcStableHashMap` in the same raw stable memory.

To store SQLite inside one virtual `MemoryId` alongside other stable
structures, use the MemoryManager-compatible API. Its on-stable layout is
byte-compatible with `ic-stable-structures` 0.7 (`MGR`) and the Rust
`ic-sqlite-vfs` memory manager.

```nim
import ic_sqlite
import ic_sqlite/stable/ic_backend
import ic_sqlite/stable/memory_manager
import nicp_cdk/ic0/ic0

var manager: MemoryManager
var database: Db

const dbMemory = 8'u8  # ids 0..7 are used by the wasi2ic polyfill

proc initializeDatabase() =
  database.close()
  let raw = newIcStableBackend()
  # Boot through wasi2ic: place the SQLite-owned manager after the polyfill's
  # fixed MGR prefix. Without wasi2ic this is just `raw`.
  manager = initMemoryManager(stableBackendAfterForeignManager(raw))
  let initialized =
    database.initDatabase(manager.getMemory(newMemoryId(dbMemory)), migrations)
  if not initialized.isOk:
    let message = "database initialization failed: " & initialized.error.message
    ic0_trap(cast[int](message.cstring), message.len)

proc canister_init() {.exportwasm.} =
  initializeDatabase()

proc canister_post_upgrade() {.exportwasm.} =
  initializeDatabase()
```

`getMemory(id)` returns a `VirtualStableBackend` that inherits from
`StableBackend`, so it can be passed anywhere a backend is expected. Native
tests use `newVecStableBackend()` with the same API.

```text
raw stable memory
  page 0
    +0     magic "MGR"                          3 bytes
    +3     layout version                       1 byte (= 1)
    +4     allocated bucket count               u16
    +6     bucket size in stable pages          u16 (default 128)
    +8     reserved                             32 bytes
    +40    size in pages per MemoryId           255 * u64
    +2080  bucket allocation table              32768 * u8 (owner id, 255 = free)
  page 1+
    1 bucket = bucketSizeInPages * 64 KiB (default 8 MiB)
```

A virtual `MemoryId` maps `logical offset -> bucket -> physical address`.
Buckets are assigned to exactly one owner in the allocation table, so physical
ranges never overlap. Buckets allocated to one memory may be interleaved with
another memory's buckets.

- `initMemoryManager(backend)`: creates a fresh / all-zero region, validates and
  loads an existing `MGR` region, and rejects any other non-empty region without
  overwriting it (`ValueError`).
- `newMemoryId(id)`: the virtual memory id to use (`255` is reserved).
- `manager.getMemory(id)`: returns a `VirtualStableBackend` usable as a
  `StableBackend`.
- `stableBackendAfterForeignManager(raw)`: detects a wasi2ic/`MGR` prefix and
  offsets the SQLite-owned manager past its fixed reservation
  (`Wasi2icReservedStablePages = 1025` pages) so the two do not share an
  allocation table.
- Limits: up to 255 memory ids (`255` is reserved), up to 32768 buckets, and
  `grow` is a page-granular operation. `MemoryId`/bucket bounds are validated
  on load, and every access is bounds-checked.

> Note: the `1025`-page reservation assumes the wasi2ic polyfill keeps eight
> 128-page buckets. If it grows past that, it could overlap the SQLite-owned
> manager. The safest layout is to create a single `MemoryManager` and place
> every stable structure, including SQLite, in `MemoryId`s under it.

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

## Stable memory compatibility

- The superblock is stored at offset 0 using a fixed little-endian encoding with
  magic `"NIMSQLV1"`; it is never a raw Nim object dump.
- On initialization, empty (or all-zero) stable memory creates a fresh image,
  `NIMSQLV1` is loaded, and any other non-empty image is rejected with
  `foreign stable memory image` instead of being overwritten.
- The superblock format, page size, logical DB offset, public API, and defaults
  are preserved. A canister upgrade only recreates heap state; the SQLite image
  and metadata are restored from stable memory.

## Testing

Run the full suite from `ic-sqlite/` (after checking out the `nicp_cdk` submodule):

```sh
./scripts/test.sh
```

The script installs the Nim package dependencies, runs native tests with
Testament, builds the wasm32-wasi SQLite archive, and starts
the local IC network for the example-canister integration test. The integration
test verifies migrations, CRUD calls, and data persistence through a canister
upgrade.

Native tests use `VecStableBackend` to verify overlay, superblock, VFS, and
MemoryManager logic without a local replica. The `MGR` layout, non-overlapping
`MemoryId` ranges, loading an existing `MGR` image, and SQLite coexistence are
covered by `tests/test_memory_manager.nim`.

To build only the SQLite archive:

```sh
./scripts/build_sqlite.sh
```

Set `WASI_SDK_PATH` before running that command.

## Nim / Rust comparison benchmarks

`benchmarks/comparison/` compares the Nim implementation against a pinned Rust
`ic-sqlite-vfs` implementation on the same local ICP replica. Measurements are
not run in CI; run them manually in a development environment or the repository
dev container.

Make `nim`, `nicp`, `icp`, the Rust toolchain, the `wasm32-unknown-unknown`
target, and WASI SDK available first. In Docker, run these commands inside the
test container.

### Core KV paired measurement

```bash
cd /application/ic-sqlite/benchmarks/comparison
./prepare_rust.sh
nim c -d:release runner/main.nim
NISQL_COMPARE_NIM_SHA=HEAD ./runner/main 5
```

The runner creates a fresh canister per implementation and runs reset, read, and
update in each trial. Results are written to `results/<UTC run ID>/`:

- `manifest.json`: pinned SHAs, Wasm hashes, toolchain, raw stable memory, heap,
  and status balances before/after each phase
- `measurements.csv` / `measurements.jsonl`: per-trial observations
- `summary.md`: median update instruction count

Validate the artifact right after generation, replacing `<run-id>` with the
value printed by the runner:

```bash
nim c -r runner/validate.nim results/<run-id>
```

`NISQL_COMPARE_NIM_SHA=HEAD` measures the currently checked-out Nim source.
Omit it to reproduce a pinned SHA.

To also record balance changes on an external network, set the network and the
initial cycles per fresh canister explicitly. This creates, installs, and runs
canisters:

```bash
NISQL_COMPARE_NETWORK=ic \
NISQL_COMPARE_INITIAL_CYCLES=2t \
NISQL_COMPARE_NIM_SHA=HEAD ./runner/main 1
```

The `cycles` / `reserved_cycles` deltas of the external network are also stored
in the manifest. They include the runner's own ingress, status, and query calls,
so they are not treated as the exact update-execution fee.

### Churn and 30-day cost estimate

Initialize 5,000 rows, then run 100 cycles of 1,000 DELETE and 1,000 INSERT.

```bash
cd /application/ic-sqlite/benchmarks/comparison
./prepare_rust.sh
nim c -d:release -r runner/churn.nim
nim c -d:release -r runner/validate.nim results/churn-<run-id>
nim c -d:release -r runner/cost_report.nim results/churn-<run-id>
```

`cost_report.nim` accepts only a validated churn artifact and writes a 30-day
storage and update estimate using a dated pricing snapshot. Local replica
`cycles` balance deltas are a management status observation and are not used as
the instruction-execution fee in the estimate.

### Profile artifact

Collect the shared read, write, multi-get, and growth profile metrics on a fresh
canister.

```bash
cd /application/ic-sqlite/benchmarks/comparison
./prepare_rust.sh
NISQL_COMPARE_NIM_SHA=HEAD nim c -d:release -r runner/profile.nim
```

`results/profile-<UTC run ID>/profile_measurements.jsonl` stores the metrics
common to both implementations: rows, instructions, checksum, DB size, logical
stable pages/bytes, and raw stable memory. VFS/page-table-specific details are
not stored as comparison values.

```bash
nim c -d:release -r runner/validate.nim results/profile-<run-id>
nim c -d:release -r runner/profile_summary.nim results/profile-<run-id>
```

`profile_summary.md` prints the Nim/Rust instruction ratio per profile. Profiles
use a different counting backend than the normal workload, so they are not
averaged with the core KV instruction counts.

### Interpreting the numbers

- `instructions_update` is the observed Wasm instruction count of an update
  message.
- Query instruction values use a different connection and warmup condition, so
  they are not used for cycle estimates.
- `raw_stable_*` comes from `ic0_stable64_size`; `sqlite_virtual_pages` is the
  page count of the logical backend passed to SQLite. The two are not compared
  as the same quantity.
- `heap_bytes` is `memory_size - raw_stable_bytes` from a local `canister
  status`. It is a status observation at measurement time, not a general
  definition of canister heap.
- The profile endpoint uses a different counting backend than the normal
  workload, so the profile breakdown and the normal workload instruction counts
  are not averaged as one series.
