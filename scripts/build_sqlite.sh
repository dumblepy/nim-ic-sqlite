#!/usr/bin/env bash
# Build the pinned SQLite amalgamation for the ICP wasm32-wasip1 (WASI
# preview 1) target. wasi-sdk >= 30 deprecates the old `wasm32-wasi` triple.
set -euo pipefail

readonly SQLITE_VERSION="3.53.4"
readonly SQLITE_SOURCE="vendor/sqlite/sqlite3.c"
readonly SQLITE_HEADER="vendor/sqlite/sqlite3.h"
# Keep target-specific link inputs beside the vendored amalgamation.  This
# mirrors the vendor-first layout used by nim-rustcrypto and gives canister
# config.nims one stable directory to reference.
readonly ARTIFACT_DIR="vendor/sqlite/wasm32-wasi"

: "${WASI_SDK_PATH:?WASI_SDK_PATH must point to a WASI SDK installation}"
readonly CC="${WASI_SDK_PATH}/bin/clang"
readonly AR="${WASI_SDK_PATH}/bin/llvm-ar"

[[ -x "$CC" ]] || { echo "WASI clang not found: $CC" >&2; exit 1; }
[[ -x "$AR" ]] || { echo "WASI llvm-ar not found: $AR" >&2; exit 1; }
[[ -f "$SQLITE_SOURCE" && -f "$SQLITE_HEADER" ]] || {
  echo "SQLite ${SQLITE_VERSION} amalgamation is missing from vendor/sqlite" >&2
  exit 1
}
grep -Fq "#define SQLITE_VERSION        \"${SQLITE_VERSION}\"" "$SQLITE_HEADER" || {
  echo "vendor/sqlite does not contain SQLite ${SQLITE_VERSION}" >&2
  exit 1
}

mkdir -p "$ARTIFACT_DIR"
"$CC" \
  --target=wasm32-wasip1 \
  -Os \
  -std=c99 \
  -c "$SQLITE_SOURCE" \
  -o "$ARTIFACT_DIR/sqlite3.o" \
  -DSQLITE_CORE \
  -DSQLITE_DEFAULT_FOREIGN_KEYS=1 \
  -DSQLITE_ENABLE_API_ARMOR \
  -DSQLITE_ENABLE_FTS5 \
  -DSQLITE_USE_URI \
  -DSQLITE_OS_OTHER=1 \
  -DSQLITE_THREADSAFE=0 \
  -DSQLITE_OMIT_WAL \
  -DSQLITE_TEMP_STORE=3 \
  -DSQLITE_OMIT_LOCALTIME \
  -DSQLITE_OMIT_DEPRECATED \
  -DSQLITE_OMIT_LOAD_EXTENSION \
  -DSQLITE_OMIT_SHARED_CACHE \
  -DSQLITE_DEFAULT_MEMSTATUS=0

"$AR" rcs "$ARTIFACT_DIR/libsqlite3_ic.a" "$ARTIFACT_DIR/sqlite3.o"

# Canister config.nims links these objects from ARTIFACT_DIR next to the SQLite
# archive. They must use the same wasm32-wasip1 target; host-compiled objects
# cannot be linked into a canister wasm module.
"$CC" \
  --target=wasm32-wasip1 \
  -Os \
  -std=c99 \
  -Ivendor/sqlite \
  -Ic \
  -c c/ic_sqlite_vfs_shim.c \
  -o "$ARTIFACT_DIR/ic_sqlite_vfs_shim.o"

"$CC" \
  --target=wasm32-wasip1 \
  -Os \
  -std=c99 \
  -Ivendor/sqlite \
  -Ic \
  -c c/sqlite_helpers.c \
  -o "$ARTIFACT_DIR/sqlite_helpers.o"

echo "built $ARTIFACT_DIR/libsqlite3_ic.a and C shims (SQLite ${SQLITE_VERSION}, wasm32-wasip1)"
