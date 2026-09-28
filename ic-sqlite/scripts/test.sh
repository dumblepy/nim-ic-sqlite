#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

./scripts/install.sh
./scripts/build_sqlite.sh
testament --print --megatest:off p 'tests/test_*.nim'
nim c -r benchmarks/comparison/tests/test_keys.nim
nim c -r benchmarks/comparison/tests/test_report.nim
nim c -r benchmarks/comparison/tests/test_storage_stats.nim
nim c -r benchmarks/comparison/tests/test_failure_atomicity.nim
nim c -r benchmarks/comparison/tests/test_zero_extent_persistence.nim
nim c -r benchmarks/comparison/tests/test_memory_region.nim
nim c -r benchmarks/comparison/tests/test_cost_model.nim
nim c -r benchmarks/comparison/tests/test_result_validation.nim
