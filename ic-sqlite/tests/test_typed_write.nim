import std/[options, unittest]
import ic_sqlite

type
  NewUser = object
    name: string
    active: bool
    email: Option[string]
  Patch = object
    name: string

suite "typed query writes":
  test "inserts, updates, and deletes object values through parameters":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, active INTEGER, email TEXT)").isOk
    let inserted = db.table("users").insertId(NewUser(name: "Ada', 1); DROP TABLE users; --", active: true, email: none(string)))
    check inserted.isOk
    check inserted.value == 1
    check db.queryOneText("SELECT name FROM users", []).value.get == "Ada', 1); DROP TABLE users; --"
    let updated = db.table("users").where("active", "=", true).update(Patch(name: "Grace"))
    check updated.isOk
    check updated.value == 1
    let deleted = db.table("users").where("name", "=", "Grace").delete()
    check deleted.isOk
    check deleted.value == 1
    db.close()
