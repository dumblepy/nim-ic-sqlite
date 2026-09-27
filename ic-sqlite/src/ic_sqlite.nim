## Public entry point for the stable-memory SQLite VFS.
##
## Low-level C and SQLite declarations will remain in `ic_sqlite/ffi`.
## Applications should import only this module.

import ic_sqlite/db
from ic_sqlite/stable/superblock import Result
export db
export Result

const IcSqliteVersion* = "0.1.0"
