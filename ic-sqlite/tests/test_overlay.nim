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

type FailingGrowBackend = ref object of StableBackend
  delegate: StableBackend

method sizePages(backend: FailingGrowBackend): uint64 = backend.delegate.sizePages()
method grow(backend: FailingGrowBackend; pages: uint64): bool = false
method read(backend: FailingGrowBackend; offset: uint64; dst: pointer; size: uint64) =
  backend.delegate.read(offset, dst, size)
method write(backend: FailingGrowBackend; offset: uint64; src: pointer; size: uint64) =
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

  test "allows discard after a publish failure before the first page write":
    let raw: StableBackend = newVecStableBackend()
    let storage: StableBackend = FailingGrowBackend(delegate: raw)
    var overlay = initOverlay(0, pageSize = 16, dbBaseOffset = 64)
    var value = [byte 1]
    overlay.writeFrom(storage, 0, addr value[0], 1)
    expect ValueError:
      overlay.publishDirtyPages(storage)
    overlay.discardOverlay()
    check overlay.dirtyPageCount == 0
    check overlay.size == 0

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

  test "rollback and discard leave no resident dirty or clean pages":
    let storage: StableBackend = newVecStableBackend()
    check storage.grow(4)
    var old = newSeq[byte](64)
    for index in 0 ..< old.len: old[index] = byte(index + 1)
    storage.write(64, addr old[0], uint64(old.len))
    var overlay = initOverlay(64, pageSize = 16, dbBaseOffset = 64,
      cleanCachePages = 4)
    # Read whole clean pages so they enter the cache on the second pass.
    var buffer = newSeq[byte](16)
    for page in 0 ..< 4:
      check overlay.readInto(storage, uint64(page) * 16'u64, addr buffer[0], 16)
      check overlay.readInto(storage, uint64(page) * 16'u64, addr buffer[0], 16)
    check overlay.cleanCacheCount == 4
    # Dirty the same pages plus an extra one, then discard everything.
    var one = [byte 9]
    for page in 0 ..< 5:
      overlay.writeFrom(storage, uint64(page) * 16'u64 + 1, addr one[0], 1)
    check overlay.dirtyPageCount == 5
    overlay.discardOverlay()
    check overlay.dirtyPageCount == 0
    check overlay.cleanCacheCount == 0
    check overlay.size == 64
    check overlay.zeroExtents.len == 0

  test "repeated truncate and re-extension keep zero extents and bytes correct":
    let raw: StableBackend = newVecStableBackend()
    check raw.grow(4)
    var old = newSeq[byte](80)
    for index in 0 ..< old.len: old[index] = byte((index + 1) mod 251)
    raw.write(64, addr old[0], uint64(old.len))
    var overlay = initOverlay(80, pageSize = 16, dbBaseOffset = 64)
    overlay.truncate(33, raw)          # partial page
    overlay.truncate(96, raw)          # grow beyond the old size
    var buffer = newSeq[byte](96)
    check overlay.readInto(raw, 0, addr buffer[0], 96)
    check buffer[0 .. 32] == old[0 .. 32]
    check buffer[33 .. 95] == newSeq[byte](63)
    overlay.truncate(1, raw)
    var marker = [byte 9]
    overlay.writeFrom(raw, 12, addr marker[0], 1)
    overlay.truncate(8, raw)
    overlay.truncate(70, raw)
    buffer = newSeq[byte](70)
    check overlay.readInto(raw, 0, addr buffer[0], 70)
    # The marker at offset 12 was removed by truncate(8); the re-extension
    # must therefore expose only zeros beyond the retained byte 0.
    check buffer[0] == 1
    check buffer[1 .. 69] == newSeq[byte](69)

  test "clean base-page cache avoids re-reading stable pages when enabled":
    let raw: StableBackend = newVecStableBackend()
    check raw.grow(4)
    let storage: StableBackend = CountingReadBackend(delegate: raw)
    var old = newSeq[byte](32)
    for index in 0 ..< old.len: old[index] = byte(index + 10)
    raw.write(64, addr old[0], uint64(old.len))
    var overlay = initOverlay(32, pageSize = 16, dbBaseOffset = 64,
      cleanCachePages = 2)
    check overlay.cleanCacheMaxPages == 2
    var buffer = newSeq[byte](16)
    # First pass loads both cached pages from stable memory exactly once.
    for page in 0 ..< 2:
      check overlay.readInto(storage, uint64(page) * 16'u64, addr buffer[0], 16)
    check overlay.cleanCacheCount == 2
    # Exactly two whole-page reads reached stable memory.
    check CountingReadBackend(storage).readCount == 2
    let readsAfterFill = CountingReadBackend(storage).readCount
    for page in 0 ..< 2:
      check overlay.readInto(storage, uint64(page) * 16'u64, addr buffer[0], 16)
      check buffer == old[page * 16 ..< (page + 1) * 16]
    # Second pass must be served entirely from the clean cache.
    check CountingReadBackend(storage).readCount == readsAfterFill
    # Dirtying a cached page must evict its clean copy.
    var one = [byte 9]
    overlay.writeFrom(storage, 4, addr one[0], 1)
    check overlay.cleanCacheCount == 1
    check CountingReadBackend(storage).readCount == readsAfterFill

  test "clean page cache is disabled by default and holds no pages":
    let raw: StableBackend = newVecStableBackend()
    check raw.grow(4)
    let storage: StableBackend = CountingReadBackend(delegate: raw)
    var old = newSeq[byte](48)
    for index in 0 ..< old.len: old[index] = byte(index + 20)
    raw.write(64, addr old[0], uint64(old.len))
    var overlay = initOverlay(48, pageSize = 16, dbBaseOffset = 64)
    check overlay.cleanCacheMaxPages == 0
    var buffer = newSeq[byte](16)
    for page in 0 ..< 3:
      check overlay.readInto(storage, uint64(page) * 16'u64, addr buffer[0], 16)
    check overlay.cleanCacheCount == 0
    let readsAfterFill = CountingReadBackend(storage).readCount
    for page in 0 ..< 3:
      check overlay.readInto(storage, uint64(page) * 16'u64, addr buffer[0], 16)
    # No cache -> every whole-page read goes back to stable memory.
    check CountingReadBackend(storage).readCount == readsAfterFill + 3

  test "partial zero-fill writes only the uncovered range":
    let raw: StableBackend = newVecStableBackend()
    check raw.grow(2)
    let storage: StableBackend = CountingReadBackend(delegate: raw)
    var base = newSeq[byte](16)
    for index in 0 ..< base.len: base[index] = byte(index + 1)
    raw.write(64, addr base[0], uint64(base.len))
    var overlay = initOverlay(16, pageSize = 16, dbBaseOffset = 64)
    var buffer = newSeq[byte](32)
    for index in 0 ..< buffer.len: buffer[index] = 0xAA
    check not overlay.readInto(storage, 0, addr buffer[0], uint64(buffer.len))
    check buffer[0 .. 15] == base
    check buffer[16 .. 31] == newSeq[byte](16)
    # offset >= size is a full zero short read.
    for index in 0 ..< buffer.len: buffer[index] = 0xAA
    check not overlay.readInto(storage, 32, addr buffer[0], uint64(buffer.len))
    check buffer == newSeq[byte](32)

  test "dirty pages and zero extents are served without touching the base":
    let raw: StableBackend = newVecStableBackend()
    check raw.grow(4)
    let storage: StableBackend = CountingReadBackend(delegate: raw)
    var base = newSeq[byte](32)
    for index in 0 ..< base.len: base[index] = byte(index + 1)
    raw.write(64, addr base[0], uint64(base.len))
    var overlay = initOverlay(32, pageSize = 16, dbBaseOffset = 64)
    overlay.truncate(16)
    let readsAfterTruncate = CountingReadBackend(storage).readCount
    var output = newSeq[byte](16)
    for index in 0 ..< output.len: output[index] = 0xAA
    # Past the truncated EOF: a full zero short read that never reaches base.
    check not overlay.readInto(storage, 16, addr output[0], 16)
    check output == newSeq[byte](16)
    check CountingReadBackend(storage).readCount == readsAfterTruncate
    # A full-page dirty write is read back entirely from the resident page.
    var full = newSeq[byte](16)
    for index in 0 ..< full.len: full[index] = byte(200 + index)
    overlay.writeFrom(storage, 0, addr full[0], uint64(full.len))
    let readsAfterWrite = CountingReadBackend(storage).readCount
    for index in 0 ..< output.len: output[index] = 0xAA
    check overlay.readInto(storage, 0, addr output[0], 16)
    check output == full
    check CountingReadBackend(storage).readCount == readsAfterWrite

  test "partial clean reads populate and then hit the clean cache":
    let raw: StableBackend = newVecStableBackend()
    check raw.grow(4)
    let storage: StableBackend = CountingReadBackend(delegate: raw)
    var base = newSeq[byte](48)
    for index in 0 ..< base.len: base[index] = byte(index + 7)
    raw.write(64, addr base[0], uint64(base.len))
    var overlay = initOverlay(48, pageSize = 16, dbBaseOffset = 64,
      cleanCachePages = 2)
    var buffer = newSeq[byte](6)
    # First partial read of page 0 misses and loads the whole page once.
    check overlay.readInto(storage, 2, addr buffer[0], 6)
    check buffer == base[2 ..< 8]
    check overlay.cleanCacheCount == 1
    check CountingReadBackend(storage).readCount == 1
    # A second partial read of page 0 is served from the cache.
    check overlay.readInto(storage, 9, addr buffer[0], 6)
    check buffer == base[9 ..< 15]
    check CountingReadBackend(storage).readCount == 1
    # A different page still misses once and then hits.
    check overlay.readInto(storage, 20, addr buffer[0], 6)
    check buffer == base[20 ..< 26]
    check overlay.cleanCacheCount == 2
    check CountingReadBackend(storage).readCount == 2
    check overlay.readInto(storage, 20, addr buffer[0], 6)
    check CountingReadBackend(storage).readCount == 2
    # Dirtying a cached page evicts its clean copy.
    var one = [byte 0xEE]
    overlay.writeFrom(storage, 4, addr one[0], 1)
    check overlay.cleanCacheCount == 1
    # A partial read past base EOF is zero-padded in the cached page.
    var tail: array[8, byte]
    check not overlay.readInto(storage, 44, addr tail[0], 8)
    check tail[0 .. 3] == base[44 .. 47]
    check tail[4 .. 7] == [byte 0, 0, 0, 0]
