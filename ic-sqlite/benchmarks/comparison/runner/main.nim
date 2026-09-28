## Usage: ./prepare_rust.sh && nim c -r runner/main.nim [trial-count]
## A trial installs both benchmark Wasm files into fresh canisters on one subnet.
import std/[algorithm, json, options, os, osproc, strformat, strutils, times]
import nicp_cdk/ic_types/candid_types
import nicp_cdk/ic_types/ic_record except `%`, `%*`
import ../shared/[bench_report, bench_spec]
import ./transport

const
  ComparisonDir = "/application/ic-sqlite/benchmarks/comparison"
  CanisterDir = ComparisonDir / "nim_canister"
  NimBackendDir = CanisterDir / "backend"
  NimWasm = NimBackendDir / "main.wasm"
  NimDid = NimBackendDir / "backend.did"
  RustRepo = ComparisonDir / ".cache/ic-sqlite-vfs"
  RustWasm = RustRepo / "benchmarks/kv-canister/target/wasm32-unknown-unknown/release/ic_sqlite_vfs_kv_bench.wasm"
  RustDid = RustRepo / "benchmarks/kv-canister/kv_bench.did"
  ExpectedRustSha = "1386239acff1dd7ede5ac78a2f0a22ef495195de"
  ExpectedNimSha = "4735f04908ae9a7ac30bac6d05aa7aaa1e0da260"

proc shellOutput(command: string): string =
  let (output, status) = execCmdEx(command)
  if status != 0: raise newException(OSError, command & ": " & output)
  output.strip()

proc sha256(path: string): string =
  shellOutput("sha256sum " & quoteShell(path)).splitWhitespace()[0]

proc assertValue(record: CandidRecord; name: string; expected: uint64) =
  let actual = record[name].getNat64()
  if actual != expected:
    raise newException(ValueError, fmt"{name}: expected {expected}, got {actual}")

proc median(values: seq[uint64]): float64 =
  var sorted = values
  sorted.sort()
  if sorted.len == 0: return 0
  if sorted.len mod 2 == 1: float64(sorted[sorted.len div 2])
  else: (float64(sorted[sorted.len div 2 - 1]) + float64(sorted[sorted.len div 2])) / 2

proc measure(transport: CliTransport; runId, implementation, repoSha, wasmSha,
             canister, didPath, phase: string; trial, rows: uint32;
             baselineRaw: Option[uint64]): Measurement =
  let query = phase == "read"
  let response = transport.call(canister, didPath,
    if phase == "reset": "bench_reset"
    elif phase == "read": "bench_read"
    else: "bench_update_only", fmt"({rows})", query = query)
  response.assertValue("rows", uint64(rows))
  response.assertValue("checksum", if phase == "read":
    uint64(rows) * uint64(benchValue(0).len) else: uint64(rows))
  let stats = transport.call(canister, didPath, "db_stats", "()", query = true)
  result = Measurement(runId: runId, implementation: implementation,
    repoSha: repoSha, wasmSha256: wasmSha, scenario: "core_kv", phase: phase,
    trial: trial, rows: rows, success: true, instructionWindow: if query: iwQuery else: iwCore,
    dbSize: response["db_size"].getNat64(),
    sqliteVirtualPages: response["stable_pages"].getNat64(),
    sqlitePageSize: stats["sqlite_page_size"].getNat64(),
    sqlitePageCount: stats["sqlite_page_count"].getNat64(),
    sqliteFreelistCount: stats["sqlite_freelist_count"].getNat64(),
    valueChecksum: response["checksum"].getNat64(), rowCount: uint64(rows))
  let instructions = response["instructions"].getNat64()
  if query: result.instructionsQuery = some(instructions)
  else: result.instructionsUpdate = some(instructions)
  let host = transport.call(canister, didPath, "bench_host_stats", "()", query = true)
  let rawPages = host["raw_stable_pages"].getNat64()
  result.rawStablePages = some(rawPages)
  let rawBytes = host["raw_stable_bytes"].getNat64()
  result.rawStableBytes = some(rawBytes)
  let totalMemory = transport.canisterMemoryBytes(canister)
  if totalMemory < rawBytes:
    raise newException(ValueError, "canister status memory_size is smaller than raw stable memory")
  result.heapBytes = some(totalMemory - rawBytes)
  if baselineRaw.isSome: result.rawGrowthPages = some(rawGrowthPages(baselineRaw.get(), rawPages))

proc main() =
  let trialCount = if paramCount() == 0: 5 else: parseInt(paramStr(1))
  if trialCount < 1: raise newException(ValueError, "trial count must be positive")
  if not fileExists(RustWasm) or not fileExists(RustDid):
    raise newException(OSError, "run benchmarks/comparison/prepare_rust.sh first")
  let rustSha = shellOutput("git -C " & quoteShell(RustRepo) & " rev-parse HEAD")
  let nimSha = shellOutput("git -C /application/ic-sqlite rev-parse HEAD")
  if rustSha != ExpectedRustSha or nimSha != ExpectedNimSha:
    raise newException(ValueError, "source SHA differs from pinned comparison manifest")
  ## Rust uses Cargo's release profile; use the matching optimized Nim Wasm.
  discard shellOutput("cd " & quoteShell(NimBackendDir) & " && nicp productionBuild")
  let nimWasmSha = sha256(NimWasm)
  let rustWasmSha = sha256(RustWasm)
  let rustPatchSha = sha256(ComparisonDir / "rust_host_stats.patch")
  let runId = now().utc.format("yyyyMMdd'T'HHmmss") & "Z"
  let resultDir = ComparisonDir / "results" / runId
  createDir(resultDir)
  var manifest = parseFile(ComparisonDir / "bench_manifest.json")
  manifest["run_kind"] = %"local_comparison"
  manifest["run_id"] = %runId
  manifest["toolchains"]["icp_cli"] = %shellOutput("icp --version")
  manifest["toolchains"]["rustc"] = %shellOutput("rustc --version")
  manifest["toolchains"]["nim"] = %shellOutput("nim --version").splitLines()[0]
  manifest["toolchains"]["wasi_sdk"] = %shellOutput(quoteShell(getEnv("WASI_SDK_PATH") / "bin/clang") & " --version").splitLines()[0]
  manifest["toolchains"]["pocket_ic"] = %"not_used"
  manifest["subnet"]["kind"] = %"icp_cli_local_managed"
  manifest["subnet"]["node_count"] = %"not_exposed_by_icp_cli"
  manifest["subnet"]["initial_cycles"] = %"2000000000000"
  manifest["artifacts"]["nim_wasm_sha256"] = %nimWasmSha
  manifest["artifacts"]["rust_wasm_sha256"] = %rustWasmSha
  manifest["artifacts"]["rust_host_stats_patch_sha256"] = %rustPatchSha
  manifest["artifacts"]["nim_benchmark_source_sha256"] = %sha256(NimBackendDir / "src/main.nim")
  manifest["artifacts"]["nim_db_source_sha256"] = %sha256("/application/ic-sqlite/src/ic_sqlite/db.nim")
  manifest["artifacts"]["nicp_candid_types_source_sha256"] = %sha256("/application/nicp_cdk/src/nicp_cdk/ic_types/candid_types.nim")
  manifest["nim_source_dirty"] = %(
    shellOutput("git -C /application/ic-sqlite status --porcelain").len > 0)
  manifest["trials"] = %trialCount
  manifest["rows_per_trial"] = %100'u32
  manifest["trial_baselines"] = newJArray()
  manifest["notes"] = %["Both implementations use fresh canisters on the same local subnet per trial.",
    "Rust source is pinned plus rust_host_stats.patch; both physical page counts use ic0 stable64_size.",
    "heap_bytes is derived from canister status memory_size minus raw stable bytes; it is a local status observation.",
    "Nim and nicp_cdk working trees are dirty; source file hashes identify the measured build.",
    "Query instructions are measured separately and are not cycles estimates."]
  writeFile(resultDir / "manifest.json", manifest.pretty())

  let transport = CliTransport(projectDir: CanisterDir)
  try: transport.stopNetwork()
  except OSError: discard
  transport.startNetwork()
  defer: transport.stopNetwork()
  var csv = MeasurementCsvHeader & "\n"
  var jsonl = ""
  var nimUpdate = newSeq[uint64]()
  var rustUpdate = newSeq[uint64]()
  for trial in 1 .. trialCount:
    let nimCanister = transport.createCanister()
    let rustCanister = transport.createCanister()
    transport.install(nimCanister, NimWasm)
    transport.install(rustCanister, RustWasm)
    let nimRaw = transport.call(nimCanister, NimDid, "bench_host_stats", "()", query = true)
    let rustRaw = transport.call(rustCanister, RustDid, "bench_host_stats", "()", query = true)
    let nimBaseline = some(nimRaw["raw_stable_pages"].getNat64())
    let rustBaseline = some(rustRaw["raw_stable_pages"].getNat64())
    manifest["trial_baselines"].add(%*{
      "trial": trial,
      "nim_canister": nimCanister,
      "rust_canister": rustCanister,
      "nim_raw_stable_pages": nimBaseline.get(),
      "rust_raw_stable_pages": rustBaseline.get()
    })
    writeFile(resultDir / "manifest.json", manifest.pretty())
    for phase in ["reset", "read", "update"]:
      for implementation in ["nim", "rust"]:
        let measurement = measure(transport, runId, implementation,
          if implementation == "nim": nimSha else: rustSha,
          if implementation == "nim": nimWasmSha else: rustWasmSha,
          if implementation == "nim": nimCanister else: rustCanister,
          if implementation == "nim": NimDid else: RustDid,
          phase, uint32(trial), 100'u32,
          if implementation == "nim": nimBaseline else: rustBaseline)
        csv.add(measurement.toCsvRow() & "\n")
        jsonl.add($measurement.toJson() & "\n")
        if phase == "update":
          if implementation == "nim": nimUpdate.add(measurement.instructionsUpdate.get())
          else: rustUpdate.add(measurement.instructionsUpdate.get())
    writeFile(resultDir / "measurements.csv", csv)
    writeFile(resultDir / "measurements.jsonl", jsonl)
    echo fmt"trial {trial}/{trialCount} complete"
  let nimMedian = median(nimUpdate)
  let rustMedian = median(rustUpdate)
  writeFile(resultDir / "summary.md", fmt"# {runId}" & "\n\n" &
    fmt"Core KV workload: 100 rows, {trialCount} fresh Nim/Rust canister pairs." & "\n\n" &
    "| Update instruction median | Count |\n|---|---:|\n" &
    fmt"| Nim | {nimMedian} |" & "\n" & fmt"| Rust | {rustMedian} |" & "\n" &
    fmt"| Nim / Rust | {nimMedian / rustMedian} |" & "\n\n" &
    "Raw values, SQLite virtual pages, and physical stable pages are in " &
    "measurements.csv and measurements.jsonl. " &
    "Query instruction counts use different connection warmup paths and are descriptive only. " &
    "heap_bytes is derived from canister status memory_size minus raw stable bytes. Cycle cost metrics remain unavailable.\n")
  echo resultDir

when isMainModule: main()
