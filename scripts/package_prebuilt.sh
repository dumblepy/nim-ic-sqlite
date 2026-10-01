#!/usr/bin/env bash
# Build the versioned prebuilt distribution tarball for a release
# (17-fix-dir branch rule section 15.1).
#
# Usage: ./scripts/package_prebuilt.sh [version]
# The version defaults to the `version` field in ic_sqlite.nimble.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

readonly TARGET="wasm32-wasip1"
readonly ARTIFACT_DIR="vendor/sqlite/${TARGET}"
readonly DIST_DIR="dist"

version="${1:-}"
if [[ -z "$version" ]]; then
  version="$(sed -nE 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' ic_sqlite.nimble | head -n1)"
fi
[[ -n "$version" ]] || { echo "cannot determine package version" >&2; exit 1; }

readonly NAME="ic-sqlite-prebuilt-v${version}-${TARGET}"
readonly TARBALL="${DIST_DIR}/${NAME}.tar.gz"

[[ -f "${ARTIFACT_DIR}/libsqlite3_ic.a" ]] || {
  echo "prebuilt archive is missing; run ./scripts/build_sqlite.sh first" >&2
  exit 1
}
[[ -f "${ARTIFACT_DIR}/SHA256SUMS" ]] || {
  echo "SHA256SUMS is missing; run ./scripts/build_sqlite.sh first" >&2
  exit 1
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
readonly STAGE="${workdir}/${NAME}"

mkdir -p "${STAGE}/lib" "${STAGE}/include" "${DIST_DIR}"
cp "${ARTIFACT_DIR}/libsqlite3_ic.a" "${STAGE}/lib/"
cp "${ARTIFACT_DIR}/manifest.json" "${STAGE}/manifest.json"
cp "${ARTIFACT_DIR}/SHA256SUMS" "${STAGE}/SHA256SUMS"
cp vendor/sqlite/sqlite3.h "${STAGE}/include/"
cp c/ic_sqlite_vfs_shim.h "${STAGE}/include/"
cp c/sqlite_helpers.h "${STAGE}/include/"

tar -C "$workdir" -czf "$TARBALL" "$NAME"
sha256sum "$TARBALL" > "${TARBALL}.sha256"

echo "packaged ${TARBALL}"

# The tarball's archive must be identical to the one committed in the repo
# (section 21). Extract and compare so packaging can never silently diverge.
readonly EXTRACTED="${workdir}/verify"
mkdir -p "$EXTRACTED"
tar -C "$EXTRACTED" -xzf "$TARBALL"
cmp "${ARTIFACT_DIR}/libsqlite3_ic.a" "${EXTRACTED}/${NAME}/lib/libsqlite3_ic.a" || {
  echo "release archive does not match the repository archive" >&2
  exit 1
}
echo "release archive matches the repository archive"
