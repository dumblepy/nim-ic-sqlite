version       = "0.1.0"
author        = "ic-sqlite contributors"
description   = "SQLite VFS backed by Internet Computer stable memory"
license       = "MIT"
srcDir        = "src"
backend       = "c"

# The consumer build compiles the C shim/helpers and links the prebuilt SQLite
# archive from these directories, so they must survive `nimble install`
# (17-fix-dir branch rule section 18).  Nimble flattens `srcDir` on a global
# install, so the `src/c` and `src/vendor` symlinks let the whitelist installer
# carry the package-root directories into the installed tree.
installExt    = @["nim"]
installDirs   = @["c", "vendor"]

requires "nim >= 2.2.12"
# SQLite persistence depends on the nicp_cdk stable-memory infrastructure
# (`StableBackend` / `MemoryManager` / `MemoryId`).  Consumers building
# canisters provide nicp_cdk through their Nimble environment.
# nicp_cdk is not published to the Nimble registry, so pin it as a Git URL
# dependency to keep `nimble install <this repo>` self-contained.
# requires "nicp_cdk >= 0.1.0"
requires "https://github.com/dumblepy/nicp_cdk >= 0.1.0"

task test, "Run the full test suite with Testament":
  exec "./scripts/test.sh"
