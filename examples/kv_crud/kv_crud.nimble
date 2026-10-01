# Package

version       = "0.1.0"
author        = "ic-sqlite contributors"
description   = "ic-sqlite CRUD example canister with migrations and upgrade persistence"
license       = "MIT"
srcDir        = "backend/src"
bin           = @["main"]


# Dependencies

requires "nim >= 2.2.12"
requires "https://github.com/dumblepy/nicp_cdk >= 0.1.0"
