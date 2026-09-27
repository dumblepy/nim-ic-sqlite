import std/[options, unittest]
import ic_sqlite

type
  TypedRow = object
    id: int64
    name: string
    enabled: bool
    score: float64
    note: Option[string]
    payload: seq[byte]
  RequiredName = object
    name: string
  RequiredId = object
    id: int64

suite "typed row reader":
  test "decodes multiple rows, NULL options, blobs, and embedded NUL text":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE typed_rows (id INTEGER, name TEXT, enabled INTEGER, score REAL, note TEXT, payload BLOB)").isOk
    check db.exec("INSERT INTO typed_rows VALUES (1, 'alpha', 1, 1.5, NULL, x'0001')").isOk
    check db.exec("INSERT INTO typed_rows VALUES (2, 'a' || char(0) || 'b', 0, 2.5, 'present', x'FF')").isOk
    let rows = readRows[TypedRow](db, "SELECT id, name, enabled, score, note, payload FROM typed_rows ORDER BY id")
    check rows.isOk
    check rows.value.len == 2
    check rows.value[0].id == 1
    check rows.value[0].note.isNone
    check rows.value[0].payload == @[byte 0, 1]
    check rows.value[1].name.len == 3
    check rows.value[1].name[1] == '\0'
    check rows.value[1].note.get == "present"
    check rows.value[1].enabled == false
    db.close()

  test "reports strict decoding and mapping errors":
    var db: Db
    check db.initMemoryForTest().isOk
    let nullIntoString = readRows[RequiredName](db, "SELECT NULL AS name")
    check not nullIntoString.isOk
    check nullIntoString.error.kind == dekNullViolation
    let textIntoInteger = readRows[RequiredId](db, "SELECT '1' AS id")
    check not textIntoInteger.isOk
    check textIntoInteger.error.kind == dekTypeMismatch
    let missing = readRows[RequiredName](db, "SELECT 1 AS id")
    check not missing.isOk
    check missing.error.kind == dekColumnMissing
    let duplicate = readRows[RequiredId](db, "SELECT 1 AS id, 2 AS id")
    check not duplicate.isOk
    let first = readFirst[TypedRow](db, "SELECT id, name, enabled, score, note, payload FROM (SELECT 1 AS id, 'x' AS name, 1 AS enabled, 1.0 AS score, NULL AS note, x'' AS payload) WHERE 0")
    check first.isOk
    check first.value.isNone
    db.close()

  test "rejects placeholder mismatch and write SQL":
    var db: Db
    check db.initMemoryForTest().isOk
    let mismatch = readRows[RequiredId](db, "SELECT ? AS id", [])
    check not mismatch.isOk
    check mismatch.error.kind == dekBind
    let write = readRows[RequiredId](db, "CREATE TABLE forbidden (id INTEGER)")
    check not write.isOk
    check write.error.kind == dekInvalidQuery
    db.close()
