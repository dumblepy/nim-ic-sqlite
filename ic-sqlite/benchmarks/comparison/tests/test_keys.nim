import std/unittest
import ../shared/bench_spec

proc asString(buffer: openArray[char]): string =
  result = newString(buffer.len)
  for index, value in buffer: result[index] = value

suite "comparison benchmark fixtures":
  test "Rust fixed-width key boundary fixtures match":
    check benchKey(0) == "k00000000"
    check benchKey(42) == "k00000042"
    check benchKey(9_999) == "k00009999"
    check benchKey(10_000) == "k00010000"
    check benchKey(99_999_999) == "k99999999"
    check churnKey(42) == "c00000042"

  test "value fixtures match the Rust benchmark":
    check benchValue(42) == "value-00000042-stable-vfs"
    check updatedValue(42) == "updated-00000042-stable-vfs"
    check growthValue(42) == "growth-00000042-stable-vfs"
    check writeValue(42) == "write-00000042"

  test "fixed buffers exactly match the established workload strings":
    for index in [0'u32, 42'u32, 99_999_999'u32]:
      check asString(benchKeyBuffer(index)) == benchKey(index)
      check asString(benchValueBuffer(index)) == benchValue(index)

  test "key limits prevent eight-digit truncation":
    check validateFixedBenchKeyRows(100_000_000)
    check not validateFixedBenchKeyRows(100_000_001)
    check validateFixedBenchKeyIndex(99_999_999)
    check not validateFixedBenchKeyIndex(100_000_000)
    check validateFixedBenchKeyRange(99_999_999, 1)
    check not validateFixedBenchKeyRange(99_999_999, 2)

  test "churn ranges are fixed and disjoint":
    check churnDeleteRange(0) == (0'u32, 1_000'u32)
    check churnInsertRange(0) == (5_000'u32, 1_000'u32)
    check churnDeleteRange(99) == (99_000'u32, 1_000'u32)
    check churnInsertRange(99) == (104_000'u32, 1_000'u32)
