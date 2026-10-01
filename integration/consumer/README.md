# Consumer integration smoke test

This directory is a minimal canister project used by CI to verify that a
consumer can build against `ic_sqlite` with **no** SQLite include path, shim
path, or archive path in its own configuration (17-fix-dir branch rule
section 14.4).

`src/main.nim` imports the public `ic_sqlite` module plus
`nicp_cdk/storage/memory_manager`, builds a `DbStorage` from a `MemoryManager`,
and references the VFS shim symbol, so the build must pick up the C sources and
the prebuilt `libsqlite3_ic.a` through `src/ic_sqlite/ffi/linkage.nim`.

Run it after installing the package into the active Nimble environment:

```sh
tmpdir="$(mktemp -d)"
cp -r integration/consumer/* "$tmpdir"
cd "$tmpdir"
nim c main.nim
```

In CI this runs inside the test image, which provides `WASI_SDK_PATH` and
`IC_WASI_POLYFILL_PATH`.
