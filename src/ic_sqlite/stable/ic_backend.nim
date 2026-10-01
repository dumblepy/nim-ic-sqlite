## IC stable64 syscall backend. Native builds deliberately do not emulate it;
## use VecStableBackend in unit tests instead.
import ./backend

when defined(wasm32):
  proc ic0Stable64Size(): uint64 {.importc: "ic0_stable64_size", cdecl, header: "ic0.h".}
  proc ic0Stable64Grow(pages: uint64): uint64 {.importc: "ic0_stable64_grow", cdecl, header: "ic0.h".}
  proc ic0Stable64Read(dst, offset, size: uint64) {.importc: "ic0_stable64_read", cdecl, header: "ic0.h".}
  proc ic0Stable64Write(offset, src, size: uint64) {.importc: "ic0_stable64_write", cdecl, header: "ic0.h".}

type IcStableBackend* = ref object of StableBackend

proc newIcStableBackend*(): IcStableBackend = IcStableBackend()

proc stableReadRaw*(dst: pointer; offset, size: uint64) =
  when defined(wasm32):
    if size > 0 and dst.isNil: raise newException(ValueError, "nil stable read destination")
    ic0Stable64Read(cast[uint64](dst), offset, size)
  else:
    raise newException(CatchableError, "IC stable memory is only available on wasm32")

proc stableWriteRaw*(offset: uint64; src: pointer; size: uint64) =
  when defined(wasm32):
    if size > 0 and src.isNil: raise newException(ValueError, "nil stable write source")
    ic0Stable64Write(offset, cast[uint64](src), size)
  else:
    raise newException(CatchableError, "IC stable memory is only available on wasm32")

method sizePages*(backend: IcStableBackend): uint64 =
  when defined(wasm32): ic0Stable64Size()
  else: raise newException(CatchableError, "IC stable memory is only available on wasm32")

method grow*(backend: IcStableBackend; pages: uint64): bool =
  when defined(wasm32): ic0Stable64Grow(pages) != high(uint64)
  else: raise newException(CatchableError, "IC stable memory is only available on wasm32")

method read*(backend: IcStableBackend; offset: uint64; dst: pointer; size: uint64) =
  stableReadRaw(dst, offset, size)

method write*(backend: IcStableBackend; offset: uint64; src: pointer; size: uint64) =
  stableWriteRaw(offset, src, size)
