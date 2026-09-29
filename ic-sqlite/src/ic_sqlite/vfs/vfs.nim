import std/[strutils, tables]
import ../stable/[backend, superblock]
import ./[lock, overlay, temp_file]

const
  SqliteOk* = 0.cint
  SqliteCantOpen* = 14.cint
  SqliteIoErr* = 10.cint
  SqliteIoErrRead* = 266.cint
  SqliteIoErrWrite* = 778.cint
  SqliteIoErrShortRead* = 522.cint
  SqliteReadOnly* = 8.cint

type FileKind* = enum fkMainDb, fkTemp
type FileState* = ref object
  kind*: FileKind
  temp: TempFile
  lock: LockState

when defined(benchmarkProfile):
  ## Benchmark-only VFS counters. They are compiled out of normal builds; a
  ## zero temp-buffer count after the direct-I/O refactor is the expected
  ## regression guard for this hot path.
  type VfsProfileStats* = object
    tempBufferAllocs*: uint64     ## heap staging buffers created during one I/O
    tempBufferAllocBytes*: uint64
    readCalls*: uint64
    writeCalls*: uint64
    shortReads*: uint64
    truncateCalls*: uint64

var storage*: StableBackend
var databaseSize*: uint64
var activeOverlay*: Overlay
var overlayActive*: bool
var nextHandleId = 1'u32
var files = initTable[uint32, FileState]()
var lastError = ""
var randomState = 1'u64
var currentTimeNanoseconds*: uint64
var configuredMaxDirtyPages = high(uint64)
var configuredMaxDirtyBytes = high(uint64)
var configuredCleanCachePages = 0'u64
var persistedZeroExtents: seq[ZeroExtent]
var persistedZeroExtentPageSize = 16_384'u64

when defined(benchmarkProfile):
  var vfsProfile: VfsProfileStats
  var overlayProfile: OverlayProfileStats
    ## Accumulated over every overlay lifetime since the last reset; each
    ## SQLite transaction gets a fresh `Overlay`, so the per-overlay stats
    ## alone would miss all but the current operation.

  proc benchmarkVfsProfile*(): VfsProfileStats = vfsProfile
  proc benchmarkOverlayProfile*(): OverlayProfileStats = overlayProfile
  proc resetBenchmarkProfile*() =
    vfsProfile = VfsProfileStats()
    overlayProfile = OverlayProfileStats()
  proc countTempBuffer*(bytes: uint64) =
    ## Call site for every heap buffer that a single VFS I/O creates besides
    ## the dirty page itself. Direct I/O must keep this at zero on the main
    ## DB read/write hot path.
    inc vfsProfile.tempBufferAllocs
    vfsProfile.tempBufferAllocBytes += bytes

proc zeroPersistedRange(dst: pointer; length, offset: uint64) =
  ## Query connections read without an active overlay. Apply the logical
  ## truncation map before returning bytes from the stable backing store.
  if length == 0: return
  let endOffset = offset + length
  let target = cast[ptr UncheckedArray[byte]](dst)
  for extent in persistedZeroExtents:
    let zeroStart = extent.startPage * persistedZeroExtentPageSize
    let zeroEnd = extent.endPage * persistedZeroExtentPageSize
    let start = max(offset, zeroStart)
    let finish = min(endOffset, zeroEnd)
    if start < finish:
      zeroMem(addr target[int(start - offset)], int(finish - start))

when defined(wasm32):
  proc ic0TimeNanoseconds(): uint64 {.importc: "ic0_time", cdecl, header: "ic0.h".}

proc vfsTimeNanoseconds*(): uint64 =
  ## Native tests inject a deterministic value; canisters use consensus time.
  when defined(wasm32): ic0TimeNanoseconds()
  else: currentTimeNanoseconds

proc setLastError*(message: string) = lastError = message
proc lastErrorMessage*(): string = lastError
proc initVfs*(backend: StableBackend; dbSize = 0'u64; seed = 1'u64;
              maxDirtyPages = high(uint64); maxDirtyBytes = high(uint64);
              zeroExtents: openArray[ZeroExtent] = []; pageSize = 16_384'u32;
              cleanCachePages = 0'u64) =
  if pageSize == 0: raise newException(ValueError, "VFS page size must not be zero")
  storage = backend; databaseSize = dbSize; randomState = seed; files.clear(); nextHandleId = 1
  configuredMaxDirtyPages = maxDirtyPages; configuredMaxDirtyBytes = maxDirtyBytes
  configuredCleanCachePages = cleanCachePages
  when defined(benchmarkProfile):
    vfsProfile = VfsProfileStats()
    overlayProfile = OverlayProfileStats()
  persistedZeroExtents = @zeroExtents
  persistedZeroExtentPageSize = uint64(pageSize)
  overlayActive = false
proc setCleanCachePages*(pages: uint64) =
  ## Experimental knob. 0 keeps the clean page cache disabled (default);
  ## non-zero values only matter under the benchmark A/B experiments.
  configuredCleanCachePages = pages
proc beginOverlay*(pageSize = 16384'u32) =
  if storage.isNil: raise newException(ValueError, "VFS backend is not configured")
  activeOverlay = initOverlay(databaseSize, pageSize,
    maxDirtyPages = configuredMaxDirtyPages, maxDirtyBytes = configuredMaxDirtyBytes,
    cleanCachePages = int(configuredCleanCachePages))
  activeOverlay.zeroExtents = persistedZeroExtents
  persistedZeroExtentPageSize = uint64(pageSize)
  overlayActive = true
proc endOverlay*(publish = false) =
  if publish:
    activeOverlay.publishDirtyPages(storage)
    databaseSize = activeOverlay.size
    persistedZeroExtents = activeOverlay.zeroExtents
  when defined(benchmarkProfile):
    ## Merge before discard so the accumulator survives overlay teardown.
    overlayProfile.addFrom(activeOverlay.benchmarkProfile)
  activeOverlay.discardOverlay(); overlayActive = false
proc currentZeroExtents*(): seq[ZeroExtent] = persistedZeroExtents
proc openFile*(name: string; flags: cint; handleId: var uint32; outFlags: var cint): cint =
  if name.endsWith("-wal"): return SqliteCantOpen
  let state = FileState(kind: if name == "/main.db": fkMainDb else: fkTemp,
    temp: initTempFile(), lock: initLockState())
  if nextHandleId == 0: return SqliteIoErr
  handleId = nextHandleId; inc nextHandleId; files[handleId] = state; outFlags = flags; SqliteOk
proc closeFile*(handleId: uint32): cint =
  if not files.hasKey(handleId): return SqliteIoErr
  files.del(handleId); SqliteOk
proc stateFor(handleId: uint32): FileState =
  if not files.hasKey(handleId): raise newException(ValueError, "unknown VFS handle")
  files[handleId]
proc readFile*(handleId: uint32; dst: pointer; amount: cint; offset: int64): cint =
  if amount < 0 or offset < 0 or (amount > 0 and dst.isNil): return SqliteIoErrRead
  try:
    let state = stateFor(handleId); let size = int(amount)
    var short = false
    if state.kind == fkTemp:
      if offset > int64(high(int)): return SqliteIoErrRead
      short = not state.temp.readInto(int(offset), dst, size)
    elif overlayActive:
      short = not activeOverlay.readInto(storage, uint64(offset), dst, uint64(size))
    else:
      if size > 0: zeroMem(dst, size)
      short = uint64(offset) >= databaseSize or uint64(size) > databaseSize - uint64(offset)
      let readable = if uint64(offset) >= databaseSize: 0'u64 else: min(uint64(size), databaseSize - uint64(offset))
      if readable > 0: storage.read(SuperblockReservedBytes + uint64(offset), dst, readable)
      zeroPersistedRange(dst, uint64(size), uint64(offset))
    when defined(benchmarkProfile):
      inc vfsProfile.readCalls
      if short: inc vfsProfile.shortReads
    if short: SqliteIoErrShortRead else: SqliteOk
  except CatchableError as error: setLastError(error.msg); SqliteIoErrRead
proc writeFile*(handleId: uint32; src: pointer; amount: cint; offset: int64): cint =
  if amount < 0 or offset < 0 or (amount > 0 and src.isNil): return SqliteIoErrWrite
  try:
    let state = stateFor(handleId); let size = int(amount)
    when defined(benchmarkProfile): inc vfsProfile.writeCalls
    if state.kind == fkTemp:
      if offset > int64(high(int)): return SqliteIoErrWrite
      state.temp.writeFrom(int(offset), src, size)
    elif not overlayActive: return SqliteReadOnly
    else: activeOverlay.writeFrom(storage, uint64(offset), src, uint64(size))
    SqliteOk
  except CatchableError as error: setLastError(error.msg); SqliteIoErrWrite
proc truncateFile*(handleId: uint32; size: int64): cint =
  if size < 0: return SqliteIoErr
  try:
    let state = stateFor(handleId)
    when defined(benchmarkProfile): inc vfsProfile.truncateCalls
    if state.kind == fkTemp:
      if uint64(size) > uint64(high(int)): return SqliteIoErr
      state.temp.truncate(int(size))
    elif overlayActive: activeOverlay.truncate(uint64(size), storage)
    else: return SqliteReadOnly
    SqliteOk
  except CatchableError as error: setLastError(error.msg); SqliteIoErr
proc fileSize*(handleId: uint32; size: var int64): cint =
  try:
    let state = stateFor(handleId)
    let fileLen = if state.kind == fkTemp: uint64(state.temp.len)
      elif overlayActive: activeOverlay.size else: databaseSize
    if fileLen > uint64(high(int64)): return SqliteIoErr
    size = int64(fileLen)
    SqliteOk
  except CatchableError as error: setLastError(error.msg); SqliteIoErr
proc lockFile*(handleId: uint32; level: cint): cint =
  try:
    if stateFor(handleId).lock.lock(LockLevel(level)): SqliteOk else: SqliteIoErr
  except CatchableError: SqliteIoErr
proc unlockFile*(handleId: uint32; level: cint): cint =
  try:
    if stateFor(handleId).lock.unlock(LockLevel(level)): SqliteOk else: SqliteIoErr
  except CatchableError: SqliteIoErr
proc reservedFile*(handleId: uint32; reserved: var cint): cint =
  try:
    reserved = if stateFor(handleId).lock.checkReservedLock: 1 else: 0
    SqliteOk
  except CatchableError: SqliteIoErr
proc randomBytes*(dst: pointer; amount: cint): cint =
  if dst.isNil or amount < 0: return 0
  for index in 0 ..< int(amount):
    randomState = randomState xor (randomState shl 13); randomState = randomState xor (randomState shr 7); randomState = randomState xor (randomState shl 17)
    cast[ptr UncheckedArray[byte]](dst)[index] = byte(randomState)
  amount
