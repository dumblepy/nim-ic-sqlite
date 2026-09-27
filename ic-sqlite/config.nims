when defined(wasm32):
  let sqliteWasiArtifacts = projectDir / "vendor" / "sqlite" / "wasm32-wasi"
  switch("passC", "-I" & projectDir / "vendor/sqlite")
  switch("passC", "-I" & projectDir / "c")
  switch("passL", sqliteWasiArtifacts / "libsqlite3_ic.a")
  switch("passL", sqliteWasiArtifacts / "ic_sqlite_vfs_shim.o")
  switch("passL", sqliteWasiArtifacts / "sqlite_helpers.o")
