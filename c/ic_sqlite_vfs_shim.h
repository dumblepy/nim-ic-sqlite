#ifndef IC_SQLITE_VFS_SHIM_H
#define IC_SQLITE_VFS_SHIM_H

#include <stdint.h>
#include "../vendor/sqlite/sqlite3.h"

typedef struct IcFile {
  sqlite3_file base; /* Must be first: SQLite owns this prefix. */
  uint32_t handle_id;
} IcFile;

int ic_sqlite_register_vfs(void);

extern sqlite3_vfs IC_VFS;

#endif
