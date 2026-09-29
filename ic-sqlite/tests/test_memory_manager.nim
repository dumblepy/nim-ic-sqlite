## Tests for the MemoryManager-compatible virtual stable memory.
##
## The on-stable format must stay byte-compatible with `ic-stable-structures`
## 0.7 / the Rust `ic-sqlite-vfs` fork so an existing `MGR` image can be loaded
## and SQLite can coexist with other stable structures.
import std/[options, unittest]
import ic_sqlite
import ic_sqlite/stable/backend
import ic_sqlite/stable/memory_manager

# `ic-stable-structures` MemoryManager 0.7 layout constants.
const
  MgrHeaderSize = 2080
  MgrAllocationTableSize = 32768
  MgrBucketSizePages = 128'u64
  MgrOwnerId = 7'u8
  MgrUnallocated = 255'u8
  MgrMemorySizesOffset = 40

proc putLe16(bytes: var openArray[byte]; offset: int; value: uint16) =
  bytes[offset] = byte(value and 0xff)
  bytes[offset + 1] = byte(value shr 8)

proc putLe64(bytes: var openArray[byte]; offset: int; value: uint64) =
  for index in 0 ..< 8:
    bytes[offset + index] = byte((value shr (index * 8)) and 0xff)

proc writeValidMgrFixture(raw: StableBackend) =
  ## One header page plus one 128-page bucket owned by MemoryId 7.
  check raw.grow(1 + MgrBucketSizePages)
  var header = newSeq[byte](MgrHeaderSize)
  header[0 .. 2] = [byte('M'), byte('G'), byte('R')]
  header[3] = 1
  header.putLe16(4, 1)
  header.putLe16(6, uint16(MgrBucketSizePages))
  header.putLe64(MgrMemorySizesOffset + int(MgrOwnerId) * 8, 1)
  raw.write(0, unsafeAddr header[0], uint64(header.len))

  var allocations = newSeq[byte](MgrAllocationTableSize)
  for index in 0 ..< allocations.len: allocations[index] = MgrUnallocated
  allocations[0] = MgrOwnerId
  raw.write(uint64(MgrHeaderSize), unsafeAddr allocations[0], uint64(allocations.len))

proc readBytes(raw: StableBackend; offset: uint64; size: int): seq[byte] =
  result = newSeq[byte](size)
  raw.read(offset, addr result[0], uint64(size))

suite "MemoryManager virtual stable memory":
  test "creates a fresh MGR image using the ic-stable-structures layout":
    let raw: StableBackend = newVecStableBackend()
    let manager = initMemoryManager(raw)
    check raw.sizePages >= 1
    check manager.bucketSizeInPages == DefaultBucketSizeInPages
    check manager.allocatedBucketCount == 0

    let header = readBytes(raw, 0, MgrHeaderSize)
    check header[0 .. 2] == [byte('M'), byte('G'), byte('R')]
    check header[3] == 1
    check header[4] == 0 and header[5] == 0
    check header[6] == byte(MgrBucketSizePages) and header[7] == 0
    check header[MgrMemorySizesOffset] == 0

    let allocations = readBytes(raw, uint64(MgrHeaderSize), MgrAllocationTableSize)
    for value in allocations: check value == MgrUnallocated

  test "grows and maps a virtual memory across bucket boundaries":
    let raw: StableBackend = newVecStableBackend()
    let manager = initMemoryManager(raw)
    let vm = manager.getMemory(newMemoryId(3))
    check vm.sizePages == 0
    check vm.grow(129)
    check vm.sizePages == 129
    check manager.memoryBucketCount(newMemoryId(3)) == 2
    check manager.allocatedBucketCount == 2

    # Small payload at offset 0.
    var first = [byte 1, 2, 3, 4]
    vm.write(0, addr first[0], uint64(first.len))
    var firstBack = newSeq[byte](first.len)
    vm.read(0, addr firstBack[0], uint64(firstBack.len))
    check firstBack == @first

    # 4-byte payload straddling the 128-page (8 MiB) bucket boundary.
    let boundary = MgrBucketSizePages * StablePageSize
    var crossing = [byte 0xAA, 0xBB, 0xCC, 0xDD]
    vm.write(boundary - 2, addr crossing[0], uint64(crossing.len))
    var crossingBack = newSeq[byte](crossing.len)
    vm.read(boundary - 2, addr crossingBack[0], uint64(crossingBack.len))
    check crossingBack == @crossing

    # Ownership table records bucket 0 and 1 for MemoryId 3.
    let allocations = readBytes(raw, uint64(MgrHeaderSize), 2)
    check allocations == @[byte(3), byte(3)]

  test "loads an existing ic-stable-structures image and coexists with SQLite":
    let raw: StableBackend = newVecStableBackend()
    raw.writeValidMgrFixture()
    let sentinel = [byte 0xA5, 0x5A, 0x19, 0xE7]
    raw.write(StablePageSize, unsafeAddr sentinel[0], uint64(sentinel.len))

    let manager = initMemoryManager(raw)
    check manager.memorySizePages(newMemoryId(7)) == 1
    check manager.memoryBucketCount(newMemoryId(7)) == 1
    check manager.allocatedBucketCount == 1

    # Bucket 0 belongs to MemoryId 7; a new memory must land in bucket 1+.
    let sqliteMemory = manager.getMemory(newMemoryId(8))
    var database: Db
    check database.init(sqliteMemory).isOk
    check database.exec("CREATE TABLE isolated (key TEXT PRIMARY KEY, value TEXT)").isOk
    check database.execText("INSERT INTO isolated(key, value) VALUES (?, ?)", ["a", "b"]).isOk
    database.close()
    check manager.memoryBucketCount(newMemoryId(8)) > 0
    check manager.allocatedBucketCount == 1 + uint64(manager.memoryBucketCount(newMemoryId(8)))

    # The independent owner's bucket is untouched.
    var after = readBytes(raw, StablePageSize, sentinel.len)
    check after == @sentinel

    # Re-open from scratch (restart) and confirm the SQLite image persisted.
    let reopened = initMemoryManager(raw)
    check reopened.memorySizePages(newMemoryId(7)) == 1
    var database2: Db
    check database2.init(reopened.getMemory(newMemoryId(8))).isOk
    let row = database2.queryOneText("SELECT value FROM isolated WHERE key = ?", ["a"])
    check row.isOk
    check row.value.isSome
    check row.value.get == "b"
    database2.close()

  test "places a SQLite-owned manager after the wasi2ic MGR prefix":
    let raw: StableBackend = newVecStableBackend()
    raw.writeValidMgrFixture()
    let sentinel = [byte 0x11, 0x22, 0x33, 0x44]
    raw.write(StablePageSize, unsafeAddr sentinel[0], uint64(sentinel.len))

    let manager = initMemoryManager(stableBackendAfterForeignManager(raw))
    check raw.sizePages > Wasi2icReservedStablePages
    check manager.rawBackend.sizePages == 1
    # The polyfill's own header and bucket are untouched.
    let header = readBytes(raw, 0, 3)
    check header == @[byte('M'), byte('G'), byte('R')]
    check readBytes(raw, StablePageSize, sentinel.len) == @sentinel
    # The SQLite-owned header lives at the reserved prefix, not at offset 0.
    let ownedMagic = readBytes(raw, Wasi2icReservedStablePages * StablePageSize, 3)
    check ownedMagic == @[byte('M'), byte('G'), byte('R')]

  test "rejects foreign and corrupt images without modifying them":
    let foreign: StableBackend = newVecStableBackend()
    check foreign.grow(1)
    var marker = [byte 1, 2, 3, 4, 5, 6, 7, 8]
    foreign.write(0, addr marker[0], uint64(marker.len))
    expect ValueError:
      discard initMemoryManager(foreign)
    check readBytes(foreign, 0, marker.len) == @marker

    let corrupt: StableBackend = newVecStableBackend()
    corrupt.writeValidMgrFixture()
    # Bucket 1 is declared unallocated but carries an owner.
    var owner = [MgrOwnerId]
    corrupt.write(uint64(MgrHeaderSize) + 1, addr owner[0], 1)
    expect ValueError:
      discard initMemoryManager(corrupt)

  test "enforces bounds, overflow and the bucket limit":
    let raw: StableBackend = newVecStableBackend()
    let manager = initMemoryManager(raw)
    let vm = manager.getMemory(newMemoryId(5))
    check vm.grow(1)
    expect ValueError:
      var byteOut: byte
      vm.read(StablePageSize, addr byteOut, 1)
    expect ValueError:
      var byteOut: byte
      vm.read(0, addr byteOut, StablePageSize + 1)
    # Arithmetic overflow is rejected before any backing grow.
    check not vm.grow(high(uint64))
    # Requesting more buckets than the allocation table can hold is rejected.
    let tooManyPages = (MaxNumBuckets + 1) * uint64(DefaultBucketSizeInPages)
    check not manager.getMemory(newMemoryId(6)).grow(tooManyPages)
