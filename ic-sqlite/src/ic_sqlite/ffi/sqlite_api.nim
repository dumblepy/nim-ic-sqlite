## SQLite C declarations. This is intentionally the only Nim module that
## exposes SQLite pointers and C API details.
{.passC: "-Ivendor/sqlite -Ic".}

type
  Sqlite3* {.importc: "sqlite3", header: "sqlite3.h", incompleteStruct.} = object
  Sqlite3Stmt* {.importc: "sqlite3_stmt", header: "sqlite3.h", incompleteStruct.} = object

const
  SqliteOk* = 0.cint
  SqliteRow* = 100.cint
  SqliteDone* = 101.cint
  SqliteInteger* = 1.cint
  SqliteFloat* = 2.cint
  SqliteText* = 3.cint
  SqliteBlob* = 4.cint
  SqliteNull* = 5.cint
  SqliteOpenReadOnly* = 0x00000001.cint
  SqliteOpenReadWrite* = 0x00000002.cint
  SqliteOpenCreate* = 0x00000004.cint
  SqliteOpenUri* = 0x00000040.cint
  SqliteOpenNoMutex* = 0x00008000.cint
  SqliteDbStatusCacheUsed* = 1.cint

proc sqlite3_open_v2*(filename: cstring; db: ptr ptr Sqlite3; flags: cint; vfs: cstring): cint
  {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_close*(db: ptr Sqlite3): cint {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_prepare_v2*(db: ptr Sqlite3; sql: cstring; nByte: cint; stmt: ptr ptr Sqlite3Stmt; tail: pointer): cint
  {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_finalize*(stmt: ptr Sqlite3Stmt): cint {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_step*(stmt: ptr Sqlite3Stmt): cint {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_reset*(stmt: ptr Sqlite3Stmt): cint {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_clear_bindings*(stmt: ptr Sqlite3Stmt): cint {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_bind_null*(stmt: ptr Sqlite3Stmt; index: cint): cint {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_bind_int64*(stmt: ptr Sqlite3Stmt; index: cint; value: int64): cint {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_bind_double*(stmt: ptr Sqlite3Stmt; index: cint; value: cdouble): cint {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_bind_parameter_count*(stmt: ptr Sqlite3Stmt): cint {.importc, cdecl, header: "sqlite3.h".}
proc ic_sqlite_bind_text*(stmt: ptr Sqlite3Stmt; index: cint; value: cstring; length: cint): cint {.importc, cdecl, header: "sqlite_helpers.h".}
proc ic_sqlite_bind_blob*(stmt: ptr Sqlite3Stmt; index: cint; value: pointer; length: cint): cint {.importc, cdecl, header: "sqlite_helpers.h".}
proc ic_sqlite_bind_text_static*(stmt: ptr Sqlite3Stmt; index: cint; value: cstring; length: cint): cint {.importc, cdecl, header: "sqlite_helpers.h".}
proc ic_sqlite_bind_blob_static*(stmt: ptr Sqlite3Stmt; index: cint; value: pointer; length: cint): cint {.importc, cdecl, header: "sqlite_helpers.h".}
proc sqlite3_column_count*(stmt: ptr Sqlite3Stmt): cint {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_column_name*(stmt: ptr Sqlite3Stmt; index: cint): cstring {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_column_type*(stmt: ptr Sqlite3Stmt; index: cint): cint {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_column_int64*(stmt: ptr Sqlite3Stmt; index: cint): int64 {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_column_double*(stmt: ptr Sqlite3Stmt; index: cint): cdouble {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_column_text*(stmt: ptr Sqlite3Stmt; index: cint): cstring {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_column_blob*(stmt: ptr Sqlite3Stmt; index: cint): pointer {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_column_bytes*(stmt: ptr Sqlite3Stmt; index: cint): cint {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_errmsg*(db: ptr Sqlite3): cstring {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_errcode*(db: ptr Sqlite3): cint {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_extended_errcode*(db: ptr Sqlite3): cint {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_stmt_readonly*(stmt: ptr Sqlite3Stmt): cint {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_changes*(db: ptr Sqlite3): cint {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_last_insert_rowid*(db: ptr Sqlite3): int64 {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_db_status*(db: ptr Sqlite3; op: cint; current, highwater: ptr cint;
                        resetFlag: cint): cint {.importc, cdecl, header: "sqlite3.h".}
proc sqlite3_exec*(db: ptr Sqlite3; sql: cstring; callback: pointer; argument: pointer; errorMessage: ptr cstring): cint
  {.importc, cdecl, header: "sqlite3.h".}
proc ic_sqlite_register_vfs*(): cint {.importc, cdecl, header: "ic_sqlite_vfs_shim.h".}
