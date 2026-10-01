#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Design 19-use-nicp_cdk-memory-management section 37: the repository must not
# define its own stable-memory allocator. nicp_cdk is the single source of truth.
if grep -R -E 'type[[:space:]]+(MemoryManager|StableBackend|VirtualStableBackend)' src/ic_sqlite; then
  echo "duplicate stable-memory implementation found" >&2
  exit 1
fi

./scripts/install.sh
./scripts/verify_prebuilt.sh
testament --print --megatest:off p 'tests/test_*.nim'
