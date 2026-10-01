## Synchronous transaction syntax backed exclusively by Db.withUpdate.

import std/macros
import ./db

macro transaction*(database: typed; tx: untyped; body: untyped): untyped =
  ## Runs body with tx: var UpdateConnection and returns Result[T, DbError].
  ## Return an error Result (or raise CatchableError) to roll back. A return
  ## exits the transaction body, not the calling proc. Use tx for DB operations;
  ## nested transactions and await/inter-canister calls are unsupported.
  if tx.kind != nnkIdent:
    error("transaction connection must be an identifier", tx)
  let bodyProc = genSym(nskProc, "transactionBody")
  result = quote do:
    block:
      proc `bodyProc`(`tx`: var UpdateConnection): auto {.closure.} =
        `body`
      withUpdate(`database`, `bodyProc`)
