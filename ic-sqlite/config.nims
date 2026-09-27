when defined(wasm32):
  switch("passC", "-I" & projectDir / "vendor/sqlite")
  switch("passC", "-I" & projectDir / "c")
  switch("passL", projectDir / "build/libsqlite3_ic.a")
  switch("passL", projectDir / "build/ic_sqlite_vfs_shim.o")
  switch("passL", projectDir / "build/sqlite_helpers.o")
