#!/usr/bin/env bash
# Build the pinned SQLite amalgamation for the ICP wasm32-wasip1 (WASI
# preview 1) target.
#
# Only the SQLite static archive `libsqlite3_ic.a` is a distribution artifact
# (17-fix-dir branch rule section 2 and 10).  The IC-specific C shim and the
# SQLite helpers are shipped as C source and compiled by the consumer build
# through `src/ic_sqlite/ffi/linkage.nim`, so this script does not build them
# into the artifact directory.
set -euo pipefail

readonly SQLITE_VERSION_HEADER="vendor/sqlite/sqlite3.h"
readonly SQLITE_SOURCE="vendor/sqlite/sqlite3.c"
readonly BUILD_FLAGS_FILE="vendor/sqlite/build-flags.txt"

# Keep the target name identical to the clang triple used by the canister
# build.  `wasm32-wasi` and `wasm32-wasip1` must not be mixed (section 5.1).
readonly TARGET="wasm32-wasip1"
readonly ARTIFACT_DIR="vendor/sqlite/${TARGET}"
readonly ARCHIVE="${ARTIFACT_DIR}/libsqlite3_ic.a"

: "${WASI_SDK_PATH:?WASI_SDK_PATH must point to a WASI SDK installation}"
readonly CC="${WASI_SDK_PATH}/bin/clang"
readonly AR="${WASI_SDK_PATH}/bin/llvm-ar"

# The committed archive is built with the same WASI SDK as
# docker/test.Dockerfile so CI can byte-compare it. Warn (do not fail) when a
# developer uses a different major version; verify_prebuilt.sh then falls back
# to semantic checks.
readonly REQUIRED_WASI_SDK_MAJOR="34"
if [[ -f "${WASI_SDK_PATH}/VERSION" ]]; then
  actual_wasi_version="$(head -n1 "${WASI_SDK_PATH}/VERSION")"
  case "$actual_wasi_version" in
    ${REQUIRED_WASI_SDK_MAJOR}.*) ;;
    *)
      echo "warning: pinned WASI SDK is ${REQUIRED_WASI_SDK_MAJOR}.x but found ${actual_wasi_version};" >&2
      echo "warning: the archive may not be byte-reproducible in CI." >&2
      ;;
  esac
fi

[[ -x "$CC" ]] || { echo "WASI clang not found: $CC" >&2; exit 1; }
[[ -x "$AR" ]] || { echo "WASI llvm-ar not found: $AR" >&2; exit 1; }
[[ -f "$SQLITE_SOURCE" && -f "$SQLITE_VERSION_HEADER" ]] || {
  echo "SQLite amalgamation is missing from vendor/sqlite" >&2
  exit 1
}
[[ -f "$BUILD_FLAGS_FILE" ]] || {
  echo "SQLite build flags are missing: $BUILD_FLAGS_FILE" >&2
  exit 1
}

# Read the pinned SQLite version from the vendored header.
smatch="$(grep -F '#define SQLITE_VERSION ' "$SQLITE_VERSION_HEADER" | head -n1)"
SQLITE_VERSION="$(printf '%s' "$smatch" | sed -E 's/.*"([^"]+)".*/\1/')"
[[ -n "$SQLITE_VERSION" ]] || { echo "cannot parse SQLite version" >&2; exit 1; }

# Merge build-flags.txt into -D<flag> arguments.
defines=()
while IFS= read -r line; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | tr -d '[:space:]')"
  [[ -z "$line" ]] && continue
  defines+=("-D${line}")
done < "$BUILD_FLAGS_FILE"
[[ ${#defines[@]} -gt 0 ]] || { echo "no build flags found" >&2; exit 1; }

mkdir -p "$ARTIFACT_DIR"

# Compile the intermediate object outside the artifact directory so it is never
# distributed by `nimble install` (only the archive belongs there).
OBJ_DIR="$(mktemp -d)"
trap 'rm -rf "$OBJ_DIR"' EXIT

"$CC" \
  "--target=${TARGET}" \
  -Os \
  -std=c99 \
  -c "$SQLITE_SOURCE" \
  -o "${OBJ_DIR}/sqlite3.o" \
  "${defines[@]}"

# `rcsD` selects llvm-ar deterministic mode so the archive is reproducible.
"$AR" rcsD "$ARCHIVE" "${OBJ_DIR}/sqlite3.o"

# Refresh the checksum manifest (section 13).
(
  cd "$ARTIFACT_DIR"
  sha256sum "libsqlite3_ic.a" > SHA256SUMS
)

# Refresh the artifact metadata (section 12).  package_version is read from the
# Nimble manifest so the archive and the package stay in lockstep.
package_version="$(sed -nE 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' ic_sqlite.nimble | head -n1)"
[[ -n "$package_version" ]] || package_version="0.0.0"
cat > "${ARTIFACT_DIR}/manifest.json" <<JSON
{
  "package": "ic_sqlite",
  "package_version": "${package_version}",
  "sqlite_version": "${SQLITE_VERSION}",
  "target": "${TARGET}",
  "archive": "libsqlite3_ic.a",
  "build_profile": "ic-canister",
  "threadsafe": false,
  "wal": false,
  "fts5": true
}
JSON

echo "built ${ARCHIVE} (SQLite ${SQLITE_VERSION}, ${TARGET})"
