import std/[json, unittest]
import ../runner/transport

suite "icp CLI transport":
  test "parses status counters with separators":
    check parseCliNat(%"70_992_848") == 70_992_848'u64
    check parseCliNat(%42) == 42'u64
