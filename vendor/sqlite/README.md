# SQLite amalgamation

This directory vendors SQLite 3.53.4 from the official
`sqlite-amalgamation-3530400.zip` archive.  Its SHA3-256 is recorded in
[`SHA3-256`](./SHA3-256).  Only `sqlite3.c` and `sqlite3.h` are needed by this
library.

Rebuild the wasm32-wasip1 link inputs with:

```sh
WASI_SDK_PATH=/root/.wasi-sdk ./scripts/build_sqlite.sh
```

The build writes the prebuilt `libsqlite3_ic.a`, `manifest.json`, and
`SHA256SUMS` to [`wasm32-wasip1/`](./wasm32-wasip1/). The archive is a committed
distribution artifact (about 1.1 MiB). The SQLite compile flags are pinned in
[`build-flags.txt`](./build-flags.txt). The IC VFS shim and the SQLite helpers
are not built here: they are compiled by the consumer build through
`src/ic_sqlite/ffi/linkage.nim`.
