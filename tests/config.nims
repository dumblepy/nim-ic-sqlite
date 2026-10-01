import std/os

let icSqliteRoot = projectDir().parentDir
switch("path", icSqliteRoot / "src")
switch("passC", "-I" & (icSqliteRoot / "vendor/sqlite") & " -I" & (icSqliteRoot / "c"))
# Host tests compile the same C shim/helper sources that the wasm consumer
# build compiles through ic_sqlite/ffi/linkage.nim.
switch("passL", icSqliteRoot / "c/sqlite_helpers.c")
switch("passL", icSqliteRoot / "c/ic_sqlite_vfs_shim.c")
switch("passL", "/usr/lib/x86_64-linux-gnu/libsqlite3.so.0")
# Tests of the comparison tooling (profile_report, transport) use nicp_cdk.
# Prefer the checked-out CDK over whatever `nimble install` last placed.
switch("path", icSqliteRoot / "nicp_cdk" / "src")
