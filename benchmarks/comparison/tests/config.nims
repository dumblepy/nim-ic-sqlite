import std/os

let icSqliteRoot = projectDir().parentDir.parentDir.parentDir
switch("path", icSqliteRoot / "src")
switch("passC", "-I" & (icSqliteRoot / "vendor/sqlite") & " -I" & (icSqliteRoot / "c"))
switch("passL", icSqliteRoot / "c/sqlite_helpers.c")
switch("passL", icSqliteRoot / "c/ic_sqlite_vfs_shim.c")
switch("passL", "/usr/lib/x86_64-linux-gnu/libsqlite3.so.0")
switch("path", "/application/nicp_cdk/src")
