version       = "0.1.0"
author        = "ic-sqlite contributors"
description   = "SQLite VFS backed by Internet Computer stable memory"
license       = "MIT"
srcDir        = "src"
backend       = "c"

requires "nim >= 2.2.12"
# The ICP backend is intentionally kept behind src/ic_sqlite/stable/.
# Consumers building canisters provide nicp_cdk through their Nimble environment.
requires "nicp_cdk >= 0.1.0"

task test, "Run the full test suite with Testament":
  exec "./scripts/test.sh"
