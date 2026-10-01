# ic-sqlite KV CRUD example

An independent Internet Computer canister project that demonstrates
[`ic-sqlite`](../../) end to end: versioned migrations, CRUD access over a
`kv` table, and stable-memory persistence across canister upgrades. It is a
Nim backend canister built with `nicp` and managed by `icp-cli`.

## Overview

- [`backend/`](./backend/): the Nim canister. `backend/src/main.nim` runs
  migrations on `init`/`post_upgrade` and exposes `put`, `get`, `update`,
  `putPair`, `deleteValue`, `selectOne`, `createTable`, `greet`, and `migrationCount`.
  Its interface is [`backend/backend.did`](./backend/backend.did).
- [`icp.yaml`](./icp.yaml): the `icp-cli` project definition (the `backend`
  canister and the `local` network/environment).

The canister stores its SQLite image in stable memory. `init` uses
`doiCreateOnly` and `post_upgrade` uses `doiOpenExisting`, so an upgrade only
reopens the existing image and never silently creates a new database. Because
the canister boots through the WASI polyfill, it selects the explicit
`legacyWasi2icDbStorage` adapter rather than an implicit offset.

## Build and Deploy

Start a local network:

```bash
icp network start -d
```

Deploy the project:

```bash
icp deploy
```

Call the backend directly:

```bash
icp canister call backend migrationCount '()' --query
icp canister call backend put '("hello", "world")'
icp canister call backend get '("hello")' --query
icp canister call backend update '("hello", "updated")'
icp canister call backend deleteValue '("hello")'
```

`backend` runs its migrations on startup and on upgrade. The `kv` table is
created by migration 1 and `kv_value_idx` by migration 2; `migrationCount`
returns the number of applied migrations.

Upgrade in place to verify persistence:

```bash
icp deploy backend -m upgrade -y
icp canister call backend get '("hello")' --query
```

## Transaction macro

`putPair(key1, value1, key2, value2)` uses `transaction(database, tx):` to
insert two new keys atomically. Its implementation is in
[`backend/src/main.nim`](./backend/src/main.nim). Each INSERT checks its Result;
returning an error Result rolls back both writes. Unlike `put`, `putPair` does
not overwrite existing keys.

A successful transaction commits both rows:

```bash
icp canister call backend putPair '("pair-a", "first", "pair-b", "second")'
icp canister call backend get '("pair-a")' --query
icp canister call backend get '("pair-b")' --query
```

These calls return `"ok"`, `"first"`, and `"second"`. Calling `putPair` with an
existing second key demonstrates rollback after the first INSERT succeeds:

```bash
icp canister call backend putPair '("rolled-back", "discarded", "pair-b", "replacement")'
icp canister call backend get '("rolled-back")' --query
icp canister call backend get '("pair-b")' --query
```

The write returns `"error: ..."`; `rolled-back` remains `"not_found"` and
`pair-b` still contains `"second"`. Committed rows also survive a canister
upgrade. The body is synchronous, uses `tx` for DB operations, and finishes
before the canister replies. Do not use `await` or inter-canister calls inside
it. A `return` inside the body exits only that body.

## Local Backend Iteration

Build the backend directly:

```bash
cd backend
nicp dev
```

Use `nicp build` instead of `nicp dev` for a release-oriented build. Stop the
local network with:

```bash
icp network stop
```
