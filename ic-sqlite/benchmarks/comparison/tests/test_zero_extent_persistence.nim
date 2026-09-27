## Documents the current reopen defect. This test must be revised with its fix.
import std/unittest
import ic_sqlite/stable/backend
import ic_sqlite/vfs/vfs

suite "zero extent persistence diagnostic":
  test "truncate then re-extend exposes stale stable bytes after reopen":
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
    check closeFile(handle) == SqliteOk

    initVfs(backend, dbSize = 32)
    check openFile("/main.db", 0, handle, flags) == SqliteOk
    var reopened: array[16, byte]
    check readFile(handle, addr reopened[0], 16, 16) == SqliteOk
    check reopened == original[16 ..< 32]
    echo "KNOWN_FAILURE: re-extended page contains stale bytes after reopen"
    check closeFile(handle) == SqliteOk
