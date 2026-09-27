import std/os

let icSqliteRoot = projectDir().parentDir
switch("path", icSqliteRoot / "src")
# Host tests link the same SQLITE_TRANSIENT wrapper that the wasm build links
# as build/sqlite_helpers.o.
switch("passL", icSqliteRoot / "c/sqlite_helpers.c")
switch("passL", "/usr/lib/x86_64-linux-gnu/libsqlite3.so.0")
