import std/[options, unittest]
import ic_sqlite

type User = object
  id: int64
  name: string
  active: bool

suite "query builder":
  test "executes immutable typed SELECT chains":
    var db: Db
    check db.initMemoryForTest().isOk
    check db.exec("CREATE TABLE users (id INTEGER, name TEXT, active INTEGER)").isOk
    check db.exec("INSERT INTO users VALUES (1, 'Ada', 1), (2, 'Grace', 0), (3, 'Linus', 1)").isOk
    let base = db.table("users").where("active", "=", true)
    let adults = base.orderBy("id", Desc).limit(1)
    let active = base.get(User)
    let selected = adults.get(User)
    check active.isOk
    check active.value.len == 2
    check selected.isOk
    check selected.value[0].id == 3
    let found = db.table("users").find(1, User)
    check found.isOk
    check found.value.get.name == "Ada"
    db.close()
