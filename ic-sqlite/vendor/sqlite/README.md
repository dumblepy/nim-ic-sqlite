# SQLite amalgamation

This directory vendors SQLite 3.53.4 from the official
`sqlite-amalgamation-3530400.zip` archive.  Its SHA3-256 is recorded in
[`SHA3-256`](./SHA3-256).  Only `sqlite3.c` and `sqlite3.h` are needed by this
library.

Rebuild the target archive with:

```sh
WASI_SDK_PATH=/root/.wasi-sdk ./scripts/build_sqlite.sh
```
