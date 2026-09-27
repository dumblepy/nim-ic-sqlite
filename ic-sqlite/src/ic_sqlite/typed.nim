## Typed SQLite row decoding.  Values are copied while SQLite owns the row.
import std/[options, typetraits]
import ./db
import ./value
import ./stable/superblock
import ./ffi/sqlite_api

proc decodeError(kind: DbErrorKind; message, expected, actual: string;
                 column = ""; rowIndex = -1): DbError =
  DbError(code: -1, message: message, kind: kind, column: column,
    expectedType: expected, actualType: actual, rowIndex: rowIndex)

proc storageName(kind: cint): string =
  case kind
  of SqliteInteger: "INTEGER"
  of SqliteFloat: "REAL"
  of SqliteText: "TEXT"
  of SqliteBlob: "BLOB"
  of SqliteNull: "NULL"
  else: "unknown"

proc readColumn*[T](statement: Statement; index: int; typ: typedesc[T]): Result[T, DbError] =
  let actual = statement.columnType(index)
  if actual == SqliteNull:
    when T is Option:
      return Result[T, DbError](isOk: true, value: none(typeof(default(T).get)))
    else:
      return Result[T, DbError](isOk: false, error: decodeError(dekNullViolation,
        "NULL cannot be decoded into a non-optional field", name(T), "NULL"))
  when T is Option:
    type Inner = typeof(default(T).get)
    let inner = readColumn(statement, index, Inner)
    if not inner.isOk: return Result[T, DbError](isOk: false, error: inner.error)
    return Result[T, DbError](isOk: true, value: some(inner.value))
  elif T is int64:
    if actual != SqliteInteger: return Result[T, DbError](isOk: false, error: decodeError(dekTypeMismatch, "SQLite type mismatch", "INTEGER", storageName(actual)))
    return Result[T, DbError](isOk: true, value: statement.columnInt64(index))
  elif T is int or T is int8 or T is int16 or T is int32:
    if actual != SqliteInteger: return Result[T, DbError](isOk: false, error: decodeError(dekTypeMismatch, "SQLite type mismatch", "INTEGER", storageName(actual)))
    let value = statement.columnInt64(index)
    if value < int64(low(T)) or value > int64(high(T)):
      return Result[T, DbError](isOk: false, error: decodeError(dekOverflow, "integer value is out of range", name(T), "INTEGER"))
    return Result[T, DbError](isOk: true, value: T(value))
  elif T is float64:
    if actual != SqliteFloat and actual != SqliteInteger: return Result[T, DbError](isOk: false, error: decodeError(dekTypeMismatch, "SQLite type mismatch", "REAL or INTEGER", storageName(actual)))
    return Result[T, DbError](isOk: true, value: statement.columnFloat64(index))
  elif T is float32:
    if actual != SqliteFloat and actual != SqliteInteger: return Result[T, DbError](isOk: false, error: decodeError(dekTypeMismatch, "SQLite type mismatch", "REAL or INTEGER", storageName(actual)))
    let value = statement.columnFloat64(index)
    if value < float64(low(float32)) or value > float64(high(float32)):
      return Result[T, DbError](isOk: false, error: decodeError(dekOverflow, "real value is out of range", "float32", storageName(actual)))
    return Result[T, DbError](isOk: true, value: float32(value))
  elif T is bool:
    if actual != SqliteInteger: return Result[T, DbError](isOk: false, error: decodeError(dekTypeMismatch, "SQLite type mismatch", "INTEGER", storageName(actual)))
    let value = statement.columnInt64(index)
    if value != 0 and value != 1: return Result[T, DbError](isOk: false, error: decodeError(dekTypeMismatch, "bool must be stored as 0 or 1", "0 or 1", $value))
    return Result[T, DbError](isOk: true, value: value == 1)
  elif T is string:
    if actual != SqliteText: return Result[T, DbError](isOk: false, error: decodeError(dekTypeMismatch, "SQLite type mismatch", "TEXT", storageName(actual)))
    return Result[T, DbError](isOk: true, value: statement.columnText(index))
  elif T is seq[byte]:
    if actual != SqliteBlob: return Result[T, DbError](isOk: false, error: decodeError(dekTypeMismatch, "SQLite type mismatch", "BLOB", storageName(actual)))
    return Result[T, DbError](isOk: true, value: statement.columnBlob(index))
  else:
    {.error: "unsupported SQLite decode type; use an int, float, bool, string, seq[byte], or Option".}

proc decodeRow*[T](statement: Statement; typ: typedesc[T]; rowIndex: int): Result[T, DbError] =
  var row: T
  var names: seq[string]
  for index in 0 ..< statement.columnCount:
    let column = statement.columnName(index)
    if column in names:
      return Result[T, DbError](isOk: false, error: decodeError(dekInvalidQuery,
        "result contains duplicate column name: " & column, "unique column names", column, column, rowIndex))
    names.add(column)
  for fieldName, field in fieldPairs(row):
    let index = names.find(fieldName)
    if index < 0:
      return Result[T, DbError](isOk: false, error: decodeError(dekColumnMissing,
        "result does not contain required field: " & fieldName, fieldName, "missing", fieldName, rowIndex))
    let decoded = readColumn(statement, index, type(field))
    if not decoded.isOk:
      var error = decoded.error
      error.column = fieldName
      error.rowIndex = rowIndex
      return Result[T, DbError](isOk: false, error: error)
    field = decoded.value
  Result[T, DbError](isOk: true, value: row)

proc rowBytes(statement: Statement): uint64 =
  for index in 0 ..< statement.columnCount:
    case statement.columnType(index)
    of SqliteText, SqliteBlob:
      let bytes = statement.columnBytes(index)
      if bytes > 0: result += uint64(bytes)
    of SqliteInteger, SqliteFloat:
      result += 8
    else:
      discard

proc readRows*[T](db: var Db; sql: string; params: openArray[SqlValue] = []): Result[seq[T], DbError] =
  let boundValues = @params
  db.withQuery(proc(conn: var Connection): Result[seq[T], DbError] =
    let prepared = conn.prepare(sql)
    if not prepared.isOk: return Result[seq[T], DbError](isOk: false, error: prepared.error)
    var statement = prepared.value
    defer: statement.finalize()
    let limits = statement.queryLimits()
    if uint64(boundValues.len) > limits.maxParams:
      return Result[seq[T], DbError](isOk: false, error: decodeError(dekResourceLimit,
        "query parameter count exceeds maxQueryParams", $limits.maxParams, $boundValues.len))
    if statement.parameterCount != boundValues.len:
      return Result[seq[T], DbError](isOk: false, error: decodeError(dekBind,
        "SQL placeholder count does not match bound values", $statement.parameterCount, $boundValues.len))
    if not statement.isReadonly:
      return Result[seq[T], DbError](isOk: false, error: decodeError(dekInvalidQuery,
        "readRows accepts read-only SQL only", "read-only statement", "write statement"))
    for index, value in boundValues:
      let bound = statement.bind(index + 1, value)
      if not bound.isOk: return Result[seq[T], DbError](isOk: false, error: bound.error)
    var rowIndex = 0
    var resultBytes = 0'u64
    while true:
      let stepped = statement.step()
      if not stepped.isOk: return Result[seq[T], DbError](isOk: false, error: stepped.error)
      if stepped.value == srDone: break
      let decoded = decodeRow(statement, T, rowIndex)
      if not decoded.isOk: return Result[seq[T], DbError](isOk: false, error: decoded.error)
      if uint64(rowIndex) >= limits.maxRows:
        return Result[seq[T], DbError](isOk: false, error: decodeError(dekResourceLimit,
          "result row count exceeds maxResultRows", $limits.maxRows, $(rowIndex + 1)))
      let bytes = rowBytes(statement)
      if bytes > limits.maxBytes - min(resultBytes, limits.maxBytes):
        return Result[seq[T], DbError](isOk: false, error: decodeError(dekResourceLimit,
          "result data exceeds maxResultBytes", $limits.maxBytes, $(resultBytes + bytes)))
      resultBytes += bytes
      result.value.add(decoded.value)
      inc rowIndex
    Result[seq[T], DbError](isOk: true, value: result.value)
  )

proc readFirst*[T](db: var Db; sql: string; params: openArray[SqlValue] = []): Result[Option[T], DbError] =
  let rows = readRows[T](db, sql, params)
  if not rows.isOk: return Result[Option[T], DbError](isOk: false, error: rows.error)
  Result[Option[T], DbError](isOk: true,
    value: if rows.value.len == 0: none(T) else: some(rows.value[0]))
