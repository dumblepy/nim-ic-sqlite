## Consumer-side linkage for the vendored SQLite C dependency.
##
## Applications only need `import ic_sqlite`; the public entry point imports
## this module internally (17-fix-dir branch rule section 8.2).  The package
## root is located from this module's own source path, so both a Git checkout
## (`<root>/src/ic_sqlite/ffi/linkage.nim`) and a `nimble install`
## (`<pkg>/ic_sqlite/ffi/linkage.nim`) resolve the adjacent `vendor/` and `c/`
## directories without any consumer `config.nims` setting.
##
## For wasm32 canister builds this module:
##   * adds the vendored `sqlite3.h` and the C shim include directories,
##   * compiles `c/ic_sqlite_vfs_shim.c` and `c/sqlite_helpers.c`,
##   * links the prebuilt `vendor/sqlite/wasm32-wasip1/libsqlite3_ic.a`.
##
## The shim/helper are deliberately shipped as C source and compiled here so
## the Nim FFI declarations and the C ABI cannot drift (section 7).

import std/os

proc locatePackageRoot(startDir: string): string {.compileTime.} =
  ## Walk up from the directory containing this module and return the highest
  ## ancestor that holds both `vendor/sqlite/sqlite3.h` and `c/`. Returning the
  ## highest match keeps the repository root (not the `src/vendor` install
  ## symlink) when a checkout has both.
  var dir = startDir
  var found = ""
  for _ in 0 ..< 12:
    if fileExists(dir / "vendor" / "sqlite" / "sqlite3.h") and
        dirExists(dir / "c"):
      found = dir
    let parent = parentDir(dir)
    if parent.len == 0 or parent == dir:
      break
    dir = parent
  return found

when defined(wasm32):
  const packageRoot = locatePackageRoot(currentSourcePath().parentDir)
  const sqliteDir = packageRoot / "vendor" / "sqlite"
  const artifactDir = sqliteDir / "wasm32-wasip1"
  const cDir = packageRoot / "c"
  const archive = artifactDir / "libsqlite3_ic.a"
  const shimSource = cDir / "ic_sqlite_vfs_shim.c"
  const helpersSource = cDir / "sqlite_helpers.c"

  static:
    # Fail at Nim compile time rather than with an ambiguous linker error when
    # the prebuilt archive or the C sources are missing (section 22).
    doAssert packageRoot.len > 0,
      "ic_sqlite: cannot locate package root from " & currentSourcePath()
    doAssert fileExists(archive),
      "ic_sqlite prebuilt SQLite archive is missing: " & archive
    doAssert fileExists(shimSource),
      "ic_sqlite C VFS shim is missing: " & shimSource
    doAssert fileExists(helpersSource),
      "ic_sqlite C SQLite helpers are missing: " & helpersSource

  {.passC: "-I" & sqliteDir.}
  {.passC: "-I" & cDir.}
  {.compile: shimSource.}
  {.compile: helpersSource.}
  {.passL: archive.}
