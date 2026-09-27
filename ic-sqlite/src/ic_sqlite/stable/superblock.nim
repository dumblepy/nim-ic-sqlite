import std/options
import ./[backend, checksum]

const
  SuperblockMagic* = "NIMSQLV1"
  SuperblockFormatVersion* = 1'u32
  SuperblockReservedBytes* = StablePageSize
  SuperblockFixedBytes* = 72
  MetaChecksumOffset = 64
  ZeroExtentBytes = 16

type
  Result*[T, E] = object
    isOk*: bool
    value*: T
    error*: E
  ZeroExtent* = object
    startPage*: uint64
    endPage*: uint64
  Superblock* = object
    formatVersion*: uint32
    sqlitePageSize*: uint32
    dbSize*: uint64
    schemaVersion*: uint64
    lastTxId*: uint64
    flags*: uint64
    dbChecksum*: uint64
    zeroExtents*: seq[ZeroExtent]

proc ok[T, E](value: T): Result[T, E] = Result[T, E](isOk: true, value: value)
proc err[T, E](message: E): Result[T, E] = Result[T, E](isOk: false, error: message)

proc putU32(data: var seq[byte]; offset: int; value: uint32) =
  for index in 0 ..< 4: data[offset + index] = byte(value shr (index * 8))
proc putU64(data: var seq[byte]; offset: int; value: uint64) =
  for index in 0 ..< 8: data[offset + index] = byte(value shr (index * 8))
proc getU32(data: openArray[byte]; offset: int): uint32 =
  for index in 0 ..< 4: result = result or (uint32(data[offset + index]) shl (index * 8))
proc getU64(data: openArray[byte]; offset: int): uint64 =
  for index in 0 ..< 8: result = result or (uint64(data[offset + index]) shl (index * 8))

proc encodeSuperblock*(sb: Superblock): seq[byte] =
  if sb.zeroExtents.len > (int(SuperblockReservedBytes) - SuperblockFixedBytes) div ZeroExtentBytes:
    raise newException(ValueError, "too many zero extents for superblock reservation")
  result = newSeq[byte](SuperblockFixedBytes + sb.zeroExtents.len * ZeroExtentBytes)
  for index, character in SuperblockMagic:
    result[index] = byte(ord(character))
  result.putU32(8, sb.formatVersion)
  result.putU32(12, sb.sqlitePageSize)
  result.putU64(16, sb.dbSize)
  result.putU64(24, sb.schemaVersion)
  result.putU64(32, sb.lastTxId)
  result.putU64(40, sb.flags)
  result.putU64(48, sb.dbChecksum)
  result.putU64(56, uint64(sb.zeroExtents.len))
  for index, extent in sb.zeroExtents:
    let offset = SuperblockFixedBytes + index * ZeroExtentBytes
    result.putU64(offset, extent.startPage)
    result.putU64(offset + 8, extent.endPage)
  result.putU64(MetaChecksumOffset, fnv1a64(result))

proc decodeSuperblock*(data: seq[byte]): Result[Superblock, string] =
  if data.len < SuperblockFixedBytes: return err[Superblock, string]("superblock is truncated")
  for index, character in SuperblockMagic:
    if data[index] != byte(ord(character)): return err[Superblock, string]("foreign stable memory image")
  let extentCount = getU64(data, 56)
  if extentCount > uint64((int(SuperblockReservedBytes) - SuperblockFixedBytes) div ZeroExtentBytes):
    return err[Superblock, string]("zero extent count exceeds superblock reservation")
  let encodedBytes = SuperblockFixedBytes + int(extentCount) * ZeroExtentBytes
  if data.len < encodedBytes: return err[Superblock, string]("zero extent table is truncated")
  var encoded = data[0 ..< encodedBytes]
  let expectedChecksum = getU64(encoded, MetaChecksumOffset)
  encoded.putU64(MetaChecksumOffset, 0)
  if fnv1a64(encoded) != expectedChecksum: return err[Superblock, string]("superblock checksum mismatch")
  var sb = Superblock(formatVersion: getU32(data, 8), sqlitePageSize: getU32(data, 12),
    dbSize: getU64(data, 16), schemaVersion: getU64(data, 24), lastTxId: getU64(data, 32),
    flags: getU64(data, 40), dbChecksum: getU64(data, 48))
  for index in 0 ..< int(extentCount):
    let offset = SuperblockFixedBytes + index * ZeroExtentBytes
    sb.zeroExtents.add ZeroExtent(startPage: getU64(data, offset), endPage: getU64(data, offset + 8))
  ok[Superblock, string](sb)

proc readExistingSuperblock*(storage: StableBackend): Result[Option[Superblock], string] =
  if storage.sizePages() == 0: return ok[Option[Superblock], string](none(Superblock))
  var header = newSeq[byte](SuperblockFixedBytes)
  try: storage.read(0, addr header[0], uint64(header.len))
  except CatchableError as error: return err[Option[Superblock], string](error.msg)
  ## Some IC runtimes allocate one zero-filled stable page before user code
  ## touches stable memory.  It is still uninitialized storage, not a foreign
  ## format.  Any non-zero header whose magic is not ours remains rejected.
  var allZero = true
  for value in header:
    if value != 0:
      allZero = false
      break
  if allZero: return ok[Option[Superblock], string](none(Superblock))
  let count = getU64(header, 56)
  if count > uint64((int(SuperblockReservedBytes) - SuperblockFixedBytes) div ZeroExtentBytes):
    return err[Option[Superblock], string]("zero extent count exceeds superblock reservation")
  let totalBytes = SuperblockFixedBytes + int(count) * ZeroExtentBytes
  var data = newSeq[byte](totalBytes)
  try: storage.read(0, addr data[0], uint64(data.len))
  except CatchableError as error: return err[Option[Superblock], string](error.msg)
  let decoded = decodeSuperblock(data)
  if not decoded.isOk: return err[Option[Superblock], string](decoded.error)
  ok[Option[Superblock], string](some(decoded.value))
