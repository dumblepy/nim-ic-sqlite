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

  test "short reads zero-fill the complete unread suffix and zero-byte I/O accepts nil":
    let backend: StableBackend = newVecStableBackend()
    check backend.grow(2)
    initVfs(backend, dbSize = 2)
    var id: uint32
    var flags: cint
    check openFile("/main.db", 0, id, flags) == SqliteOk
    var persisted = [byte 4, 5]
    backend.write(65536, addr persisted[0], 2)
    var output = [byte 99, 99, 99, 99]
    check readFile(id, addr output[0], 4, 1) == SqliteIoErrShortRead
    check output == [byte 5, 0, 0, 0]
    check readFile(id, nil, 0, 0) == SqliteOk
    check writeFile(id, nil, 0, 0) == SqliteReadOnly

  test "main DB direct I/O handles page boundaries and multiple pages":
    let backend: StableBackend = newVecStableBackend()
    check backend.grow(3)
    initVfs(backend)
    var id: uint32
    var flags: cint
    check openFile("/main.db", 0, id, flags) == SqliteOk
    beginOverlay(pageSize = 16)
    var input = newSeq[byte](48)
    for index in 0 ..< input.len: input[index] = byte(index + 1)
    check writeFile(id, addr input[0], cint(input.len), 0) == SqliteOk
    var output = newSeq[byte](48)
    check readFile(id, addr output[0], cint(output.len), 0) == SqliteOk
    check output == input
    endOverlay(publish = true)
    output = newSeq[byte](48)
    check readFile(id, addr output[0], cint(output.len), 0) == SqliteOk
    check output == input

  test "partial main DB truncate keeps the retained prefix and zeroes re-extension":
    let backend: StableBackend = newVecStableBackend()
    check backend.grow(2)
    initVfs(backend)
    var id: uint32
    var flags: cint
    check openFile("/main.db", 0, id, flags) == SqliteOk
    beginOverlay(pageSize = 16)
    var input = [byte 1, 2, 3, 4]
    check writeFile(id, addr input[0], 4, 0) == SqliteOk
    check truncateFile(id, 1) == SqliteOk
    var output = [byte 99, 99, 99, 99]
    check readFile(id, addr output[0], 4, 0) == SqliteIoErrShortRead
    check output == [byte 1, 0, 0, 0]

  test "file sizes outside SQLite's signed range return an I/O error":
    let backend: StableBackend = newVecStableBackend()
    initVfs(backend, dbSize = uint64(high(int64)) + 1)
    var id: uint32
    var flags: cint
    var size: int64
    check openFile("/main.db", 0, id, flags) == SqliteOk
    check fileSize(id, size) == SqliteIoErr
