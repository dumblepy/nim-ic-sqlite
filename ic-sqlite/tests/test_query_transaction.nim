import std/[options, unittest]
import ic_sqlite
import ic_sqlite/stable/superblock

type NewItem = object
  name: string
type StoredItem = object
  name: string

suite "query builder transactions":
  test "commits typed writes in one withUpdate transaction":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE items (name TEXT)").isOk
    let committed = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let first = conn.table("items").insert(NewItem(name: "one"))
      if not first.isOk: return Result[bool, DbError](isOk: false, error: first.error)
      let second = conn.table("items").insert(NewItem(name: "two"))
      if not second.isOk: return Result[bool, DbError](isOk: false, error: second.error)
      let visible = conn.table("items").where("name", "=", "two").first(StoredItem)
      if not visible.isOk or visible.value.isNone or visible.value.get.name != "two":
        return Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "uncommitted row not visible"))
      Result[bool, DbError](isOk: true, value: true)
    )
    check committed.isOk
    check db.queryOneText("SELECT count(*) FROM items", []).value.get == "2"
    let rolledBack = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      let insert = conn.table("items").insert(NewItem(name: "lost"))
      if not insert.isOk: return Result[bool, DbError](isOk: false, error: insert.error)
      Result[bool, DbError](isOk: false, error: DbError(code: -1, message: "rollback"))
    )
    check not rolledBack.isOk
    check db.queryOneText("SELECT count(*) FROM items", []).value.get == "2"
    let exceptionRolledBack = db.withUpdate(proc(conn: var UpdateConnection): Result[bool, DbError] =
      discard conn.table("items").insert(NewItem(name: "exception"))
      raise newException(ValueError, "intentional exception")
    )
    check not exceptionRolledBack.isOk
    check db.queryOneText("SELECT count(*) FROM items", []).value.get == "2"
    db.close()
