import std/unittest
import ic_sqlite/stable/backend
import ic_sqlite/stable/superblock
import ic_sqlite/vfs/overlay

suite "Overlay":
  test "keeps writes off stable memory until publish":
    let storage: StableBackend = newVecStableBackend()
    check storage.grow(2)
    var overlay = initOverlay(0, pageSize = 16, dbBaseOffset = 64)
    overlay.writeAt(storage, 0, [byte 1, 2, 3])
    check overlay.readAt(storage, 0, 3) == @[byte 1, 2, 3]
    check overlay.dirtyPageCount == 1
    var before = [byte 9, 9, 9]
    storage.read(64, addr before[0], 3)
    check before == [byte 0, 0, 0]
    overlay.publishDirtyPages(storage)
    storage.read(64, addr before[0], 3)
    check before == [byte 1, 2, 3]
  test "partial writes load the base page and discard restores base size":
    let storage: StableBackend = newVecStableBackend()
    check storage.grow(2)
    var initial = [byte 1, 2, 3, 4]
    storage.write(64, addr initial[0], 4)
    var overlay = initOverlay(4, pageSize = 16, dbBaseOffset = 64)
    overlay.writeAt(storage, 1, [byte 8, 9])
    check overlay.readAt(storage, 0, 4) == @[byte 1, 8, 9, 4]
    overlay.discardOverlay()
    check overlay.size == 4
    check overlay.dirtyPageCount == 0
  test "truncate marks removed pages logically zero until rewritten":
    let storage: StableBackend = newVecStableBackend()
    check storage.grow(2)
    var old = newSeq[byte](32)
    for index in 0 ..< old.len: old[index] = byte(index + 1)
    storage.write(64, addr old[0], uint64(old.len))
    var overlay = initOverlay(32, pageSize = 16, dbBaseOffset = 64)
    overlay.truncate(16)
    check overlay.zeroExtents == @[ZeroExtent(startPage: 1, endPage: 2)]
    check overlay.readAt(storage, 16, 16) == newSeq[byte](16)
    overlay.writeAt(storage, 16, [byte 7])
    check overlay.zeroExtents.len == 0
