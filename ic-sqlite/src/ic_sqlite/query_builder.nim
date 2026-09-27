## Immutable method-chain query builder. SQL values are always bound.
import std/[options, strutils]
import ./db
import ./value
import ./typed
import ./stable/superblock

type
  SortOrder* = enum Asc, Desc
  PredicateKind* = enum pkCompare, pkNull, pkNotNull, pkIn, pkNotIn, pkBetween, pkGroup
  Predicate* = object
    kind*: PredicateKind
    column*: string
    op*: string
    value*: SqlValue
    values*: seq[SqlValue]
    connector*: string
    children*: seq[Predicate]
  PredicateBuilder* = object
    predicates: seq[Predicate]
  JoinClause* = object
    tableName*: string
    alias*: string
    leftColumn*: string
    op*: string
    rightColumn*: string
    leftOuter*: bool
  OrderClause* = object
    column*: string
    direction*: SortOrder
  Query* = object
    owner: ptr Db
    updateScope: TransactionLease
    tableName*: string
    tableAlias*: string
    columns*: seq[string]
    predicates*: seq[Predicate]
    joins*: seq[JoinClause]
    orders*: seq[OrderClause]
    groupColumns*: seq[string]
    havingPredicates*: seq[Predicate]
    limitValue*: Option[int64]
    offsetValue*: Option[int64]
  CompiledQuery* = object
    sql*: string
    params*: seq[SqlValue]

proc queryError(message: string): DbError =
  DbError(code: -1, message: message, kind: dekInvalidQuery)

proc quoteIdentifier*(name: string): Result[string, DbError] =
  if name.len == 0: return Result[string, DbError](isOk: false, error: queryError("identifier must not be empty"))
  var quotedParts: seq[string]
  for part in strutils.split(name, '.'):
    if part.len == 0 or not (part[0] in {'a'..'z', 'A'..'Z', '_'}):
      return Result[string, DbError](isOk: false, error: queryError("invalid SQL identifier: " & name))
    for ch in part:
      if not (ch in {'a'..'z', 'A'..'Z', '0'..'9', '_'}):
        return Result[string, DbError](isOk: false, error: queryError("invalid SQL identifier: " & name))
    quotedParts.add("\"" & part & "\"")
  Result[string, DbError](isOk: true, value: quotedParts.join("."))

proc table*(db: var Db; name: string; alias = ""): Query =
  Query(owner: addr db, tableName: name, tableAlias: alias)

proc table*(conn: var UpdateConnection; name: string; alias = ""): Query =
  Query(owner: conn.ownerDb(), updateScope: conn.transactionLease(), tableName: name, tableAlias: alias)

proc select*(q: Query; columns: varargs[string]): Query =
  result = q
  for column in columns: result.columns.add(column)

proc where*[T](q: Query; column, op: string; value: T): Query =
  result = q
  result.predicates.add(Predicate(kind: pkCompare, column: column, op: op, value: toSqlValue(value), connector: "AND"))

proc orWhere*[T](q: Query; column, op: string; value: T): Query =
  result = q
  result.predicates.add(Predicate(kind: pkCompare, column: column, op: op, value: toSqlValue(value), connector: "OR"))

proc whereNull*(q: Query; column: string): Query =
  result = q
  result.predicates.add(Predicate(kind: pkNull, column: column, connector: "AND"))

proc whereNotNull*(q: Query; column: string): Query =
  result = q
  result.predicates.add(Predicate(kind: pkNotNull, column: column, connector: "AND"))

proc whereIn*[T](q: Query; column: string; values: openArray[T]): Query =
  result = q
  var bound: seq[SqlValue]
  for value in values: bound.add(toSqlValue(value))
  result.predicates.add(Predicate(kind: pkIn, column: column, values: bound, connector: "AND"))

proc whereNotIn*[T](q: Query; column: string; values: openArray[T]): Query =
  result = q
  var bound: seq[SqlValue]
  for value in values: bound.add(toSqlValue(value))
  result.predicates.add(Predicate(kind: pkNotIn, column: column, values: bound, connector: "AND"))

proc whereBetween*[T](q: Query; column: string; low, high: T): Query =
  result = q
  result.predicates.add(Predicate(kind: pkBetween, column: column,
    values: @[toSqlValue(low), toSqlValue(high)], connector: "AND"))

proc where*[T](b: var PredicateBuilder; column, op: string; value: T) =
  b.predicates.add(Predicate(kind: pkCompare, column: column, op: op, value: toSqlValue(value), connector: "AND"))

proc orWhere*[T](b: var PredicateBuilder; column, op: string; value: T) =
  b.predicates.add(Predicate(kind: pkCompare, column: column, op: op, value: toSqlValue(value), connector: "OR"))

proc whereGroup*(q: Query; body: proc(builder: var PredicateBuilder) {.closure.}): Query =
  var builder: PredicateBuilder
  body(builder)
  result = q
  if builder.predicates.len > 0:
    result.predicates.add(Predicate(kind: pkGroup, connector: "AND", children: builder.predicates))

proc join*(q: Query; tableName, alias, leftColumn, op, rightColumn: string): Query =
  result = q
  result.joins.add(JoinClause(tableName: tableName, alias: alias, leftColumn: leftColumn, op: op, rightColumn: rightColumn))

proc leftJoin*(q: Query; tableName, alias, leftColumn, op, rightColumn: string): Query =
  result = q
  result.joins.add(JoinClause(tableName: tableName, alias: alias, leftColumn: leftColumn, op: op, rightColumn: rightColumn, leftOuter: true))

proc orderBy*(q: Query; column: string; direction = Asc): Query =
  result = q
  result.orders.add(OrderClause(column: column, direction: direction))

proc groupBy*(q: Query; columns: varargs[string]): Query =
  result = q
  for column in columns: result.groupColumns.add(column)

proc having*[T](q: Query; column, op: string; value: T): Query =
  result = q
  result.havingPredicates.add(Predicate(kind: pkCompare, column: column, op: op,
    value: toSqlValue(value), connector: "AND"))

proc limit*(q: Query; count: int64): Query =
  result = q
  result.limitValue = some(count)

proc offset*(q: Query; count: int64): Query =
  result = q
  result.offsetValue = some(count)

proc compile*(q: Query): Result[CompiledQuery, DbError] =
  let table = quoteIdentifier(q.tableName)
  if not table.isOk: return Result[CompiledQuery, DbError](isOk: false, error: table.error)
  var sql = "SELECT "
  if q.columns.len == 0:
    sql.add("*")
  else:
    for column in q.columns:
      let quoted = quoteIdentifier(column)
      if not quoted.isOk: return Result[CompiledQuery, DbError](isOk: false, error: quoted.error)
      if sql != "SELECT ": sql.add(", ")
      sql.add(quoted.value)
  sql.add(" FROM " & table.value)
  if q.tableAlias.len > 0:
    let alias = quoteIdentifier(q.tableAlias)
    if not alias.isOk: return Result[CompiledQuery, DbError](isOk: false, error: alias.error)
    sql.add(" AS " & alias.value)
  for join in q.joins:
    let tableName = quoteIdentifier(join.tableName)
    let alias = quoteIdentifier(join.alias)
    let leftColumn = quoteIdentifier(join.leftColumn)
    let rightColumn = quoteIdentifier(join.rightColumn)
    if not tableName.isOk: return Result[CompiledQuery, DbError](isOk: false, error: tableName.error)
    if not alias.isOk: return Result[CompiledQuery, DbError](isOk: false, error: alias.error)
    if not leftColumn.isOk: return Result[CompiledQuery, DbError](isOk: false, error: leftColumn.error)
    if not rightColumn.isOk: return Result[CompiledQuery, DbError](isOk: false, error: rightColumn.error)
    if join.op notin ["=", "!=", "<", "<=", ">", ">="]:
      return Result[CompiledQuery, DbError](isOk: false, error: queryError("unsupported JOIN operator: " & join.op))
    sql.add(if join.leftOuter: " LEFT JOIN " else: " JOIN ")
    sql.add(tableName.value & " AS " & alias.value & " ON " & leftColumn.value & " " & join.op & " " & rightColumn.value)
  for index, predicate in q.predicates:
    sql.add(if index == 0: " WHERE " else: " " & predicate.connector & " ")
    if predicate.kind == pkGroup:
      sql.add("(")
      for childIndex, child in predicate.children:
        if child.kind != pkCompare or child.op notin ["=", "!=", "<", "<=", ">", ">=", "LIKE"]:
          return Result[CompiledQuery, DbError](isOk: false, error: queryError("whereGroup supports comparison predicates only"))
        let childColumn = quoteIdentifier(child.column)
        if not childColumn.isOk: return Result[CompiledQuery, DbError](isOk: false, error: childColumn.error)
        if childIndex > 0: sql.add(" " & child.connector & " ")
        sql.add(childColumn.value & " " & child.op & " ?")
        result.value.params.add(child.value)
      sql.add(")")
      continue
    let column = quoteIdentifier(predicate.column)
    if not column.isOk: return Result[CompiledQuery, DbError](isOk: false, error: column.error)
    case predicate.kind
    of pkNull: sql.add(column.value & " IS NULL")
    of pkNotNull: sql.add(column.value & " IS NOT NULL")
    of pkIn, pkNotIn:
      if predicate.values.len == 0:
        sql.add(if predicate.kind == pkIn: "0" else: "1")
      else:
        sql.add(column.value & (if predicate.kind == pkIn: " IN (" else: " NOT IN ("))
        for valueIndex, value in predicate.values:
          if valueIndex > 0: sql.add(", ")
          sql.add("?")
          result.value.params.add(value)
        sql.add(")")
    of pkBetween:
      if predicate.values.len != 2:
        return Result[CompiledQuery, DbError](isOk: false, error: queryError("BETWEEN requires exactly two values"))
      sql.add(column.value & " BETWEEN ? AND ?")
      result.value.params.add(predicate.values[0])
      result.value.params.add(predicate.values[1])
    of pkCompare:
      if predicate.op notin ["=", "!=", "<", "<=", ">", ">=", "LIKE"]:
        return Result[CompiledQuery, DbError](isOk: false, error: queryError("unsupported comparison operator: " & predicate.op))
      sql.add(column.value & " " & predicate.op & " ?")
      result.value.params.add(predicate.value)
    of pkGroup:
      discard
  if q.groupColumns.len > 0:
    sql.add(" GROUP BY ")
    for index, groupColumn in q.groupColumns:
      let column = quoteIdentifier(groupColumn)
      if not column.isOk: return Result[CompiledQuery, DbError](isOk: false, error: column.error)
      if index > 0: sql.add(", ")
      sql.add(column.value)
  if q.havingPredicates.len > 0:
    if q.groupColumns.len == 0:
      return Result[CompiledQuery, DbError](isOk: false, error: queryError("HAVING requires GROUP BY"))
    sql.add(" HAVING ")
    for index, predicate in q.havingPredicates:
      if predicate.kind != pkCompare or predicate.op notin ["=", "!=", "<", "<=", ">", ">=", "LIKE"]:
        return Result[CompiledQuery, DbError](isOk: false, error: queryError("unsupported HAVING predicate"))
      let column = quoteIdentifier(predicate.column)
      if not column.isOk: return Result[CompiledQuery, DbError](isOk: false, error: column.error)
      if index > 0: sql.add(" " & predicate.connector & " ")
      sql.add(column.value & " " & predicate.op & " ?")
      result.value.params.add(predicate.value)
  if q.orders.len > 0:
    sql.add(" ORDER BY ")
    for index, order in q.orders:
      let column = quoteIdentifier(order.column)
      if not column.isOk: return Result[CompiledQuery, DbError](isOk: false, error: column.error)
      if index > 0: sql.add(", ")
      sql.add(column.value & (if order.direction == Asc: " ASC" else: " DESC"))
  if q.limitValue.isSome:
    if q.limitValue.get < 0: return Result[CompiledQuery, DbError](isOk: false, error: queryError("LIMIT must not be negative"))
    sql.add(" LIMIT ?")
    result.value.params.add(sqlInt(q.limitValue.get))
  if q.offsetValue.isSome:
    if q.offsetValue.get < 0: return Result[CompiledQuery, DbError](isOk: false, error: queryError("OFFSET must not be negative"))
    if q.limitValue.isNone: sql.add(" LIMIT -1")
    sql.add(" OFFSET ?")
    result.value.params.add(sqlInt(q.offsetValue.get))
  result.value.sql = sql
  Result[CompiledQuery, DbError](isOk: true, value: result.value)

proc get*[T](q: Query; typ: typedesc[T]): Result[seq[T], DbError] =
  if q.owner.isNil: return Result[seq[T], DbError](isOk: false, error: DbError(code: -1, message: "query has no database", kind: dekInvalidState))
  let compiled = q.compile()
  if not compiled.isOk: return Result[seq[T], DbError](isOk: false, error: compiled.error)
  if not q.updateScope.isNil:
    return withUpdateQueryRead(q.updateScope,
      proc(conn: var Connection): Result[seq[T], DbError] =
        scanRowsOnConnection[T](conn, compiled.value.sql, compiled.value.params))
  readRows[T](q.owner[], compiled.value.sql, compiled.value.params)

proc first*[T](q: Query; typ: typedesc[T]): Result[Option[T], DbError] =
  let rows = q.get(T)
  if not rows.isOk: return Result[Option[T], DbError](isOk: false, error: rows.error)
  Result[Option[T], DbError](isOk: true, value: if rows.value.len == 0: none(T) else: some(rows.value[0]))

proc find*[T](q: Query; id: int64; typ: typedesc[T]; key = "id"): Result[Option[T], DbError] =
  q.where(key, "=", id).first(T)

proc executeWrite(q: Query; sql: string; params: openArray[SqlValue]): Result[int, DbError] =
  if q.owner.isNil: return Result[int, DbError](isOk: false, error: DbError(code: -1, message: "query has no database", kind: dekInvalidState))
  if not q.updateScope.isNil:
    return execValuesInTransaction(q.updateScope, sql, params)
  q.owner[].execValues(sql, params)

proc insert*[T](q: Query; value: T): Result[int, DbError] =
  let tableName = quoteIdentifier(q.tableName)
  if not tableName.isOk: return Result[int, DbError](isOk: false, error: tableName.error)
  var columns, marks: seq[string]
  var params: seq[SqlValue]
  for fieldName, field in fieldPairs(value):
    let column = quoteIdentifier(fieldName)
    if not column.isOk: return Result[int, DbError](isOk: false, error: column.error)
    columns.add(column.value)
    marks.add("?")
    params.add(toSqlValue(field))
  if columns.len == 0: return Result[int, DbError](isOk: false, error: queryError("INSERT object has no fields"))
  executeWrite(q, "INSERT INTO " & tableName.value & " (" & columns.join(", ") & ") VALUES (" & marks.join(", ") & ")", params)

proc insertId*[T](q: Query; value: T): Result[int64, DbError] =
  let inserted = q.insert(value)
  if not inserted.isOk: return Result[int64, DbError](isOk: false, error: inserted.error)
  if not q.updateScope.isNil:
    return lastInsertIdInTransaction(q.updateScope)
  q.owner[].lastInsertId()

proc delete*(q: Query): Result[int, DbError] =
  if q.joins.len > 0: return Result[int, DbError](isOk: false, error: queryError("DELETE does not support JOIN"))
  let compiled = q.compile()
  if not compiled.isOk: return Result[int, DbError](isOk: false, error: compiled.error)
  let fromIndex = compiled.value.sql.find(" FROM ")
  let whereIndex = compiled.value.sql.find(" WHERE ")
  let suffix = if whereIndex >= 0: compiled.value.sql[whereIndex .. ^1] else: ""
  executeWrite(q, "DELETE FROM " & compiled.value.sql[fromIndex + 6 ..< (if whereIndex >= 0: whereIndex else: compiled.value.sql.len)] & suffix, compiled.value.params)

proc update*[T](q: Query; value: T): Result[int, DbError] =
  if q.joins.len > 0: return Result[int, DbError](isOk: false, error: queryError("UPDATE does not support JOIN"))
  let tableName = quoteIdentifier(q.tableName)
  if not tableName.isOk: return Result[int, DbError](isOk: false, error: tableName.error)
  var sets: seq[string]
  var params: seq[SqlValue]
  for fieldName, field in fieldPairs(value):
    let column = quoteIdentifier(fieldName)
    if not column.isOk: return Result[int, DbError](isOk: false, error: column.error)
    sets.add(column.value & " = ?")
    params.add(toSqlValue(field))
  if sets.len == 0: return Result[int, DbError](isOk: false, error: queryError("UPDATE object has no fields"))
  let compiled = q.compile()
  if not compiled.isOk: return Result[int, DbError](isOk: false, error: compiled.error)
  let whereIndex = compiled.value.sql.find(" WHERE ")
  if whereIndex >= 0:
    params.add(compiled.value.params)
  let suffix = if whereIndex >= 0: compiled.value.sql[whereIndex .. ^1] else: ""
  executeWrite(q, "UPDATE " & tableName.value & " SET " & sets.join(", ") & suffix, params)
