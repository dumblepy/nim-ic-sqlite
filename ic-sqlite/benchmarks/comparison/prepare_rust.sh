#!/usr/bin/env bash
set -euo pipefail

comparison_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rust_dir="$comparison_dir/.cache/ic-sqlite-vfs"
expected_sha=1386239acff1dd7ede5ac78a2f0a22ef495195de

if [[ ! -d "$rust_dir/.git" ]]; then
  git clone https://github.com/humandebri/ic-sqlite-vfs.git "$rust_dir"
fi
git -C "$rust_dir" checkout --detach "$expected_sha"
actual_sha="$(git -C "$rust_dir" rev-parse HEAD)"
if [[ "$actual_sha" != "$expected_sha" ]]; then
  echo "Rust source SHA mismatch" >&2
  exit 1
fi
patch_file="$comparison_dir/rust_host_stats.patch"
if ! git -C "$rust_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
  git -C "$rust_dir" apply --check "$patch_file"
  git -C "$rust_dir" apply "$patch_file"
fi
rustup target add wasm32-unknown-unknown
(
  cd "$rust_dir/benchmarks/kv-canister"
  cargo build --locked --target wasm32-unknown-unknown --release
)
echo "$rust_dir/benchmarks/kv-canister/target/wasm32-unknown-unknown/release/ic_sqlite_vfs_kv_bench.wasm"
