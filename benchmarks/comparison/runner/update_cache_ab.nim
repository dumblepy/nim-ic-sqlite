## Update statement-cache A/B experiment (PR-6, Nim only; requires the
## benchmarkProfile canister build). Usage:
##   NISQL_COMPARE_NIM_SHA=HEAD NISQL_ENABLE_UPDATE_CACHE=0 nim c -r runner/update_cache_ab.nim
##   NISQL_COMPARE_NIM_SHA=HEAD NISQL_ENABLE_UPDATE_CACHE=1 nim c -r runner/update_cache_ab.nim
##
## Each run builds the canister with the update statement cache off or on and
## runs the same 20-transaction upsert workload (each transaction prepares the
## same SQL). The two result directories are compared by instructions. The Rust
## comparison canister is not involved.
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
  MeasuredFields = ["instructions", "dirty_pages_new", "dirty_pages_peak",
    "vfs_read_calls", "vfs_write_calls", "stable_read_calls", "stable_write_calls",
    "db_size", "sqlite_page_count", "sqlite_cache_used_bytes", "heap_bytes"]

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
  let cacheEnabled = getEnv("NISQL_ENABLE_UPDATE_CACHE", "0") == "1"
  let previousDir = getCurrentDir()
  try:
    setCurrentDir(NimBackendDir)
    putEnv("NISQL_ENABLE_PROFILE", "1")
    putEnv("NISQL_ENABLE_UPDATE_CACHE", if cacheEnabled: "1" else: "0")
    defer:
      delEnv("NISQL_ENABLE_PROFILE")
      delEnv("NISQL_ENABLE_UPDATE_CACHE")
    discard commandOutput("nicp productionBuild")
  finally:
    setCurrentDir(previousDir)
  let nimSha = commandOutput("git -C /application rev-parse HEAD")
  let dirtyTree = commandOutput("git -C /application status --porcelain")
  let nimWasmSha = sha256(NimWasm)

  let runId = "update-cache-ab-" & now().utc.format("yyyyMMdd'T'HHmmss") & "Z"
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
    for name in MeasuredFields:
      if name == "heap_bytes":
        row[name] = newJInt(int64(totalMemory - rawBytes))
      else:
        row[name] = newJInt(report[name].getNat64().int64)
    row["statement_cache"] = newJBool(cacheEnabled)
    row["rep"] = newJInt(int64(rep))
    row["run_id"] = newJString(runId)
    samples.add(row)
    jsonl.add($row & "\n")
  var medianRow = newJObject()
  for field in MeasuredFields:
    var values = newSeq[uint64]()
    for row in samples:
      values.add(row[field].getBiggestInt().uint64)
    medianRow[field] = newJInt(int64(medianUnsorted(values)))
  medianRow["statement_cache"] = newJBool(cacheEnabled)
  writeFile(resultDir / "update_cache_ab.jsonl", jsonl)
  let manifest = %*{
    "run_kind": "update_cache_ab",
    "run_id": runId,
    "repository": "dumblepy/nim-ic-sqlite",
    "nim_source_sha": nimSha,
    "nim_source_dirty": dirtyTree.len > 0,
    "nim_wasm_sha256": nimWasmSha,
    "benchmark_profile_build": true,
    "statement_cache_enabled": cacheEnabled,
    "canister": canister,
    "seed_rows": int64(SeedRows),
    "workload_rows": int64(WorkloadRows),
    "workload_cycles": int64(WorkloadCycles),
    "repeats": int64(Repeats),
    "median": medianRow,
    "notes": [
      "Nim-only experiment; statementCacheEnabled has no Rust-side equivalent knob.",
      "Each transaction prepares the same upsert SQL, so the cache removes repeated prepare work.",
      "heap_bytes = canister status memory_size minus raw stable bytes (never live heap)."
    ]
  }
  writeFile(resultDir / "manifest.json", manifest.pretty())
  echo resultDir

when isMainModule: main()