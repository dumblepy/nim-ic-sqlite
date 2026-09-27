#!/usr/bin/env sh
set -eu

# compose.test.yaml bind-mounts the checkout after the image has been built.
# Produce all wasm linker inputs in that mounted checkout before running the
# requested test command.
if [ -x /application/ic-sqlite/scripts/build_sqlite.sh ]; then
  cd /application/ic-sqlite
  ./scripts/build_sqlite.sh
fi

exec "$@"
