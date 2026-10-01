import std/unittest
import ic_sqlite/ffi/sqlite_api

suite "SQLite FFI declarations":
  test "exports the VFS open flags and step result constants":
    check (SqliteOpenReadWrite or SqliteOpenCreate) == 6
    check SqliteRow == 100
    check SqliteDone == 101
    check SqliteDbStatusCacheUsed == 1
