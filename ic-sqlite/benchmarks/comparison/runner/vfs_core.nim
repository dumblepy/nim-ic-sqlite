## VFS/core comparison runner. Runs the isolated VFS/core profile endpoint
## (allocation-free fixed-length buffers, known prepare/step/reset counts)
## on a fresh Nim canister. No Rust comparison: the VFS/core counters are
## Nim-specific and have no equivalent public knob on the Rust side.
##
## Usage:
##   nim c -r runner/vfs_core.nim [rows=1000]
##
## The workload manifest records SQL, transaction count, prepare/step/reset
## counts, and input lengths so the comparison is reproducible.
import std/[json, os, options, osproc, strformat, strutils, times]
import nicp_cdk/ic_types/candid_types
import nicp_cdk/ic_types/ic_record except `%`, `%*`
import ../shared/bench_spec
import ./transport

const
  ComparisonDir = "/application/ic-sqlite/benchmarks/comparison"
  CanisterDir = ComparisonDir / "nim_canister"
  NimBackendDir = CanisterDir / "backend"
  NimWasm = NimBackendDir / "main.wasm"
  NimDid = NimBackendDir / "backend.did"

  VfsCoreSql = "INSERT INTO bench(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
  VfsCoreReadSql = "SELECT value FROM bench WHERE key = ?"

type
  VfsCoreManifest = object
    run_id, nim_sha, wasm_sha256, source_sha256, db_source_sha256: string
    source_dirty: bool
    rows: uint32
    sql: string
    read_sql: string
    transaction_count: uint32
    prepare_count: uint32
    step_count: uint32
    reset_count: uint32
    key_length: uint32
    value_length: uint32
    toolchains: JsonNode
    notes: seq[string]

proc commandOutput(command: string): string =
  let (output, status) = execCmdEx(command)
  if status != 0: raise newException(OSError, command & ": " & output)
  output.strip()

proc sha256(path: string): string =
  commandOutput("sha256sum " & quoteShell(path)).splitWhitespace()[0]

proc main() =
  let rows = if paramCount() == 0: 1000'u32 else: parseInt(paramStr(1)).uint32
  if rows == 0 or rows > 10_000'u32:
    raise newException(ValueError, "rows must be 1..10000")

  let useDirtySeq = getEnv("NISQL_ENABLE_DIRTY_SEQ", "0") == "1"
  ## Profile-instrumented build; the dirty store variant is selected by env so
  ## C0 and C1 can be measured as separate Wasm artifacts.
  block:
    let previousDir = getCurrentDir()
    try:
      setCurrentDir(NimBackendDir)
      putEnv("NISQL_ENABLE_PROFILE", "1")
      putEnv("NISQL_ENABLE_DIRTY_SEQ", if useDirtySeq: "1" else: "0")
      discard commandOutput("nicp productionBuild")
    finally:
      setCurrentDir(previousDir)
      delEnv("NISQL_ENABLE_PROFILE")
      delEnv("NISQL_ENABLE_DIRTY_SEQ")
  let nimSha = commandOutput("git -C /application/ic-sqlite rev-parse HEAD")
  let dirtyTree = commandOutput("git -C /application/ic-sqlite status --porcelain")
  let nimWasmSha = sha256(NimWasm)
  let sourceSha = sha256(NimBackendDir / "src/main.nim")
  let dbSourceSha = sha256("/application/ic-sqlite/src/ic_sqlite/db.nim")

  let runId = "vfs-core-" & now().utc.format("yyyyMMdd'T'HHmmss") & "Z"
  let resultDir = ComparisonDir / "results" / runId
  createDir(resultDir)

  let transport = CliTransport(projectDir: CanisterDir)
  try: transport.stopNetwork()
  except OSError: discard
  transport.startNetwork()
  defer: transport.stopNetwork()
  let canister = transport.createCanister()
  transport.install(canister, NimWasm)

  ## Seed rows so the upsert has existing data to update.
  discard transport.call(canister, NimDid, "bench_reset", fmt"({rows})")

  ## Run the VFS/core profile.
  let response = transport.call(canister, NimDid, "bench_vfs_core_profile", fmt"({rows})")
  let host = transport.call(canister, NimDid, "bench_host_stats", "()", query = true)
  let totalMemory = transport.canisterMemoryBytes(canister)
  let rawBytes = host["raw_stable_bytes"].getNat64()
  let heapBytes = if totalMemory >= rawBytes: some(totalMemory - rawBytes) else: none(uint64)

  ## Build the workload manifest.
  var manifest = newJObject()
  manifest["run_id"] = %runId
  manifest["run_kind"] = %"vfs_core_comparison"
  manifest["nim_sha"] = %nimSha
  manifest["wasm_sha256"] = %nimWasmSha
  manifest["source_sha256"] = %sourceSha
  manifest["db_source_sha256"] = %dbSourceSha
  manifest["source_dirty"] = %(dirtyTree.len > 0)
  manifest["dirty_seq"] = %useDirtySeq
  manifest["rows"] = %rows
  manifest["sql"] = %VfsCoreSql
  manifest["read_sql"] = %VfsCoreReadSql
  manifest["transaction_count"] = %1
  manifest["prepare_count"] = %2  # one upsert + one read-back
  manifest["step_count"] = %(rows * 2)  # upsert rows + read-back rows
  manifest["reset_count"] = %(rows * 2)  # upsert rows + read-back rows
  manifest["key_length"] = %9   # benchKeyBuffer = array[9, char]
  manifest["value_length"] = %27  # updatedValueBuffer = array[27, char]
  manifest["toolchains"] = %*{
    "nim": commandOutput("nim --version").splitLines()[0],
    "icp_cli": commandOutput("icp --version"),
    "wasi_sdk": commandOutput(quoteShell(getEnv("WASI_SDK_PATH")) / "bin/clang" & " --version").splitLines()[0]
  }
  manifest["notes"] = %[
    "VFS/core comparison: allocation-free fixed-length key/value buffers, known prepare/step/reset counts.",
    "Single transaction, one upsert prepared statement, one read-back prepared statement.",
    "Nim-only: the VFS/core profile counters have no equivalent public knob on the Rust side.",
    "heap_bytes is derived from canister status memory_size minus raw stable bytes."
  ]
  writeFile(resultDir / "manifest.json", manifest.pretty())

  ## Write the measurement.
  var measurement = newJObject()
  measurement["run_id"] = %runId
  measurement["rows"] = %rows
  for (jsonName, candidName) in [
      ("instructions", "instructions"), ("checksum", "checksum"),
      ("db_size", "db_size"), ("sqlite_virtual_pages", "sqlite_virtual_pages"),
      ("sqlite_page_count", "sqlite_page_count"),
      ("sqlite_cache_used_bytes", "sqlite_cache_used_bytes"),
      ("clean_cache_pages", "clean_cache_pages"),
      ("dirty_pages_current", "dirty_pages_current"),
      ("dirty_pages_peak", "dirty_pages_peak"),
      ("dirty_pages_new", "dirty_pages_new"),
      ("dirty_pages_new_bytes", "dirty_pages_new_bytes"),
      ("clean_cache_hits", "clean_cache_hits"),
      ("clean_cache_misses", "clean_cache_misses"),
      ("clean_cache_evictions", "clean_cache_evictions"),
      ("clean_cache_bytes", "clean_cache_bytes"),
      ("temp_buffer_allocs", "temp_buffer_allocs"),
      ("temp_buffer_alloc_bytes", "temp_buffer_alloc_bytes"),
      ("vfs_read_calls", "vfs_read_calls"),
      ("vfs_write_calls", "vfs_write_calls"),
      ("vfs_short_reads", "vfs_short_reads"),
      ("vfs_truncate_calls", "vfs_truncate_calls"),
      ("stable_read_calls", "stable_read_calls"),
      ("stable_read_bytes", "stable_read_bytes"),
      ("stable_write_calls", "stable_write_calls"),
      ("stable_write_bytes", "stable_write_bytes"),
      ("stable_grow_calls", "stable_grow_calls"),
      ("stable_grow_pages", "stable_grow_pages"),
      ("raw_stable_pages", "raw_stable_pages"),
      ("raw_stable_bytes", "raw_stable_bytes")]:
    measurement[jsonName] = %response[candidName].getNat64()
  if heapBytes.isSome:
    measurement["heap_bytes"] = %(heapBytes.get())
  else:
    measurement["heap_bytes"] = newJNull()
  writeFile(resultDir / "measurement.json", measurement.pretty())

  ## Write a human-readable summary.
  writeFile(resultDir / "summary.md", fmt"""# {runId}

## VFS/core comparison: {rows} rows

| Metric | Value |
|---|---|
| Instructions | {measurement["instructions"].getBiggestInt()} |
| Checksum | {measurement["checksum"].getBiggestInt()} |
| DB size | {measurement["db_size"].getBiggestInt()} |
| SQLite virtual pages | {measurement["sqlite_virtual_pages"].getBiggestInt()} |
| SQLite page count | {measurement["sqlite_page_count"].getBiggestInt()} |
| SQLite cache used bytes | {measurement["sqlite_cache_used_bytes"].getBiggestInt()} |
| Dirty pages (current) | {measurement["dirty_pages_current"].getBiggestInt()} |
| Dirty pages (peak) | {measurement["dirty_pages_peak"].getBiggestInt()} |
| Dirty pages (new) | {measurement["dirty_pages_new"].getBiggestInt()} |
| Dirty pages new bytes | {measurement["dirty_pages_new_bytes"].getBiggestInt()} |
| Clean cache hits | {measurement["clean_cache_hits"].getBiggestInt()} |
| Clean cache misses | {measurement["clean_cache_misses"].getBiggestInt()} |
| Clean cache evictions | {measurement["clean_cache_evictions"].getBiggestInt()} |
| Clean cache bytes | {measurement["clean_cache_bytes"].getBiggestInt()} |
| Temp buffer allocs | {measurement["temp_buffer_allocs"].getBiggestInt()} |
| Temp buffer alloc bytes | {measurement["temp_buffer_alloc_bytes"].getBiggestInt()} |
| VFS read calls | {measurement["vfs_read_calls"].getBiggestInt()} |
| VFS write calls | {measurement["vfs_write_calls"].getBiggestInt()} |
| VFS short reads | {measurement["vfs_short_reads"].getBiggestInt()} |
| VFS truncate calls | {measurement["vfs_truncate_calls"].getBiggestInt()} |
| Stable read calls | {measurement["stable_read_calls"].getBiggestInt()} |
| Stable read bytes | {measurement["stable_read_bytes"].getBiggestInt()} |
| Stable write calls | {measurement["stable_write_calls"].getBiggestInt()} |
| Stable write bytes | {measurement["stable_write_bytes"].getBiggestInt()} |
| Stable grow calls | {measurement["stable_grow_calls"].getBiggestInt()} |
| Stable grow pages | {measurement["stable_grow_pages"].getBiggestInt()} |
| Raw stable pages | {measurement["raw_stable_pages"].getBiggestInt()} |
| Raw stable bytes | {measurement["raw_stable_bytes"].getBiggestInt()} |
| Heap bytes | {heapBytes.get(0)} |

## Workload manifest

- SQL: `{VfsCoreSql}`
- Read-back SQL: `{VfsCoreReadSql}`
- Transactions: 1
- Prepare count: 2 (one upsert + one read-back)
- Step count: {rows * 2}
- Reset count: {rows * 2}
- Key length: 9 bytes
- Value length: 27 bytes
""")
  echo resultDir

when isMainModule: main()