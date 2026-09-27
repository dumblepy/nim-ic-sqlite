version       = "0.1.0"
author        = "ic-sqlite contributors"
description   = "Minimal stable-memory SQLite key-value canister"
license       = "MIT"
srcDir        = "backend/src"
bin           = @["main"]

requires "nim >= 2.2.12"
requires "nicp_cdk >= 0.1.0"
