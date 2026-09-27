## SQLite-compatible lock state for SQLITE_THREADSAFE=0 / EXCLUSIVE mode.

type
  LockLevel* = enum
    lkNone, lkShared, lkReserved, lkPending, lkExclusive
  LockState* = object
    level*: LockLevel

proc initLockState*(): LockState = LockState(level: lkNone)

proc lock*(state: var LockState; requested: LockLevel): bool =
  ## A single canister execution has no competing OS process. SQLite still
  ## expects its requested state to be retained for reserved-lock checks.
  if requested > state.level: state.level = requested
  true

proc unlock*(state: var LockState; target: LockLevel): bool =
  if target > state.level: return false
  state.level = target
  true

proc checkReservedLock*(state: LockState): bool {.inline.} =
  state.level >= lkReserved
