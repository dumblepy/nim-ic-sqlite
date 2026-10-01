import std/[options, strutils, unittest]
import ic_sqlite
import ic_sqlite/stable/backend

type Item = object
  name: string

static:
  doAssert not compiles(block:
    var database: Db
    discard transaction(database, tx.field):
      Result[bool, DbError](isOk: true, value: true))
  doAssert not compiles(block:
    var database: Db
    discard transaction(database, tx):
      42)

for stable in [false, true]:
  suite "transaction macro (stable=" & $stable & ")":
    var database: Db
    var backend: StableBackend
    setup:
      if stable:
        backend = newVecStableBackend()
        require database.init(backend).isOk
      else:
        require database.initMemoryForTest().isOk
      require database.exec("CREATE TABLE items (name TEXT)").isOk
    teardown:
      database.close()

    test "commit, read-your-writes, generic result and expired query":
      var escaped: Query
      let outcome = transaction(database, tx):
        let inserted = tx.table("items").insert(Item(name: "committed"))
        if not inserted.isOk:
          return Result[Option[Item], DbError](isOk: false, error: inserted.error)
        escaped = tx.table("items")
        escaped.first(Item)
      require outcome.isOk
      require outcome.value.isSome
      check outcome.value.get.name == "committed"
      check database.queryOneText("SELECT name FROM items", []).value.get == "committed"
      let staleRead = escaped.first(Item)
      check not staleRead.isOk
      check staleRead.error.kind == dekInvalidState
      let staleWrite = escaped.delete()
      check not staleWrite.isOk
      check staleWrite.error.kind == dekInvalidState
      if stable:
        database.close()
        require database.init(backend).isOk
        check database.queryOneText("SELECT name FROM items", []).value.get == "committed"

    test "error Result rolls back without publishing stable bytes or growing pages":
      let beforePages = if stable: backend.sizePages() else: 0'u64
      var before: seq[byte]
      if stable:
        before = newSeq[byte](int(beforePages * StablePageSize))
        backend.read(0, addr before[0], uint64(before.len))
      let expected = DbError(code: 123, kind: dekInvalidState, message: "rollback")
      let outcome = transaction(database, tx):
        let inserted = tx.execText("INSERT INTO items VALUES (?)", [repeat('x', 150_000)])
        if not inserted.isOk:
          return Result[int64, DbError](isOk: false, error: inserted.error)
        Result[int64, DbError](isOk: false, error: expected)
      check not outcome.isOk
      check outcome.error == expected
      check database.queryOneText("SELECT count(*) FROM items", []).value.get == "0"
      if stable:
        check backend.sizePages() == beforePages
        var after = newSeq[byte](before.len)
        backend.read(0, addr after[0], uint64(after.len))
        check after == before
        database.close()
        require database.init(backend).isOk
        check database.queryOneText("SELECT count(*) FROM items", []).value.get == "0"

    test "CatchableError rolls back and the next transaction succeeds":
      let outcome = transaction(database, tx):
        let inserted = tx.exec("INSERT INTO items VALUES ('exception')")
        if not inserted.isOk:
          return Result[bool, DbError](isOk: false, error: inserted.error)
        raise newException(ValueError, "intentional")
      check not outcome.isOk
      check outcome.error.kind == dekInvalidState
      check outcome.error.message == "intentional"
      check database.queryOneText("SELECT count(*) FROM items", []).value.get == "0"
      let recovered = transaction(database, tx):
        tx.exec("INSERT INTO items VALUES ('recovered')")
      check recovered.isOk
      check database.queryOneText("SELECT name FROM items", []).value.get == "recovered"

    test "nested transaction and ordinary writes fail while outer transaction remains usable":
      let outcome = transaction(database, outerTx):
        var innerCalled = false
        let nested = transaction(database, innerTx):
          innerCalled = true
          Result[bool, DbError](isOk: true, value: true)
        check not innerCalled
        check not nested.isOk
        check nested.error.kind == dekInvalidState
        check nested.error.message == "nested update transaction is not supported"
        let direct = database.exec("INSERT INTO items VALUES ('invalid')")
        let text = database.execText("INSERT INTO items VALUES (?)", ["invalid"])
        let typed = database.execValues("INSERT INTO items VALUES (?)", [sqlText("invalid")])
        let query = database.table("items").insert(Item(name: "invalid"))
        for invalid in [direct, text, typed, query]:
          check not invalid.isOk
          check invalid.error.kind == dekInvalidState
          check invalid.error.message == "ordinary write is forbidden during withUpdate"
        outerTx.execValues("INSERT INTO items VALUES (?)", [sqlText("outer")])
      check outcome.isOk
      check database.queryOneText("SELECT count(*) FROM items", []).value.get == "1"
      check database.queryOneText("SELECT name FROM items", []).value.get == "outer"

    test "return exits the body and hygienic symbols preserve caller variables":
      proc caller(): int64 =
        let transactionBody = 42'i64
        let outcome = transaction(database, tx):
          return Result[int64, DbError](isOk: true, value: transactionBody)
        doAssert outcome.isOk
        outcome.value + 1
      check caller() == 43

    test "database expression is evaluated once":
      var evaluations = 0
      proc selected(): var Db =
        inc evaluations
        database
      let outcome = transaction(selected(), tx):
        Result[int64, DbError](isOk: true, value: 42)
      check outcome.isOk
      check outcome.value == 42
      check evaluations == 1
