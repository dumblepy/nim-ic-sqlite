## Public entry point for the stable-memory SQLite VFS.
##
## Low-level C and SQLite declarations remain in `ic_sqlite/ffi`.
## Applications import this module for the SQLite API and, when they place
## SQLite under an application `MemoryManager`, also
## `import nicp_cdk/storage/memory_manager` for `MemoryManager` / `MemoryId`.

import ic_sqlite/db
import ic_sqlite/transaction
import ic_sqlite/ffi/linkage
import ic_sqlite/lifecycle
import ic_sqlite/value
import ic_sqlite/typed
import ic_sqlite/query_builder
from ic_sqlite/stable/superblock import Result
export db
export transaction
export lifecycle
export value
export typed
export query_builder
export Result

const IcSqliteVersion* = "0.1.0"
