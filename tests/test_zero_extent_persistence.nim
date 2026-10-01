import std/unittest
import nicp_cdk/storage/stable_backend
import ic_sqlite/vfs/vfs

suite "zero extent persistence":
  test "truncate then re-extend is zero-filled after reopen":
    let backend: StableBackend = newVecStableBackend()
    check backend.grow(2)
    initVfs(backend)
    var handle: uint32
    var flags: cint
    check openFile("/main.db", 0, handle, flags) == SqliteOk
    beginOverlay(pageSize = 16)
    var original: array[32, byte]
    for index in 0 ..< original.len: original[index] = 0xA5'u8
    check writeFile(handle, addr original[0], 32, 0) == SqliteOk
    endOverlay(publish = true)

    beginOverlay(pageSize = 16)
    check truncateFile(handle, 16) == SqliteOk
    check truncateFile(handle, 32) == SqliteOk
    endOverlay(publish = true)
    let persisted = currentZeroExtents()
    check persisted.len == 1
    check closeFile(handle) == SqliteOk

    initVfs(backend, dbSize = 32, zeroExtents = persisted, pageSize = 16)
    check openFile("/main.db", 0, handle, flags) == SqliteOk
    var reopened: array[16, byte]
    check readFile(handle, addr reopened[0], 16, 16) == SqliteOk
    check reopened == [byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    check closeFile(handle) == SqliteOk
