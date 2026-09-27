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
