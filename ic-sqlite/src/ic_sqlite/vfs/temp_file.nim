## Heap-only implementation for SQLite journals and temporary databases.

type TempFile* = object
  data: seq[byte]

proc initTempFile*(): TempFile = TempFile(data: @[])
proc len*(file: TempFile): int {.inline.} = file.data.len

proc readAt*(file: TempFile; offset, size: int): seq[byte] =
  if offset < 0 or size < 0: raise newException(ValueError, "negative temp-file range")
  result = newSeq[byte](size)
  if offset >= file.data.len or size == 0: return
  let readable = min(size, file.data.len - offset)
  copyMem(addr result[0], unsafeAddr file.data[offset], readable)

proc writeAt*(file: var TempFile; offset: int; data: openArray[byte]) =
  if offset < 0: raise newException(ValueError, "negative temp-file offset")
  if data.len > high(int) - offset: raise newException(ValueError, "temp-file write is too large")
  let endOffset = offset + data.len
  if endOffset > file.data.len: file.data.setLen(endOffset)
  if data.len > 0: copyMem(addr file.data[offset], unsafeAddr data[0], data.len)

proc truncate*(file: var TempFile; size: int) =
  if size < 0: raise newException(ValueError, "negative temp-file size")
  file.data.setLen(size)
