## Read connection / statement cache experiment (Nim only). Usage:
##   NISQL_COMPARE_NIM_SHA=HEAD nim c -r runner/query_reuse_ab.nim
##
## Same canister, same stable image, same public read workload (bench_read).
## The only variable is the optional query-connection reuse and the
## statement cache bound to it.  Both are disabled by default; the cached
## reader is invalidated before every update by the library.
import std/[algorithm, json, os, osproc, strformat, strutils, times]
import nicp_cdk/ic_types/ic_record except `%`, `%*`
import ./transport

const
  ComparisonDir = "/application/benchmarks/comparison"
  CanisterDir = ComparisonDir / "nim_canister"
  NimBackendDir = CanisterDir / "backend"
  NimWasm = NimBackendDir / "main.wasm"
  NimDid = NimBackendDir / "backend.did"
  SeedRows = 500'u32
  ReadRows = 100'u32
  Repeats = 3

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
  ## The experiment endpoints compile into the regular production Wasm;
  ## benchmarkProfile is not required here.
  let previousDir = getCurrentDir()
  try:
    setCurrentDir(NimBackendDir)
    discard commandOutput("nicp productionBuild")
  finally:
    setCurrentDir(previousDir)
  let nimSha = commandOutput("git -C /application rev-parse HEAD")
  let dirtyTree = commandOutput("git -C /application status --porcelain")
  let nimWasmSha = sha256(NimWasm)

  let runId = "query-reuse-ab-" & now().utc.format("yyyyMMdd'T'HHmmss") & "Z"
  let resultDir = ComparisonDir / "results" / runId
  createDir(resultDir)

  let transport = CliTransport(projectDir: CanisterDir)
  try: transport.stopNetwork()
  except OSError: discard
  transport.startNetwork()
  defer: transport.stopNetwork()
  let canister = transport.createCanister()
  transport.install(canister, NimWasm)
  discard transport.call(canister, NimDid, "bench_reset", $(SeedRows))

  ## (reuse, stmtCache) variants; (0,0) is the shipped default.
  var jsonl = ""
  var variantSummary = newJArray()
  var variants: seq[(string, uint32, uint32)] = @[]
  variants.add (("off", 0'u32, 0'u32))
  variants.add (("query_reuse", 1'u32, 0'u32))
  variants.add (("statement_cache", 0'u32, 1'u32))
  variants.add (("query_reuse_and_stmt_cache", 1'u32, 1'u32))
  for (variantName, reuse, stmtCache) in variants:
    discard transport.call(canister, NimDid, "bench_set_experiment",
      fmt"({reuse}, {stmtCache})")
    var samples = newSeq[uint64]()
    for rep in 1 .. Repeats:
      let report = transport.call(canister, NimDid, "bench_read", $(ReadRows), query = true)
      let host = transport.call(canister, NimDid, "bench_host_stats", "()", query = true)
      let stats = transport.call(canister, NimDid, "db_stats", "()", query = true)
      let totalMemory = transport.canisterMemoryBytes(canister)
      let rawBytes = host["raw_stable_bytes"].getNat64()
      if totalMemory < rawBytes:
        raise newException(ValueError, "canister memory_size is below raw stable bytes")
      samples.add(report["instructions"].getNat64())
      var row = newJObject()
      row["implementation"] = newJString("nim")
      row["run_id"] = newJString(runId)
      row["variant"] = newJString($variantName)
      row["query_reuse"] = newJInt(int64(reuse))
      row["statement_cache"] = newJInt(int64(stmtCache))
      row["rep"] = newJInt(int64(rep))
      row["rows"] = newJInt(int64(ReadRows))
      row["instructions"] = newJInt(int64(report["instructions"].getNat64()))
      row["checksum"] = newJInt(int64(report["checksum"].getNat64()))
      row["db_size"] = newJInt(int64(report["db_size"].getNat64()))
      row["sqlite_cache_used_bytes"] = newJInt(int64(stats["sqlite_cache_used_bytes"].getNat64()))
      row["raw_stable_pages"] = newJInt(int64(host["raw_stable_pages"].getNat64()))
      row["raw_stable_bytes"] = newJInt(int64(rawBytes))
      row["host_memory_size_bytes"] = newJInt(int64(totalMemory))
      row["heap_bytes"] = newJInt(int64(totalMemory - rawBytes))
      jsonl.add($row & "\n")
    let median = medianUnsorted(samples)
    variantSummary.add(%*{
      "variant": $variantName,
      "instructions_median": int64(median),
      "instructions_range": int64(samples.max - samples.min)
    })
    echo fmt"variant {variantName} median={median}"
  writeFile(resultDir / "query_reuse_ab.jsonl", jsonl)
  let manifest = %*{
    "run_kind": "query_reuse_ab",
    "run_id": runId,
    "repository": "dumblepy/nim-ic-sqlite",
    "nim_source_sha": nimSha,
    "nim_source_dirty": dirtyTree.len > 0,
    "nim_wasm_sha256": nimWasmSha,
    "canister": canister,
    "seed_rows": int64(SeedRows),
    "read_rows": int64(ReadRows),
    "repeats": int64(Repeats),
    "variants_summary": variantSummary,
    "notes": [
      "Nim-only experiment; Rust reader reuse has a different lifecycle and is not comparable here.",
      "Workload is the public bench_read endpoint (open-per-query vs reused connection).",
      "The cached reader is invalidated by the library before every update; close() finalizes statements.",
      "sqlite_cache_used_bytes is the SQLite pager cache; heap_bytes = status memory_size - raw stable bytes (high-water, not live heap).",
      "Instructions from query endpoints are descriptive; they are not instruction-only cost estimates."
    ]
  }
  writeFile(resultDir / "manifest.json", manifest.pretty())
  echo resultDir

when isMainModule: main()
