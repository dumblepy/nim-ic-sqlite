#ifndef IC_SQLITE_HELPERS_H
#define IC_SQLITE_HELPERS_H

#include "sqlite3.h"
int ic_sqlite_bind_text(sqlite3_stmt *, int, const char *, int);
int ic_sqlite_bind_blob(sqlite3_stmt *, int, const void *, int);
int ic_sqlite_bind_text_static(sqlite3_stmt *, int, const char *, int);
int ic_sqlite_bind_blob_static(sqlite3_stmt *, int, const void *, int);
#endif
