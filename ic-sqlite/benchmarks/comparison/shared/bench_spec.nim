## Deterministic workload inputs shared by the Nim benchmark canister and host runner.

const
  MaxFixedBenchKeyRows* = 100_000_000'u32
  SqlitePageSize* = 16_384'u32
  StablePageSize* = 65_536'u64
  BenchSchemaSql* = "CREATE TABLE bench (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID"
  ChurnSchemaSql* = "CREATE TABLE churn_bench (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID"
  CommonPragmasSql* = "PRAGMA page_size=16384; PRAGMA journal_mode=MEMORY; PRAGMA synchronous=OFF; PRAGMA temp_store=MEMORY; PRAGMA locking_mode=EXCLUSIVE; PRAGMA cache_size=-32768; PRAGMA auto_vacuum=NONE;"

proc validateFixedBenchKeyIndex*(index: uint32): bool {.inline.} =
  index < MaxFixedBenchKeyRows

proc validateFixedBenchKeyRows*(rows: uint32): bool {.inline.} =
  rows <= MaxFixedBenchKeyRows

proc validateFixedBenchKeyRange*(start, count: uint32): bool {.inline.} =
  ## The exclusive endpoint is permitted because it does not name a key.
  let endIndex = uint64(start) + uint64(count)
  endIndex <= uint64(MaxFixedBenchKeyRows)

proc fixedIndex(index: uint32): string =
  if not validateFixedBenchKeyIndex(index):
    raise newException(ValueError, "benchmark key index must be less than 100000000")
  result = newString(8)
  var value = index
  for position in countdown(7, 0):
    result[position] = char(ord('0') + int(value mod 10))
    value = value div 10

proc prefixedKey*(prefix: char; index: uint32): string =
  result = $prefix & fixedIndex(index)

proc benchKey*(index: uint32): string = prefixedKey('k', index)
proc churnKey*(index: uint32): string = prefixedKey('c', index)
proc benchValue*(index: uint32): string = "value-" & fixedIndex(index) & "-stable-vfs"
proc updatedValue*(index: uint32): string = "updated-" & fixedIndex(index) & "-stable-vfs"
proc growthValue*(index: uint32): string = "growth-" & fixedIndex(index) & "-stable-vfs"
proc writeValue*(index: uint32): string = "write-" & fixedIndex(index)

proc fixedIndexInto(index: uint32; dst: var array[8, char]) =
  if not validateFixedBenchKeyIndex(index):
    raise newException(ValueError, "benchmark key index must be less than 100000000")
  var value = index
  for position in countdown(7, 0):
    dst[position] = char(ord('0') + int(value mod 10))
    value = value div 10

proc benchKeyBuffer*(index: uint32): array[9, char] =
  ## Allocation-free counterpart of `benchKey`; intended for core/VFS probes.
  result[0] = 'k'
  var digits: array[8, char]
  fixedIndexInto(index, digits)
  for position in 0 ..< digits.len: result[position + 1] = digits[position]

proc benchValueBuffer*(index: uint32): array[25, char] =
  ## Allocation-free counterpart of `benchValue`; this is deliberately an
  ## internal benchmark input, not a public SQLite binding API.
  const Prefix = "value-"
  const Suffix = "-stable-vfs"
  for position in 0 ..< Prefix.len: result[position] = Prefix[position]
  var digits: array[8, char]
  fixedIndexInto(index, digits)
  for position in 0 ..< digits.len: result[Prefix.len + position] = digits[position]
  for position in 0 ..< Suffix.len:
    result[Prefix.len + digits.len + position] = Suffix[position]

proc churnDeleteRange*(cycle: uint32): tuple[start, count: uint32] =
  if cycle >= 100'u32:
    raise newException(ValueError, "churn cycle must be less than 100")
  (cycle * 1_000'u32, 1_000'u32)

proc churnInsertRange*(cycle: uint32): tuple[start, count: uint32] =
  if cycle >= 100'u32:
    raise newException(ValueError, "churn cycle must be less than 100")
  (5_000'u32 + cycle * 1_000'u32, 1_000'u32)
