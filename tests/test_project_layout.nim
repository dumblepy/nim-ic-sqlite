import std/[os, unittest]
import ic_sqlite

suite "ic_sqlite project scaffold":
  test "public module is importable":
    check IcSqliteVersion == "0.1.0"
    check declared(initDatabase)

  test "required Phase 0 directories exist":
    for path in [
      "build", "scripts", "vendor/sqlite", "c",
      "src/ic_sqlite/ffi", "src/ic_sqlite/vfs",
      "src/ic_sqlite/stable", "tests/test_upgrade",
      "examples/minimal_kv"
    ]:
      check dirExists(path)

  test "prebuilt C distribution artifacts exist":
    for path in [
      "vendor/sqlite/build-flags.txt",
      "vendor/sqlite/wasm32-wasip1/libsqlite3_ic.a",
      "vendor/sqlite/wasm32-wasip1/manifest.json",
      "vendor/sqlite/wasm32-wasip1/SHA256SUMS",
      "src/ic_sqlite/ffi/linkage.nim",
      "integration/consumer/src/main.nim"
    ]:
      check fileExists(path)
