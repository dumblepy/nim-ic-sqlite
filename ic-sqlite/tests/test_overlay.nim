import std/unittest
import ic_sqlite/stable/backend
import ic_sqlite/stable/superblock
import ic_sqlite/vfs/overlay

type FailingWriteBackend = ref object of StableBackend
  delegate: StableBackend
  failOnWrite: int
  writeCount: int

method sizePages(backend: FailingWriteBackend): uint64 =
  backend.delegate.sizePages()

method grow(backend: FailingWriteBackend; pages: uint64): bool =
  backend.delegate.grow(pages)

method read(backend: FailingWriteBackend; offset: uint64; dst: pointer; size: uint64) =
  backend.delegate.read(offset, dst, size)

method write(backend: FailingWriteBackend; offset: uint64; src: pointer; size: uint64) =
  inc backend.writeCount
  if backend.writeCount == backend.failOnWrite:
    raise newException(IOError, "injected stable write failure")
  backend.delegate.write(offset, src, size)

type CountingReadBackend = ref object of StableBackend
  delegate: StableBackend
  readCount: int

method sizePages(backend: CountingReadBackend): uint64 = backend.delegate.sizePages()
method grow(backend: CountingReadBackend; pages: uint64): bool = backend.delegate.grow(pages)
method read(backend: CountingReadBackend; offset: uint64; dst: pointer; size: uint64) =
  inc backend.readCount
  backend.delegate.read(offset, dst, size)
method write(backend: CountingReadBackend; offset: uint64; src: pointer; size: uint64) =
  backend.delegate.write(offset, src, size)

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

  test "marks failures after the first stable page write as irreversible":
    let raw: StableBackend = newVecStableBackend()
    check raw.grow(2)
    let storage: StableBackend = FailingWriteBackend(delegate: raw, failOnWrite: 2)
    var overlay = initOverlay(0, pageSize = 16, dbBaseOffset = 64)
    overlay.writeAt(storage, 0, [byte 1])
    overlay.writeAt(storage, 16, [byte 2])
    expect PublishStartedError:
      overlay.publishDirtyPages(storage)

  test "direct I/O keeps EOF tails zero and full page writes avoid base reads":
    let raw: StableBackend = newVecStableBackend()
    check raw.grow(2)
    let storage: StableBackend = CountingReadBackend(delegate: raw)
    var overlay = initOverlay(16, pageSize = 16, dbBaseOffset = 64)
    var full = newSeq[byte](16)
    for index in 0 ..< full.len: full[index] = byte(index + 1)
    overlay.writeFrom(storage, 0, addr full[0], uint64(full.len))
    check CountingReadBackend(storage).readCount == 0
    var output = [byte 99, 99, 99, 99, 99, 99]
    check not overlay.readInto(storage, 14, addr output[0], uint64(output.len))
    check output == [byte 15, 16, 0, 0, 0, 0]

  test "truncate then sparse extension never exposes the old tail":
    let storage: StableBackend = newVecStableBackend()
    check storage.grow(2)
    var old = newSeq[byte](32)
    for index in 0 ..< old.len: old[index] = byte(index + 1)
    storage.write(64, addr old[0], uint64(old.len))
    var overlay = initOverlay(32, pageSize = 16, dbBaseOffset = 64)
    overlay.truncate(1, storage)
    var marker = [byte 77]
    overlay.writeFrom(storage, 20, addr marker[0], 1)
    var output = newSeq[byte](21)
    check overlay.readInto(storage, 0, addr output[0], uint64(output.len))
    check output[0] == 1
    check output[1 .. 19] == newSeq[byte](19)
    check output[20] == 77

  test "multi-page overlapping writes preserve the last bytes without new base reads":
    let raw: StableBackend = newVecStableBackend()
    check raw.grow(2)
    let storage: StableBackend = CountingReadBackend(delegate: raw)
    var overlay = initOverlay(0, pageSize = 16, dbBaseOffset = 64)
    var initial = newSeq[byte](48)
    for index in 0 ..< initial.len: initial[index] = byte(index)
    overlay.writeFrom(storage, 0, addr initial[0], uint64(initial.len))
    let readsAfterInitial = CountingReadBackend(storage).readCount
    var replacement = newSeq[byte](20)
    for index in 0 ..< replacement.len: replacement[index] = byte(200 + index)
    overlay.writeFrom(storage, 10, addr replacement[0], uint64(replacement.len))
    check CountingReadBackend(storage).readCount == readsAfterInitial
    var output = newSeq[byte](48)
    check overlay.readInto(storage, 0, addr output[0], uint64(output.len))
    check output[0 .. 9] == initial[0 .. 9]
    check output[10 .. 29] == replacement
    check output[30 .. 47] == initial[30 .. 47]

  test "dirty limits apply only to newly resident pages":
    let storage: StableBackend = newVecStableBackend()
    check storage.grow(2)
    var overlay = initOverlay(0, pageSize = 16, dbBaseOffset = 64,
      maxDirtyPages = 1, maxDirtyBytes = 16)
    var first = [byte 1]
    overlay.writeFrom(storage, 0, addr first[0], 1)
    var replacement = [byte 2]
    overlay.writeFrom(storage, 1, addr replacement[0], 1)
    check overlay.dirtyPageCount == 1
    expect ValueError:
      overlay.writeFrom(storage, 16, addr replacement[0], 1)
