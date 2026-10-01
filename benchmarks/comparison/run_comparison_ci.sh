#!/usr/bin/env bash
# P5 CI regression: build both benchmark Wasm files and run a short paired
# core-KV comparison on a fresh local icp network, then validate results.
# The full 5-trial / 100-churn runs remain manual; CI keeps the build and the
# paired-shape regression fast (single trial, 100 rows).
set -euo pipefail

comparison_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$comparison_dir"

# CI measures the checked-out source tree (PR commit); the runner pins the
# Rust benchmark to its pinned commit via prepare_rust.sh.
export NISQL_COMPARE_NIM_SHA=HEAD

# 1. Build the pinned Rust benchmark Wasm (with rust_host_stats.patch).
./prepare_rust.sh

# 2. Build the Nim benchmark Wasm from the checked-out sources.
(
  cd "$comparison_dir/nim_canister/backend"
  nicp productionBuild
)
test -f "$comparison_dir/nim_canister/backend/main.wasm"

# 3. Build the runner and validator from the checked-out sources.
nim c -d:release "$comparison_dir/runner/main.nim"
nim c -d:release "$comparison_dir/runner/validate.nim"

# 4. Run one trial of the paired core-KV comparison (reset/read/update).
#    The network is started and stopped by the runner itself.
./main 1

result_dir=$(ls -dt "$comparison_dir"/results/*/ | head -n 1)
echo "comparison result dir: $result_dir"

# 5. Mechanically validate completeness of the paired measurements.
./validate "$result_dir"

# 6. Keep the run manifest traceability files available for CI logs.
cat "$result_dir/manifest.json"
