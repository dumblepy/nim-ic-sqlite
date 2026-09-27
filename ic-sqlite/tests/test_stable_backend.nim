import std/unittest
import ic_sqlite/stable/backend
import ic_sqlite/stable/ic_backend

suite "VecStableBackend":
  test "grows in 64 KiB stable pages and preserves raw bytes":
    let backend: StableBackend = newVecStableBackend()
    check backend.sizePages() == 0
    check backend.grow(2)
    check backend.sizePages() == 2

    var source = [byte 1, 2, 3, 4]
    var destination = [byte 0, 0, 0, 0]
    backend.write(StablePageSize + 12, addr source[0], uint64(source.len))
    backend.read(StablePageSize + 12, addr destination[0], uint64(destination.len))
    check destination == source

  test "rejects I/O outside grown memory":
    let backend: StableBackend = newVecStableBackend()
    var byteValue = byte 0
    expect ValueError:
      backend.read(0, addr byteValue, 1)

  test "IC backend is unavailable rather than silently emulated on native":
    let backend = newIcStableBackend()
    expect CatchableError:
      discard backend.sizePages()

  test "offset backend preserves a runtime-owned stable prefix":
    let raw: StableBackend = newVecStableBackend()
    let region: StableBackend = newOffsetStableBackend(raw, StablePageSize)
    check region.sizePages == 0
    check region.grow(1)
    check raw.sizePages == 2
    var written = [byte 7, 8, 9]
    region.write(0, addr written[0], uint64(written.len))
    var readBack = newSeq[byte](written.len)
    region.read(0, addr readBack[0], uint64(readBack.len))
    check readBack == @written
