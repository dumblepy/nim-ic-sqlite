version       = "0.1.0"
author        = "ic-sqlite contributors"
description   = "SQLite VFS backed by Internet Computer stable memory"
license       = "MIT"
srcDir        = "src"
backend       = "c"
bin           = @["ic_sqlite"]

requires "nim >= 2.2.12"
# The ICP backend is intentionally kept behind src/ic_sqlite/stable/.
# Consumers building canisters provide nicp_cdk through their Nimble environment.
requires "nicp_cdk >= 0.1.0"

task test, "Run native unit tests":
  # Nim cache entries include a program's reachable module graph.  Keep one
  # cache per test executable so partial graphs cannot be reused by another.
  exec "nim c -r --path:src --nimcache:build/nimcache/test_project_layout tests/test_project_layout.nim"
  exec "nim c -r --path:src --nimcache:build/nimcache/test_stable_backend tests/test_stable_backend.nim"
  exec "nim c -r --path:src --nimcache:build/nimcache/test_superblock tests/test_superblock.nim"
  exec "nim c -r --path:src --nimcache:build/nimcache/test_overlay tests/test_overlay.nim"
  exec "nim c -r --path:src --nimcache:build/nimcache/test_temp_file tests/test_temp_file.nim"
  exec "nim c -r --path:src --nimcache:build/nimcache/test_vfs tests/test_vfs.nim"
  exec "nim c -r --path:src --nimcache:build/nimcache/test_vfs_exports tests/test_vfs_exports.nim"
  exec "nim c -r --path:src --nimcache:build/nimcache/test_sqlite_api tests/test_sqlite_api.nim"
  exec "nim c -r --path:src --nimcache:build/nimcache/test_db_api tests/test_db_api.nim"
  exec "nim c -r --path:src --nimcache:build/nimcache/test_typed_row tests/test_typed_row.nim"
  exec "nim c -r --path:src --nimcache:build/nimcache/test_query_compiler tests/test_query_compiler.nim"
  exec "nim c -r --path:src --nimcache:build/nimcache/test_query_builder tests/test_query_builder.nim"
  exec "nim c -r --path:src --nimcache:build/nimcache/test_typed_write tests/test_typed_write.nim"
  exec "nim c -r --path:src --nimcache:build/nimcache/test_query_transaction tests/test_query_transaction.nim"
