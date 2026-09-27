import std/unittest
import ic_sqlite/stable/backend
import ic_sqlite/vfs/vfs

suite "VFS registry":
  test "main DB writes use overlay while temp files remain heap-only":
    let backend: StableBackend = newVecStableBackend()
    check backend.grow(2)
    initVfs(backend)
    var mainId, tempId: uint32
    var outFlags: cint
    check openFile("/main.db", 0, mainId, outFlags) == SqliteOk
    check openFile("journal", 0, tempId, outFlags) == SqliteOk
    beginOverlay(pageSize = 16)
    var main = [byte 1, 2]
    var temp = [byte 3, 4]
    check writeFile(mainId, addr main[0], 2, 0) == SqliteOk
    check writeFile(tempId, addr temp[0], 2, 0) == SqliteOk
    var readMain = [byte 0, 0]
    var readTemp = [byte 0, 0]
    check readFile(mainId, addr readMain[0], 2, 0) == SqliteOk
    check readFile(tempId, addr readTemp[0], 2, 0) == SqliteOk
    check readMain == main
    check readTemp == temp
    endOverlay(publish = true)
    var persisted = [byte 0, 0]
    backend.read(65536, addr persisted[0], 2)
    check persisted == main
    check closeFile(mainId) == SqliteOk
    check closeFile(tempId) == SqliteOk
  test "rejects WAL and provides deterministic VFS randomness":
    let backend: StableBackend = newVecStableBackend()
    initVfs(backend, seed = 42)
    var id: uint32
    var flags: cint
    check openFile("/main.db-wal", 0, id, flags) == SqliteCantOpen
    var first = [byte 0, 0, 0, 0]
    discard randomBytes(addr first[0], 4)
    initVfs(backend, seed = 42)
    var second = [byte 0, 0, 0, 0]
    discard randomBytes(addr second[0], 4)
    check first == second
