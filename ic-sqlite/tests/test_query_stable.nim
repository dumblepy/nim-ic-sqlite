import std/[options, unittest]
import ic_sqlite
import ic_sqlite/stable/backend

type PersistedItem = object
  id: int64
  name: string

suite "query builder stable backend":
  test "retains typed rows after database reinitialization":
    let backend: StableBackend = newVecStableBackend()
    var first: Db
    check first.init(backend).isOk
    check first.exec("CREATE TABLE items (id INTEGER, name TEXT)").isOk
    check first.table("items").insert(PersistedItem(id: 7, name: "persisted")).isOk
    first.close()
    var reopened: Db
    check reopened.init(backend).isOk
    let row = reopened.table("items").where("id", "=", 7'i64).first(PersistedItem)
    check row.isOk
    check row.value.isSome
    if row.value.isSome:
      check row.value.get.name == "persisted"
    reopened.close()
