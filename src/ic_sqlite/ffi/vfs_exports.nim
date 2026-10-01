import ../vfs/vfs
proc nim_icvfs_open*(name: cstring; flags: cint; id: ptr uint32; outFlags: ptr cint): cint {.exportc, cdecl, raises: [].} =
  try: openFile(if name.isNil: "" else: $name, flags, id[], outFlags[]) except: setLastError("VFS open failure"); SqliteCantOpen
proc nim_icvfs_close*(id: uint32): cint {.exportc, cdecl, raises: [].} =
  try: closeFile(id) except: SqliteIoErr
proc nim_icvfs_read*(id: uint32; dst: pointer; amount: cint; offset: int64): cint {.exportc, cdecl, raises: [].} =
  try: readFile(id, dst, amount, offset) except: SqliteIoErrRead
proc nim_icvfs_write*(id: uint32; src: pointer; amount: cint; offset: int64): cint {.exportc, cdecl, raises: [].} =
  try: writeFile(id, src, amount, offset) except: SqliteIoErrWrite
proc nim_icvfs_truncate*(id: uint32; size: int64): cint {.exportc, cdecl, raises: [].} =
  try: truncateFile(id, size) except: SqliteIoErr
proc nim_icvfs_file_size*(id: uint32; size: ptr int64): cint {.exportc, cdecl, raises: [].} =
  if size.isNil: SqliteIoErr else: fileSize(id, size[])
proc nim_icvfs_lock*(id: uint32; level: cint): cint {.exportc, cdecl, raises: [].} =
  try: lockFile(id, level) except: SqliteIoErr
proc nim_icvfs_unlock*(id: uint32; level: cint): cint {.exportc, cdecl, raises: [].} =
  try: unlockFile(id, level) except: SqliteIoErr
proc nim_icvfs_check_reserved_lock*(id: uint32; value: ptr cint): cint {.exportc, cdecl, raises: [].} =
  if value.isNil: SqliteIoErr else: reservedFile(id, value[])
proc nim_icvfs_randomness*(dst: pointer; amount: cint): cint {.exportc, cdecl, raises: [].} =
  try: randomBytes(dst, amount) except: 0
proc nim_icvfs_current_time*(value: ptr cdouble): cint {.exportc, cdecl, raises: [].} =
  if value.isNil: return SqliteIoErr
  value[] = 2440587.5 + cdouble(vfsTimeNanoseconds()) / 86_400_000_000_000.0
  SqliteOk
proc nim_icvfs_last_error*(dst: pointer; amount: cint): cint {.exportc, cdecl, raises: [].} =
  if dst.isNil or amount <= 0: return SqliteOk
  let message = lastErrorMessage()
  let count = min(message.len, int(amount) - 1); if count > 0: copyMem(dst, unsafeAddr message[0], count)
  cast[ptr UncheckedArray[char]](dst)[count] = '\0'; SqliteOk
