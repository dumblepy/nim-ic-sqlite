# SQLite amalgamation

This directory vendors SQLite 3.53.4 from the official
`sqlite-amalgamation-3530400.zip` archive.  Its SHA3-256 is recorded in
[`SHA3-256`](./SHA3-256).  Only `sqlite3.c` and `sqlite3.h` are needed by this
library.

Rebuild the wasm32-wasi link inputs with:

```sh
WASI_SDK_PATH=/root/.wasi-sdk ./scripts/build_sqlite.sh
```

The build writes `sqlite3.o`, `libsqlite3_ic.a`, `ic_sqlite_vfs_shim.o`, and
`sqlite_helpers.o` to [`wasm32-wasi/`](./wasm32-wasi/). These generated files
are intentionally ignored by Git; canister `config.nims` files link only from
that target-specific directory.
