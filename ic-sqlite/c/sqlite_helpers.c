#include "../vendor/sqlite/sqlite3.h"

int ic_sqlite_bind_text(sqlite3_stmt *stmt, int index, const char *data, int length) {
  return sqlite3_bind_text(stmt, index, data, length, SQLITE_TRANSIENT);
}

int ic_sqlite_bind_blob(sqlite3_stmt *stmt, int index, const void *data, int length) {
  return sqlite3_bind_blob(stmt, index, data, length, SQLITE_TRANSIENT);
}

int ic_sqlite_bind_text_static(sqlite3_stmt *stmt, int index, const char *data, int length) {
  return sqlite3_bind_text(stmt, index, data, length, SQLITE_STATIC);
}

int ic_sqlite_bind_blob_static(sqlite3_stmt *stmt, int index, const void *data, int length) {
  return sqlite3_bind_blob(stmt, index, data, length, SQLITE_STATIC);
}
