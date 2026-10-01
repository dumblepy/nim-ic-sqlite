discard """
  action: reject
  errormsg: "transaction connection must be an identifier"
"""

import ic_sqlite

var database: Db
discard transaction(database, tx.field):
  Result[bool, DbError](isOk: true, value: true)
