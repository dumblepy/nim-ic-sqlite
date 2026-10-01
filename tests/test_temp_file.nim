import std/unittest
import ic_sqlite/vfs/[lock, temp_file]

suite "TempFile":
  test "reads, writes, zero-fills gaps and truncates":
    var file = initTempFile()
    file.writeAt(2, [byte 1, 2])
    check file.len == 4
    check file.readAt(0, 6) == @[byte 0, 0, 1, 2, 0, 0]
    file.truncate(1)
    check file.len == 1
    file.truncate(3)
    check file.readAt(0, 3) == @[byte 0, 0, 0]
  test "rejects negative ranges":
    var file = initTempFile()
    expect ValueError: discard file.readAt(-1, 1)
    expect ValueError: file.truncate(-1)

suite "LockState":
  test "tracks SQLite lock escalation and reserved state":
    var state = initLockState()
    check state.lock(lkShared)
    check not state.checkReservedLock
    check state.lock(lkReserved)
    check state.checkReservedLock
    check state.lock(lkExclusive)
    check state.unlock(lkShared)
    check state.level == lkShared
    check not state.unlock(lkExclusive)
