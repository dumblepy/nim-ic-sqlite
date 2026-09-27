#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

./scripts/install.sh
./scripts/build_sqlite.sh
testament --print --megatest:off p 'tests/test_*.nim'
