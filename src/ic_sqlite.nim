## Public entry point for the stable-memory SQLite VFS.
##
## Low-level C and SQLite declarations will remain in `ic_sqlite/ffi`.
## Applications should import only this module.

import ic_sqlite/db
import ic_sqlite/transaction
import ic_sqlite/ffi/linkage
import ic_sqlite/lifecycle
import ic_sqlite/value
import ic_sqlite/typed
import ic_sqlite/query_builder
import ic_sqlite/stable/memory_manager
from ic_sqlite/stable/superblock import Result
export db
export transaction
export lifecycle
export value
export typed
export query_builder
export memory_manager
export Result

const IcSqliteVersion* = "0.1.0"
