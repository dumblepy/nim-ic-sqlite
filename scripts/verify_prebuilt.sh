#!/usr/bin/env bash
# Verify that the committed prebuilt SQLite archive can be reproduced from the
# vendored source and build-flags.txt, and that its checksum and symbols match
# (17-fix-dir branch rule sections 14.2, 14.3 and 21).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

readonly TARGET="wasm32-wasip1"
readonly ARTIFACT_DIR="vendor/sqlite/${TARGET}"
readonly ARCHIVE="${ARTIFACT_DIR}/libsqlite3_ic.a"

: "${WASI_SDK_PATH:?WASI_SDK_PATH must point to a WASI SDK installation}"
readonly NM="${WASI_SDK_PATH}/bin/llvm-nm"

[[ -f "$ARCHIVE" ]] || {
  echo "committed prebuilt archive is missing: $ARCHIVE" >&2
  exit 1
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cp "$ARCHIVE" "${workdir}/committed.a"

# 1. The committed checksum must match the committed archive.
( cd "$ARTIFACT_DIR" && sha256sum -c SHA256SUMS )

# 2. Rebuild from source + build-flags.txt and require a byte-for-byte match.
./scripts/build_sqlite.sh
if ! cmp "${workdir}/committed.a" "$ARCHIVE"; then
  echo "prebuilt archive is not reproducible from source" >&2
  exit 1
fi
( cd "$ARTIFACT_DIR" && sha256sum -c SHA256SUMS )

# 3. Metadata must describe the target this directory is named for.
grep -q "\"target\": \"${TARGET}\"" "${ARTIFACT_DIR}/manifest.json" || {
  echo "manifest.json target does not match ${TARGET}" >&2
  exit 1
}

# 4. Symbol audit: the archive must export the SQLite entry points the Nim FFI
#    links against.
"$NM" "$ARCHIVE" > "${workdir}/symbols.txt"
for sym in sqlite3_open_v2 sqlite3_prepare_v2 sqlite3_step sqlite3_exec; do
  if ! grep -q "[[:space:]]T[[:space:]]${sym}\$" "${workdir}/symbols.txt"; then
    echo "archive is missing exported symbol: ${sym}" >&2
    exit 1
  fi
done

echo "verified reproducible prebuilt archive (${TARGET})"
