## Heap-resident write overlay. Logical DB offsets are translated to stable
## memory only when dirty pages are published after SQLite COMMIT succeeds.
import std/[algorithm, sequtils, tables]
import ../stable/[backend, superblock]

type Overlay* = object
  baseSize*: uint64
  size*: uint64
  pageSize*: uint32
  dbBaseOffset*: uint64
  maxDirtyPages*: uint64
  maxDirtyBytes*: uint64
  dirtyPages: Table[uint64, seq[byte]]
  zeroExtents*: seq[ZeroExtent]

type PublishStartedError* = object of CatchableError

proc initOverlay*(baseSize: uint64; pageSize = 16384'u32;
                  dbBaseOffset = SuperblockReservedBytes;
                  maxDirtyPages = high(uint64); maxDirtyBytes = high(uint64)): Overlay =
  if pageSize == 0: raise newException(ValueError, "overlay page size must not be zero")
  Overlay(baseSize: baseSize, size: baseSize, pageSize: pageSize,
    dbBaseOffset: dbBaseOffset, maxDirtyPages: maxDirtyPages,
    maxDirtyBytes: maxDirtyBytes, dirtyPages: initTable[uint64, seq[byte]]())

proc pageBytes(overlay: Overlay): uint64 {.inline.} = uint64(overlay.pageSize)
proc pageIsZero(overlay: Overlay; page: uint64): bool =
  for extent in overlay.zeroExtents:
    if page >= extent.startPage and page < extent.endPage: return true

proc removeZeroPage(overlay: var Overlay; page: uint64) =
  var revised: seq[ZeroExtent]
  for extent in overlay.zeroExtents:
    if page < extent.startPage or page >= extent.endPage:
      revised.add extent
    else:
      if extent.startPage < page: revised.add ZeroExtent(startPage: extent.startPage, endPage: page)
      if page + 1 < extent.endPage: revised.add ZeroExtent(startPage: page + 1, endPage: extent.endPage)
  overlay.zeroExtents = revised

proc addZeroExtent(overlay: var Overlay; startPage, endPage: uint64) =
  if startPage >= endPage: return
  var start = startPage
  var finish = endPage
  var revised: seq[ZeroExtent]
  for extent in overlay.zeroExtents:
    if extent.endPage < start or finish < extent.startPage:
      revised.add extent
    else:
      start = min(start, extent.startPage)
      finish = max(finish, extent.endPage)
  revised.add ZeroExtent(startPage: start, endPage: finish)
  revised.sort(proc(a, b: ZeroExtent): int = cmp(a.startPage, b.startPage))
  overlay.zeroExtents = revised

proc ensureDirtyPage(overlay: var Overlay; storage: StableBackend; page: uint64;
                     loadBase: bool) =
  ## Inserts at most one resident page. Existing table entries are subsequently
  ## mutated through `mget`, never copied out and assigned back.
  if overlay.dirtyPages.hasKey(page): return
  let nextPages = uint64(overlay.dirtyPages.len) + 1
  if nextPages > overlay.maxDirtyPages or
      nextPages > overlay.maxDirtyBytes div overlay.pageBytes:
    raise newException(ValueError, "dirty overlay limit exceeded")
  var data = newSeq[byte](int(overlay.pageSize))
  if loadBase:
    if page > high(uint64) div overlay.pageBytes:
      raise newException(ValueError, "overlay page offset overflows")
    let pageOffset = page * overlay.pageBytes
    if not overlay.pageIsZero(page) and pageOffset < overlay.baseSize:
      let readable = min(overlay.pageBytes, overlay.baseSize - pageOffset)
      storage.read(overlay.dbBaseOffset + pageOffset, addr data[0], readable)
  overlay.dirtyPages[page] = move(data)

proc readInto*(overlay: var Overlay; storage: StableBackend; offset: uint64;
               dst: pointer; length: uint64): bool =
  ## Reads directly into a borrowed VFS buffer. The buffer is zero-filled
  ## before copying so EOF and logical zero extents cannot expose old bytes.
  if length == 0: return true
  if dst.isNil or length > uint64(high(int)):
    raise newException(ValueError, "invalid overlay read buffer")
  zeroMem(dst, int(length))
  if offset >= overlay.size: return false
  let validLen = min(length, overlay.size - offset)
  var position = offset
  var destination = 0'u64
  while destination < validLen:
    let page = position div overlay.pageBytes
    let inPage = int(position mod overlay.pageBytes)
    let take = min(validLen - destination, overlay.pageBytes - uint64(inPage))
    let target = cast[ptr UncheckedArray[byte]](dst)
    if overlay.dirtyPages.hasKey(page):
      let source = overlay.dirtyPages[page]
      copyMem(addr target[int(destination)], unsafeAddr source[inPage], int(take))
    elif not overlay.pageIsZero(page) and position < overlay.baseSize:
      let readable = min(take, overlay.baseSize - position)
      if readable > 0:
        storage.read(overlay.dbBaseOffset + position, addr target[int(destination)], readable)
    position += take
    destination += take
  result = validLen == length

proc readAt*(overlay: var Overlay; storage: StableBackend; offset, length: uint64): seq[byte] =
  if length == 0: return @[]
  if length > uint64(high(int)): raise newException(ValueError, "overlay read is too large")
  result = newSeq[byte](int(length))
  discard overlay.readInto(storage, offset, addr result[0], length)

proc truncate*(overlay: var Overlay; newSize: uint64; storage: StableBackend = nil)

proc writeFrom*(overlay: var Overlay; storage: StableBackend; offset: uint64;
                src: pointer; length: uint64) =
  if length == 0: return
  if src.isNil or length > uint64(high(int)) or length > high(uint64) - offset:
    raise newException(ValueError, "invalid overlay write buffer")
  let endOffset = offset + length
  if endOffset > overlay.size:
    overlay.truncate(endOffset, storage)
  var position = offset
  var sourceOffset = 0'u64
  while sourceOffset < length:
    let page = position div overlay.pageBytes
    let inPage = int(position mod overlay.pageBytes)
    let take = min(length - sourceOffset, overlay.pageBytes - uint64(inPage))
    overlay.ensureDirtyPage(storage, page,
      loadBase = not (inPage == 0 and take == overlay.pageBytes))
    overlay.dirtyPages.withValue(page, target):
      copyMem(addr target[][inPage],
        unsafeAddr cast[ptr UncheckedArray[byte]](src)[int(sourceOffset)], int(take))
    overlay.removeZeroPage(page)
    position += take
    sourceOffset += take
  overlay.size = max(overlay.size, endOffset)

proc writeAt*(overlay: var Overlay; storage: StableBackend; offset: uint64; data: openArray[byte]) =
  if data.len == 0: return
  overlay.writeFrom(storage, offset, unsafeAddr data[0], uint64(data.len))

proc truncate*(overlay: var Overlay; newSize: uint64; storage: StableBackend = nil) =
  if newSize < overlay.size:
    let partial = newSize mod overlay.pageBytes
    if partial != 0:
      if storage.isNil: raise newException(ValueError, "storage is required for partial truncate")
      let page = newSize div overlay.pageBytes
      overlay.ensureDirtyPage(storage, page, loadBase = true)
      overlay.dirtyPages.withValue(page, target):
        zeroMem(addr target[][int(partial)], int(overlay.pageBytes - partial))
    let firstZeroPage = (newSize + overlay.pageBytes - 1) div overlay.pageBytes
    let oldEndPage = (overlay.size + overlay.pageBytes - 1) div overlay.pageBytes
    overlay.addZeroExtent(firstZeroPage, oldEndPage)
    var removePages: seq[uint64]
    for page in overlay.dirtyPages.keys:
      if page * overlay.pageBytes >= newSize: removePages.add page
    for page in removePages: overlay.dirtyPages.del(page)
  elif newSize > overlay.size:
    ## Preserve the zero tail of a prior truncate when it becomes visible again.
    let partial = overlay.size mod overlay.pageBytes
    if partial != 0:
      if storage.isNil: raise newException(ValueError, "storage is required for overlay extension")
      let page = overlay.size div overlay.pageBytes
      overlay.ensureDirtyPage(storage, page, loadBase = true)
      overlay.dirtyPages.withValue(page, target):
        zeroMem(addr target[][int(partial)], int(overlay.pageBytes - partial))
    let firstZeroPage = (overlay.size + overlay.pageBytes - 1) div overlay.pageBytes
    let endPage = (newSize + overlay.pageBytes - 1) div overlay.pageBytes
    overlay.addZeroExtent(firstZeroPage, endPage)
  overlay.size = newSize

proc dirtyPageCount*(overlay: Overlay): int = overlay.dirtyPages.len

proc publishDirtyPages*(overlay: Overlay; storage: StableBackend) =
  var pages = toSeq(overlay.dirtyPages.keys)
  pages.sort()
  var requiredBytes = overlay.dbBaseOffset + overlay.size
  for page in pages:
    requiredBytes = max(requiredBytes, overlay.dbBaseOffset + (page + 1) * overlay.pageBytes)
  let requiredStablePages = (requiredBytes + StablePageSize - 1) div StablePageSize
  if requiredStablePages > storage.sizePages and not storage.grow(requiredStablePages - storage.sizePages):
    raise newException(ValueError, "unable to grow stable memory for overlay publish")
  var started = false
  try:
    for page in pages:
      overlay.dirtyPages.withValue(page, data):
        started = true
        storage.write(overlay.dbBaseOffset + page * overlay.pageBytes,
          unsafeAddr data[0], uint64(data.len))
  except CatchableError as error:
    if started: raise newException(PublishStartedError, error.msg)
    raise

proc discardOverlay*(overlay: var Overlay) =
  overlay.dirtyPages.clear()
  overlay.zeroExtents.setLen(0)
  overlay.size = overlay.baseSize
