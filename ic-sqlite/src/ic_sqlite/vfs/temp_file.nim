## Heap-only implementation for SQLite journals and temporary databases.

type TempFile* = object
  data: seq[byte]

proc initTempFile*(): TempFile = TempFile(data: @[])
proc len*(file: TempFile): int {.inline.} = file.data.len

proc readInto*(file: TempFile; offset: int; dst: pointer; size: int): bool =
  ## Copies directly to the SQLite-owned buffer and returns whether all bytes
  ## were available.  The unread suffix is always zero-filled.
  if offset < 0 or size < 0: raise newException(ValueError, "negative temp-file range")
  if size == 0: return true
  if dst.isNil: raise newException(ValueError, "nil temp-file read buffer")
  zeroMem(dst, size)
  if offset >= file.data.len: return false
  let readable = min(size, file.data.len - offset)
  copyMem(dst, unsafeAddr file.data[offset], readable)
  result = readable == size

proc writeFrom*(file: var TempFile; offset: int; src: pointer; size: int) =
  ## `src` is borrowed for this call only; the temp file owns its copied bytes.
  if offset < 0 or size < 0 or size > high(int) - offset:
    raise newException(ValueError, "invalid temp-file write range")
  if size == 0: return
  if src.isNil: raise newException(ValueError, "nil temp-file write buffer")
  let endOffset = offset + size
  if endOffset > file.data.len: file.data.setLen(endOffset)
  copyMem(addr file.data[offset], src, size)

proc readAt*(file: TempFile; offset, size: int): seq[byte] =
  if offset < 0 or size < 0: raise newException(ValueError, "negative temp-file range")
  result = newSeq[byte](size)
  if size > 0: discard file.readInto(offset, addr result[0], size)

proc writeAt*(file: var TempFile; offset: int; data: openArray[byte]) =
  if data.len == 0:
    if offset < 0: raise newException(ValueError, "negative temp-file offset")
    return
  file.writeFrom(offset, unsafeAddr data[0], data.len)

proc truncate*(file: var TempFile; size: int) =
  if size < 0: raise newException(ValueError, "negative temp-file size")
  file.data.setLen(size)
