## Heap-resident write overlay. Logical DB offsets are translated to stable
## memory only when dirty pages are published after SQLite COMMIT succeeds.
import std/[algorithm, sequtils, tables]
import ../stable/[backend, superblock]

when defined(benchmarkProfile):
  ## Benchmark-only overlay counters, compiled out of normal builds so the
  ## update hot path keeps its uninstrumented instruction count.
  type OverlayProfileStats* = object
    dirtyPageNew*: uint64       ## count of newly resident dirty pages
    dirtyPageNewBytes*: uint64  ## bytes reserved when first dirtied
    dirtyPagePeak*: uint64      ## high-water mark of resident dirty pages
    cleanCacheHits*: uint64     ## read page served from the clean cache
    cleanCacheMisses*: uint64   ## read page loaded from base instead
    cleanCacheReadBytes*: uint64
    cleanCacheEvictions*: uint64

type
  Overlay* = object
    baseSize*: uint64
    size*: uint64
    pageSize*: uint32
    dbBaseOffset*: uint64
    maxDirtyPages*: uint64
    maxDirtyBytes*: uint64
    dirtyPages: Table[uint64, seq[byte]]
    zeroExtents*: seq[ZeroExtent]
    ## Optional read cache for base pages that are not dirty. Disabled by
    ## default (`cleanCacheMax == 0`) and only measurable under
    ## `-d:benchmarkProfile` on the benchmark canister builds.
    cleanCacheMax: uint64
    cleanCache: Table[uint64, seq[byte]]
    when defined(benchmarkProfile):
      profile: OverlayProfileStats

type PublishStartedError* = object of CatchableError

proc initOverlay*(baseSize: uint64; pageSize = 16384'u32;
                  dbBaseOffset = SuperblockReservedBytes;
                  maxDirtyPages = high(uint64); maxDirtyBytes = high(uint64);
                  cleanCachePages = -1): Overlay =
  ## `cleanCachePages < 0` keeps the default (disabled). Negative or zero
  ## values keep the cache empty; 2/4/8 are used only by benchmark builds.
  if pageSize == 0: raise newException(ValueError, "overlay page size must not be zero")
  let cleanLimit = if cleanCachePages < 0: 0'u64 else: uint64(cleanCachePages)
  Overlay(baseSize: baseSize, size: baseSize, pageSize: pageSize,
    dbBaseOffset: dbBaseOffset, maxDirtyPages: maxDirtyPages,
    maxDirtyBytes: maxDirtyBytes, dirtyPages: initTable[uint64, seq[byte]](),
    cleanCacheMax: cleanLimit, cleanCache: initTable[uint64, seq[byte]]())

when defined(benchmarkProfile):
  proc benchmarkProfile*(overlay: Overlay): OverlayProfileStats = overlay.profile

  proc addFrom*(target: var OverlayProfileStats; source: OverlayProfileStats) =
    ## Each SQLite transaction gets a fresh `Overlay`; VFS-level totals are the
    ## sum over the overlay lifetimes inside one benchmark window.
    target.dirtyPageNew += source.dirtyPageNew
    target.dirtyPageNewBytes += source.dirtyPageNewBytes
    target.dirtyPagePeak = max(target.dirtyPagePeak, source.dirtyPagePeak)
    target.cleanCacheHits += source.cleanCacheHits
    target.cleanCacheMisses += source.cleanCacheMisses
    target.cleanCacheEvictions += source.cleanCacheEvictions
    target.cleanCacheReadBytes += source.cleanCacheReadBytes

proc cleanPageCached(overlay: var Overlay; page: uint64) =
  ## The cache only holds immutable base pages; a page that becomes dirty may
  ## no longer be served from it.
  if overlay.cleanCacheMax == 0: return
  if overlay.cleanCache.hasKey(page):
    overlay.cleanCache.del(page)
    when defined(benchmarkProfile):
      inc overlay.profile.cleanCacheEvictions

proc pageBytes(overlay: Overlay): uint64 {.inline.} = uint64(overlay.pageSize)
proc pageIsZero(overlay: Overlay; page: uint64): bool =
  if overlay.zeroExtents.len == 0: return false
  for extent in overlay.zeroExtents:
    if page >= extent.startPage and page < extent.endPage: return true

proc removeZeroPage(overlay: var Overlay; page: uint64) =
  if overlay.zeroExtents.len == 0: return
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
      if overlay.cleanCache.hasKey(page):
        let cached = overlay.cleanCache[page]
        copyMem(addr data[0], unsafeAddr cached[0], int(readable))
        when defined(benchmarkProfile):
          inc overlay.profile.cleanCacheHits
          overlay.profile.cleanCacheReadBytes += readable
      else:
        storage.read(overlay.dbBaseOffset + pageOffset, addr data[0], readable)
  overlay.cleanPageCached(page)
  overlay.dirtyPages[page] = move(data)
  when defined(benchmarkProfile):
    inc overlay.profile.dirtyPageNew
    overlay.profile.dirtyPageNewBytes += overlay.pageBytes
    overlay.profile.dirtyPagePeak = max(overlay.profile.dirtyPagePeak,
      uint64(overlay.dirtyPages.len))

proc readInto*(overlay: var Overlay; storage: StableBackend; offset: uint64;
               dst: pointer; length: uint64): bool =
  ## Reads directly into a borrowed VFS buffer without zero-filling the whole
  ## buffer up front. Only bytes that are not supplied by a dirty page or the
  ## base image are zeroed: logical zero extents, the base-image EOF tail and
  ## the EOF tail of the request. This keeps short-read semantics (all bytes
  ## after EOF are zero) and never exposes stale or sparse bytes.
  if length == 0: return true
  if dst.isNil or length > uint64(high(int)):
    raise newException(ValueError, "invalid overlay read buffer")
  let target = cast[ptr UncheckedArray[byte]](dst)
  if offset >= overlay.size:
    zeroMem(dst, int(length))
    return false
  let validLen = min(length, overlay.size - offset)
  var position = offset
  var destination = 0'u64
  while destination < validLen:
    let page = position div overlay.pageBytes
    let inPage = int(position mod overlay.pageBytes)
    let take = min(validLen - destination, overlay.pageBytes - uint64(inPage))
    if overlay.dirtyPages.hasKey(page):
      let source = overlay.dirtyPages[page]
      copyMem(addr target[int(destination)], unsafeAddr source[inPage], int(take))
    elif overlay.pageIsZero(page) or position >= overlay.baseSize:
      zeroMem(addr target[int(destination)], int(take))
    else:
      let readable = min(take, overlay.baseSize - position)
      if readable > 0:
        if inPage == 0 and take == overlay.pageBytes:
          ## Whole clean page: serve from the optional cache when enabled.
          if overlay.cleanCache.hasKey(page):
            let cached = overlay.cleanCache[page]
            copyMem(addr target[int(destination)], unsafeAddr cached[inPage], int(take))
            when defined(benchmarkProfile):
              inc overlay.profile.cleanCacheHits
          else:
            if overlay.cleanCacheMax > 0:
              var buffer = newSeq[byte](int(overlay.pageSize))
              storage.read(overlay.dbBaseOffset + position, addr buffer[0], readable)
              copyMem(addr target[int(destination)], unsafeAddr buffer[inPage], int(take))
              if uint64(overlay.cleanCache.len) >= overlay.cleanCacheMax:
                ## The experimental cache is tiny (0/2/4/8 pages); arbitrary
                ## eviction is acceptable for the A/B measurement.
                var evicted: uint64
                for candidate in overlay.cleanCache.keys:
                  evicted = candidate
                  break
                overlay.cleanCache.del(evicted)
                when defined(benchmarkProfile):
                  inc overlay.profile.cleanCacheEvictions
              overlay.cleanCache[page] = move(buffer)
              when defined(benchmarkProfile):
                inc overlay.profile.cleanCacheMisses
                overlay.profile.cleanCacheReadBytes += readable
            else:
              storage.read(overlay.dbBaseOffset + position, addr target[int(destination)], readable)
              if readable < take:
                zeroMem(addr target[int(destination) + int(readable)], int(take - readable))
        else:
          storage.read(overlay.dbBaseOffset + position, addr target[int(destination)], readable)
          if readable < take:
            zeroMem(addr target[int(destination) + int(readable)], int(take - readable))
    position += take
    destination += take
  if validLen < length:
    zeroMem(addr target[int(validLen)], int(length - validLen))
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
    ## Bytes removed by the truncate are logically zero now; cached base
    ## copies of whole removed pages would keep dead data resident.
    var removeCached: seq[uint64]
    for page in overlay.cleanCache.keys:
      if page >= firstZeroPage: removeCached.add page
    for page in removeCached: overlay.cleanCache.del(page)
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

proc cleanCacheCount*(overlay: Overlay): int = overlay.cleanCache.len
proc cleanCacheMaxPages*(overlay: Overlay): uint64 = overlay.cleanCacheMax

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
  overlay.cleanCache.clear()
