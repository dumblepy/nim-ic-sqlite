discard """
  action: reject
  errormsg: "Can only 'await' inside a proc marked as 'async'."
"""

import std/asyncdispatch
import ic_sqlite

proc remote(): Future[bool] {.async.} =
  return true

proc caller() {.async.} =
  var database: Db
  discard transaction(database, tx):
    let value = await remote()
    Result[bool, DbError](isOk: true, value: value)

waitFor caller()
