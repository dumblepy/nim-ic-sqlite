## Clean page cache A/B experiment (Nim only; requires the benchmarkProfile
## canister build). Usage:
##   NISQL_COMPARE_NIM_SHA=HEAD nim c -r runner/clean_cache_ab.nim
##
## Same canister, same stable image, same upsert workload; the only variable
## is the clean base-page cache size (0 = default/disabled, 2, 4, 8 pages).
## The Rust comparison canister is not involved: the clean cache does not
## have an equivalent public knob on that side.
import std/[json, os, osproc, strformat, strutils, times, algorithm]
import nicp_cdk/ic_types/ic_record except `%`, `%*`
import ./transport

const
  ComparisonDir = "/application/benchmarks/comparison"
  CanisterDir = ComparisonDir / "nim_canister"
  NimBackendDir = CanisterDir / "backend"
  NimWasm = NimBackendDir / "main.wasm"
  NimDid = NimBackendDir / "backend.did"
  SeedRows = 500'u32
  WorkloadRows = 100'u32
  WorkloadCycles = 20'u32
  Repeats = 3
  ReportFieldNames = [
    "rows", "writes", "instructions", "checksum", "clean_cache_pages",
    "dirty_pages_current", "dirty_pages_peak", "dirty_pages_new",
    "dirty_pages_new_bytes", "clean_cache_hits", "clean_cache_misses",
    "clean_cache_evictions", "clean_cache_bytes", "temp_buffer_allocs",
    "temp_buffer_alloc_bytes", "vfs_read_calls", "vfs_write_calls",
    "vfs_short_reads", "vfs_truncate_calls", "stable_read_calls",
    "stable_read_bytes", "stable_write_calls", "stable_write_bytes",
    "stable_grow_calls", "stable_grow_pages", "db_size",
    "sqlite_virtual_pages", "sqlite_page_count", "sqlite_cache_used_bytes",
    "raw_stable_pages", "raw_stable_bytes"]
  MeasuredFields = ["instructions", "clean_cache_hits", "clean_cache_misses",
    "clean_cache_evictions", "clean_cache_bytes", "stable_read_calls",
    "stable_read_bytes", "stable_write_calls", "stable_write_bytes",
    "dirty_pages_current", "dirty_pages_peak", "dirty_pages_new",
    "dirty_pages_new_bytes", "temp_buffer_allocs", "temp_buffer_alloc_bytes",
    "vfs_read_calls", "vfs_write_calls", "vfs_short_reads", "vfs_truncate_calls",
    "db_size", "sqlite_page_count", "sqlite_cache_used_bytes",
    "raw_stable_pages", "raw_stable_bytes", "heap_bytes"]

proc commandOutput(command: string): string =
  let (output, status) = execCmdEx(command)
  if status != 0: raise newException(OSError, command & ": " & output)
  output.strip()

proc sha256(path: string): string =
  commandOutput("sha256sum " & quoteShell(path)).splitWhitespace()[0]

func medianUnsorted(values: seq[uint64]): uint64 =
  if values.len == 0: return 0
  var sorted = values
  sorted.sort()
  if sorted.len mod 2 == 1: sorted[sorted.len div 2]
  else: (sorted[sorted.len div 2 - 1] + sorted[sorted.len div 2]) div 2

proc main() =
  ## Build the profile-instrumented Wasm; normal comparison builds never
  ## define benchmarkProfile, so this artifact is for measurement only.
  let previousDir = getCurrentDir()
  try:
    setCurrentDir(NimBackendDir)
    putEnv("NISQL_ENABLE_PROFILE", "1")
    defer: delEnv("NISQL_ENABLE_PROFILE")
    discard commandOutput("nicp productionBuild")
  finally:
    setCurrentDir(previousDir)
  let nimSha = commandOutput("git -C /application rev-parse HEAD")
  let dirtyTree = commandOutput("git -C /application status --porcelain")
  let nimWasmSha = sha256(NimWasm)

  let runId = "clean-cache-ab-" & now().utc.format("yyyyMMdd'T'HHmmss") & "Z"
  let resultDir = ComparisonDir / "results" / runId
  createDir(resultDir)

  let transport = CliTransport(projectDir: CanisterDir)
  try: transport.stopNetwork()
  except OSError: discard
  transport.startNetwork()
  defer: transport.stopNetwork()
  let canister = transport.createCanister()
  transport.install(canister, NimWasm)
  discard transport.call(canister, NimDid, "bench_reset", fmt"({SeedRows})")

  var jsonl = ""
  var variantSummary = newJArray()
  for variant in [0'u32, 2'u32, 4'u32, 8'u32]:
    discard transport.call(canister, NimDid, "bench_set_clean_cache", fmt"({variant})")
    var samples = newSeq[JsonNode]()
    for rep in 1 .. Repeats:
      let report = transport.call(canister, NimDid, "bench_clean_cache_write_profile",
        fmt"({WorkloadRows}, {WorkloadCycles})")
      let host = transport.call(canister, NimDid, "bench_host_stats", "()", query = true)
      let totalMemory = transport.canisterMemoryBytes(canister)
      let rawBytes = host["raw_stable_bytes"].getNat64()
      if totalMemory < rawBytes:
        raise newException(ValueError, "canister memory_size is below raw stable bytes")
      var row = newJObject()
      for name in ReportFieldNames:
        row[name] = newJInt(report[name].getNat64().int64)
      row["implementation"] = newJString("nim")
      row["run_id"] = newJString(runId)
      row["variant"] = newJInt(int64(variant))
      row["rep"] = newJInt(int64(rep))
      row["raw_stable_pages"] = newJInt(int64(host["raw_stable_pages"].getNat64()))
      row["raw_stable_bytes"] = newJInt(int64(rawBytes))
      row["host_memory_size_bytes"] = newJInt(int64(totalMemory))
      row["heap_bytes"] = newJInt(int64(totalMemory - rawBytes))
      samples.add(row)
      jsonl.add($row & "\n")
    var medianRow = newJObject()
    var rangeRow = newJObject()
    for field in MeasuredFields:
      var values = newSeq[uint64]()
      for row in samples:
        if row.hasKey(field):
          values.add(row[field].getBiggestInt().uint64)
      if values.len != Repeats:
        raise newException(ValueError,
          fmt"variant {variant}: field {field} measured {values.len}/{Repeats}")
      medianRow[field] = newJInt(int64(medianUnsorted(values)))
      rangeRow[field] = newJInt(int64(values.max - values.min))
    medianRow["variant"] = newJInt(int64(variant))
    rangeRow["variant"] = newJInt(int64(variant))
    variantSummary.add(%*{"median": medianRow, "range": rangeRow})
    echo fmt"variant cache_pages={variant} done"
  writeFile(resultDir / "clean_cache_ab.jsonl", jsonl)
  let manifest = %*{
    "run_kind": "clean_cache_ab",
    "run_id": runId,
    "repository": "dumblepy/nim-ic-sqlite",
    "nim_source_sha": nimSha,
    "nim_source_dirty": dirtyTree.len > 0,
    "nim_wasm_sha256": nimWasmSha,
    "benchmark_profile_build": true,
    "canister": canister,
    "seed_rows": int64(SeedRows),
    "workload_rows": int64(WorkloadRows),
    "workload_cycles": int64(WorkloadCycles),
    "repeats": int64(Repeats),
    "variants": %*[0, 2, 4, 8],
    "variants_summary": variantSummary,
    "notes": [
      "Nim-only experiment; the clean base-page cache has no Rust-side equivalent knob.",
      "heap_bytes = canister status memory_size minus raw stable bytes (linear-memory high-water observation, never live heap).",
      "sqlite_cache_used_bytes is the SQLite pager cache; never summed into raw stable or heap totals.",
      "raw_stable_bytes is physical stable memory via ic0_stable64_size.",
      "All variants measured on the same canister after one fresh install; re-init preserves stable data."
    ]
  }
  writeFile(resultDir / "manifest.json", manifest.pretty())
  echo resultDir

when isMainModule: main()
