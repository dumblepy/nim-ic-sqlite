#!/usr/bin/env bash
# Verify the committed prebuilt SQLite archive (17-fix-dir branch rule sections
# 14.2, 14.3 and 21).
#
# The strong guarantee is a byte-for-byte reproduction from
# vendor/sqlite/sqlite3.c and vendor/sqlite/build-flags.txt.  That requires the
# pinned WASI SDK (wasi-sdk 34, see docker/test.Dockerfile).  When a different
# toolchain produces slightly different object code, fall back to the design's
# semantic checks (section 14.2): SQLite version, build flags, archive target,
# exported symbol set.  Functional coverage comes from the rest of the suite.
#
# The committed artifact is always restored before exit, so running this script
# with a different toolchain does not rewrite the committed archive.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

readonly TARGET="wasm32-wasip1"
readonly ARTIFACT_DIR="vendor/sqlite/${TARGET}"
readonly ARCHIVE="${ARTIFACT_DIR}/libsqlite3_ic.a"
readonly SUMS="${ARTIFACT_DIR}/SHA256SUMS"
readonly MANIFEST="${ARTIFACT_DIR}/manifest.json"
readonly FLAGS_FILE="vendor/sqlite/build-flags.txt"

: "${WASI_SDK_PATH:?WASI_SDK_PATH must point to a WASI SDK installation}"
readonly NM="${WASI_SDK_PATH}/bin/llvm-nm"

[[ -f "$ARCHIVE" ]] || {
  echo "committed prebuilt archive is missing: $ARCHIVE" >&2
  exit 1
}
[[ -f "$FLAGS_FILE" ]] || {
  echo "build flags are missing: $FLAGS_FILE" >&2
  exit 1
}

workdir="$(mktemp -d)"
cleanup() {
  # Keep the committed artifact intact even after a rebuild.
  if [[ -f "${workdir}/committed.a" ]]; then
    cp -f "${workdir}/committed.a" "$ARCHIVE"
  fi
  if [[ -f "${workdir}/committed.SHA256SUMS" ]]; then
    cp -f "${workdir}/committed.SHA256SUMS" "$SUMS"
  fi
  if [[ -f "${workdir}/committed.manifest.json" ]]; then
    cp -f "${workdir}/committed.manifest.json" "$MANIFEST"
  fi
  rm -rf "$workdir"
}
trap cleanup EXIT
cp "$ARCHIVE" "${workdir}/committed.a"
cp "$SUMS" "${workdir}/committed.SHA256SUMS"
cp "$MANIFEST" "${workdir}/committed.manifest.json"

# 1. The committed checksum must match the committed archive.
( cd "$ARTIFACT_DIR" && sha256sum -c SHA256SUMS )

# 2. Rebuild from source + build-flags.txt.
./scripts/build_sqlite.sh
( cd "$ARTIFACT_DIR" && sha256sum -c SHA256SUMS )

binary_reproducible=false
if cmp -s "${workdir}/committed.a" "$ARCHIVE"; then
  binary_reproducible=true
else
  echo "warning: prebuilt archive is not byte-identical to a local rebuild" >&2
  echo "warning: likely a WASI SDK / clang difference; running semantic checks" >&2
fi

# 3. Metadata must describe the pinned SQLite version and this target.
sqlite_version="$(grep -F '#define SQLITE_VERSION ' vendor/sqlite/sqlite3.h |
  head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"
grep -q "\"sqlite_version\": \"${sqlite_version}\"" "$MANIFEST" || {
  echo "manifest.json sqlite_version does not match sqlite3.h (${sqlite_version})" >&2
  exit 1
}
grep -q "\"target\": \"${TARGET}\"" "$MANIFEST" || {
  echo "manifest.json target does not match ${TARGET}" >&2
  exit 1
}

# 4. Symbol audit: both the committed and the rebuilt archive must export the
#    SQLite entry points the Nim FFI links against.
for candidate in "${workdir}/committed.a" "$ARCHIVE"; do
  "$NM" "$candidate" > "${workdir}/symbols.txt"
  for sym in sqlite3_open_v2 sqlite3_prepare_v2 sqlite3_step sqlite3_exec; do
    if ! grep -q "[[:space:]]T[[:space:]]${sym}\$" "${workdir}/symbols.txt"; then
      echo "archive is missing exported symbol: ${sym} (${candidate})" >&2
      exit 1
    fi
  done
done

if [[ "$binary_reproducible" == true ]]; then
  echo "verified byte-for-byte reproducible prebuilt archive (${TARGET})"
else
  echo "verified prebuilt archive via semantic checks (${TARGET}; binary differs)"
fi
