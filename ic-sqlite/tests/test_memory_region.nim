import std/unittest
import ic_sqlite
import ic_sqlite/stable/backend

# `ic-stable-structures` MemoryManager 0.7 layout. This fixture owns the
# first physical bucket (pages 1..128) through MemoryId 7. It is deliberately
# a complete, reloadable MGR image rather than only a three-byte magic prefix.
const
  MgrHeaderSize = 2080
  MgrAllocationTableSize = 32768
  MgrBucketSizePages = 128'u64
  MgrOwnerId = 7'u8
  MgrUnallocated = 255'u8
  MgrMemorySizesOffset = 40

proc putLe64(bytes: var openArray[byte]; offset: int; value: uint64) =
  for index in 0 ..< 8:
    bytes[offset + index] = byte((value shr (index * 8)) and 0xff)

proc writeValidMgrFixture(raw: StableBackend) =
  # Header page plus one 128-page bucket is the minimum valid backing size.
  check raw.grow(1 + MgrBucketSizePages)
  var header = newSeq[byte](MgrHeaderSize)
  header[0 .. 2] = [byte('M'), byte('G'), byte('R')]
  header[3] = 1 # layout version
  header[4] = 1 # one allocated bucket, little endian u16
  header[6] = byte(MgrBucketSizePages) # bucket size, little endian u16
  header.putLe64(MgrMemorySizesOffset + int(MgrOwnerId) * 8, 1)
  raw.write(0, unsafeAddr header[0], uint64(header.len))

  var allocations = newSeq[byte](MgrAllocationTableSize)
  for index in 0 ..< allocations.len: allocations[index] = MgrUnallocated
  allocations[0] = MgrOwnerId
  raw.write(uint64(MgrHeaderSize), unsafeAddr allocations[0], uint64(allocations.len))

proc checkValidMgrFixture(raw: StableBackend) =
  check raw.sizePages >= 1 + MgrBucketSizePages
  var header = newSeq[byte](MgrHeaderSize)
  raw.read(0, addr header[0], uint64(header.len))
  check header[0 .. 2] == [byte('M'), byte('G'), byte('R')]
  check header[3] == 1
  check header[4] == 1 and header[5] == 0
  check header[6] == byte(MgrBucketSizePages) and header[7] == 0
  check header[MgrMemorySizesOffset + int(MgrOwnerId) * 8] == 1
  var allocations = newSeq[byte](MgrAllocationTableSize)
  raw.read(uint64(MgrHeaderSize), addr allocations[0], uint64(allocations.len))
  check allocations[0] == MgrOwnerId
  for index in 1 ..< allocations.len: check allocations[index] == MgrUnallocated

suite "MemoryManager stable-memory isolation":
  test "SQLite preserves a valid MGR owner's bucket":
    let raw: StableBackend = newVecStableBackend()
    raw.writeValidMgrFixture()
    raw.checkValidMgrFixture()

    # Physical page 1 is bucket 0's payload. SQLite must begin at page 1025.
    let sentinel = [byte 0xA5, 0x5A, 0x19, 0xE7]
    raw.write(StablePageSize, unsafeAddr sentinel[0], uint64(sentinel.len))

    var database: Db
    check database.init(raw).isOk
    check database.exec("CREATE TABLE isolated (key TEXT PRIMARY KEY, value TEXT)").isOk
    check database.execText("INSERT INTO isolated(key, value) VALUES (?, ?)", ["a", "b"]).isOk
    database.close()

    # SQLite growth crossed the reserved 1025-page prefix without changing
    # either the MGR metadata or the independently owned bucket.
    check raw.sizePages > 1025
    raw.checkValidMgrFixture()
    var after: array[4, byte]
    raw.read(StablePageSize, addr after[0], uint64(after.len))
    check after == sentinel
