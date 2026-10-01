import std/unittest
import ic_sqlite/ffi/vfs_exports
import nicp_cdk/storage/stable_backend
import ic_sqlite/vfs/vfs

suite "C ABI VFS exports":
  test "callbacks use C-compatible handles and buffers":
    let backend: StableBackend = newVecStableBackend()
    check backend.grow(2)
    initVfs(backend)
    var id: uint32
    var flags: cint
    check nim_icvfs_open("/main.db", 0, addr id, addr flags) == SqliteOk
    beginOverlay(16)
    var source = [byte 5, 6]
    var target = [byte 0, 0]
    check nim_icvfs_write(id, addr source[0], 2, 0) == SqliteOk
    check nim_icvfs_read(id, addr target[0], 2, 0) == SqliteOk
    check target == source
    check nim_icvfs_close(id) == SqliteOk
  test "current time converts nanoseconds to SQLite Julian day":
    currentTimeNanoseconds = 86_400_000_000_000'u64
    var julian: cdouble
    check nim_icvfs_current_time(addr julian) == SqliteOk
    check julian == 2440588.5
