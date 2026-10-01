#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

./scripts/install.sh
./scripts/verify_prebuilt.sh
testament --print --megatest:off p 'tests/test_*.nim'
