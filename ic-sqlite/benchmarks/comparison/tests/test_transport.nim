import std/[json, unittest]
import ../runner/transport

suite "icp CLI transport":
  test "parses status counters with separators":
    check parseCliNat(%"70_992_848") == 70_992_848'u64
    check parseCliNat(%42) == 42'u64

  test "extracts management status cycle balances":
    let status = parseJson("{\"cycles\":\"1_499_998_476_000\",\"reserved_cycles\":\"0\"}")
    check status.canisterCycles() == 1_499_998_476_000'u64
    check status.canisterReservedCycles() == 0'u64
