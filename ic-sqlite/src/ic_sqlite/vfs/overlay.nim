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
  dirtyPages: OrderedTable[uint64, seq[byte]]
  zeroExtents*: seq[ZeroExtent]

type PublishStartedError* = object of CatchableError

proc initOverlay*(baseSize: uint64; pageSize = 16384'u32;
                  dbBaseOffset = SuperblockReservedBytes;
                  maxDirtyPages = high(uint64); maxDirtyBytes = high(uint64)): Overlay =
  if pageSize == 0: raise newException(ValueError, "overlay page size must not be zero")
  Overlay(baseSize: baseSize, size: baseSize, pageSize: pageSize,
    dbBaseOffset: dbBaseOffset, maxDirtyPages: maxDirtyPages,
    maxDirtyBytes: maxDirtyBytes, dirtyPages: initOrderedTable[uint64, seq[byte]]())

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

proc loadPage(overlay: var Overlay; storage: StableBackend; page: uint64): seq[byte] =
  if overlay.dirtyPages.hasKey(page): return overlay.dirtyPages[page]
  result = newSeq[byte](int(overlay.pageSize))
  let pageOffset = page * overlay.pageBytes
  if overlay.pageIsZero(page) or pageOffset >= overlay.baseSize: return
  let readable = min(overlay.pageBytes, overlay.baseSize - pageOffset)
  storage.read(overlay.dbBaseOffset + pageOffset, addr result[0], readable)

proc readAt*(overlay: var Overlay; storage: StableBackend; offset, length: uint64): seq[byte] =
  if length == 0: return @[]
  if length > uint64(high(int)): raise newException(ValueError, "overlay read is too large")
  result = newSeq[byte](int(length))
  var position = offset
  var destination = 0
  while destination < result.len:
    let page = position div overlay.pageBytes
    let inPage = int(position mod overlay.pageBytes)
    let take = min(result.len - destination, int(overlay.pageBytes) - inPage)
    let source = overlay.loadPage(storage, page)
    copyMem(addr result[destination], unsafeAddr source[inPage], take)
    position += uint64(take)
    destination += take

proc writeAt*(overlay: var Overlay; storage: StableBackend; offset: uint64; data: openArray[byte]) =
  var position = offset
  var sourceOffset = 0
  while sourceOffset < data.len:
    let page = position div overlay.pageBytes
    let inPage = int(position mod overlay.pageBytes)
    let take = min(data.len - sourceOffset, int(overlay.pageBytes) - inPage)
    if not overlay.dirtyPages.hasKey(page):
      let nextPages = uint64(overlay.dirtyPages.len) + 1
      if nextPages > overlay.maxDirtyPages or
          nextPages > overlay.maxDirtyBytes div overlay.pageBytes:
        raise newException(ValueError, "dirty overlay limit exceeded")
    var target: seq[byte]
    if inPage == 0 and take == int(overlay.pageBytes):
      target = newSeq[byte](int(overlay.pageSize))
    else:
      target = overlay.loadPage(storage, page)
    copyMem(addr target[inPage], unsafeAddr data[sourceOffset], take)
    overlay.dirtyPages[page] = target
    overlay.removeZeroPage(page)
    position += uint64(take)
    sourceOffset += take
  overlay.size = max(overlay.size, offset + uint64(data.len))

proc truncate*(overlay: var Overlay; newSize: uint64) =
  if newSize < overlay.size:
    let firstZeroPage = (newSize + overlay.pageBytes - 1) div overlay.pageBytes
    let oldEndPage = (overlay.size + overlay.pageBytes - 1) div overlay.pageBytes
    overlay.addZeroExtent(firstZeroPage, oldEndPage)
    var removePages: seq[uint64]
    for page in overlay.dirtyPages.keys:
      if page * overlay.pageBytes >= newSize: removePages.add page
    for page in removePages: overlay.dirtyPages.del(page)
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
      let data = overlay.dirtyPages[page]
      started = true
      storage.write(overlay.dbBaseOffset + page * overlay.pageBytes, unsafeAddr data[0], uint64(data.len))
  except CatchableError as error:
    if started: raise newException(PublishStartedError, error.msg)
    raise

proc discardOverlay*(overlay: var Overlay) =
  overlay.dirtyPages.clear()
  overlay.zeroExtents.setLen(0)
  overlay.size = overlay.baseSize
