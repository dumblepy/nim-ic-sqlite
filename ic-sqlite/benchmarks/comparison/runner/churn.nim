## Runs the pinned Rust churn workload against one fresh canister of each kind.
## Usage: ./prepare_rust.sh && nim c -r runner/churn.nim
import std/[json, options, os, osproc, strformat, strutils, times]
import nicp_cdk/ic_types/ic_record except `%`, `%*`
import ../shared/[bench_report, bench_spec]
import ./transport

const
  ComparisonDir = "/application/ic-sqlite/benchmarks/comparison"
  CanisterDir = ComparisonDir / "nim_canister"
  NimWasm = CanisterDir / "backend/main.wasm"
  NimDid = CanisterDir / "backend/backend.did"
  RustRepo = ComparisonDir / ".cache/ic-sqlite-vfs"
  RustWasm = RustRepo / "benchmarks/kv-canister/target/wasm32-unknown-unknown/release/ic_sqlite_vfs_kv_bench.wasm"
  RustDid = RustRepo / "benchmarks/kv-canister/kv_bench.did"

proc commandOutput(command: string): string =
  let (output, status) = execCmdEx(command)
  if status != 0: raise newException(OSError, command & ": " & output)
  output.strip()

proc sha256(path: string): string = commandOutput("sha256sum " & quoteShell(path)).splitWhitespace()[0]

proc observe(transport: CliTransport; runId, implementation, repoSha, wasmSha,
             canister, didPath, methodName, args, phase: string;
             cycle, rows: uint32; expectedCount, baseline: uint64): Measurement =
  let response = transport.call(canister, didPath, methodName, args)
  let count = response["row_count"].getNat64()
  if count != expectedCount:
    raise newException(ValueError, fmt"{implementation} cycle {cycle} {phase}: expected {expectedCount} rows, got {count}")
  let host = transport.call(canister, didPath, "bench_host_stats", "()", query = true)
  let raw = host["raw_stable_pages"].getNat64()
  Measurement(runId: runId, implementation: implementation, repoSha: repoSha,
    wasmSha256: wasmSha, scenario: "churn_5000x100", phase: phase,
    trial: 1, cycle: cycle, rows: uint64(rows), success: true,
    instructionWindow: iwCore, instructionsUpdate: some(response["instructions"].getNat64()),
    dbSize: response["db_size"].getNat64(),
    sqliteVirtualPages: response["stable_pages"].getNat64(),
    sqlitePageSize: response["sqlite_page_size"].getNat64(),
    sqlitePageCount: response["sqlite_page_count"].getNat64(),
    sqliteFreelistCount: response["sqlite_freelist_count"].getNat64(),
    rawStablePages: some(raw), rawStableBytes: some(raw * StablePageSize),
    rawGrowthPages: some(rawGrowthPages(baseline, raw)), rowCount: count)

proc main() =
  if not fileExists(RustWasm):
    raise newException(OSError, "run benchmarks/comparison/prepare_rust.sh first")
  ## Keep the Nim artifact comparable with Rust's Cargo release artifact.
  discard commandOutput("cd " & quoteShell(CanisterDir / "backend") & " && nicp productionBuild")
  let runId = "churn-" & now().utc.format("yyyyMMdd'T'HHmmss") & "Z"
  let resultDir = ComparisonDir / "results" / runId
  createDir(resultDir)
  let nimSha = commandOutput("git -C /application/ic-sqlite rev-parse HEAD")
  let rustSha = commandOutput("git -C " & quoteShell(RustRepo) & " rev-parse HEAD")
  let nimWasmSha = sha256(NimWasm)
  let rustWasmSha = sha256(RustWasm)
  let transport = CliTransport(projectDir: CanisterDir)
  try: transport.stopNetwork()
  except OSError: discard
  transport.startNetwork()
  defer: transport.stopNetwork()
  let nimCanister = transport.createCanister()
  let rustCanister = transport.createCanister()
  transport.install(nimCanister, NimWasm)
  transport.install(rustCanister, RustWasm)
  var manifest = parseFile(ComparisonDir / "bench_manifest.json")
  manifest["run_kind"] = %"churn_capacity"
  manifest["run_id"] = %runId
  manifest["artifacts"]["nim_wasm_sha256"] = %nimWasmSha
  manifest["artifacts"]["rust_wasm_sha256"] = %rustWasmSha
  manifest["artifacts"]["rust_host_stats_patch_sha256"] = %sha256(ComparisonDir / "rust_host_stats.patch")
  manifest["artifacts"]["nim_benchmark_source_sha256"] = %sha256(CanisterDir / "backend/src/main.nim")
  manifest["artifacts"]["nim_db_source_sha256"] = %sha256("/application/ic-sqlite/src/ic_sqlite/db.nim")
  manifest["artifacts"]["nicp_candid_types_source_sha256"] = %sha256("/application/nicp_cdk/src/nicp_cdk/ic_types/candid_types.nim")
  manifest["toolchains"]["icp_cli"] = %commandOutput("icp --version")
  manifest["toolchains"]["rustc"] = %commandOutput("rustc --version")
  manifest["toolchains"]["nim"] = %commandOutput("nim --version").splitLines()[0]
  manifest["toolchains"]["wasi_sdk"] = %commandOutput(quoteShell(getEnv("WASI_SDK_PATH") / "bin/clang") & " --version").splitLines()[0]
  manifest["toolchains"]["pocket_ic"] = %"not_used"
  manifest["subnet"]["kind"] = %"icp_cli_local_managed"
  manifest["subnet"]["node_count"] = %"not_exposed_by_icp_cli"
  manifest["subnet"]["initial_cycles"] = %"2000000000000"
  manifest["nim_source_dirty"] = %(
    commandOutput("git -C /application/ic-sqlite status --porcelain").len > 0)
  manifest["nim_canister"] = %nimCanister
  manifest["rust_canister"] = %rustCanister
  manifest["cycles"] = %100
  manifest["rows_initial"] = %5_000
  manifest["rows_per_step"] = %1_000
  manifest["notes"] = %["Each implementation keeps one canister for all 100 cycles.",
    "A failed step terminates the run; completed rows remain in measurements files."]
  writeFile(resultDir / "manifest.json", manifest.pretty())
  var csv = MeasurementCsvHeader & "\n"
  var jsonl = ""
  let nimBaseline = transport.call(nimCanister, NimDid, "bench_host_stats", "()", query = true)["raw_stable_pages"].getNat64()
  let rustBaseline = transport.call(rustCanister, RustDid, "bench_host_stats", "()", query = true)["raw_stable_pages"].getNat64()
  manifest["trial_baselines"] = %*{
    "nim_raw_stable_pages": nimBaseline,
    "rust_raw_stable_pages": rustBaseline
  }
  writeFile(resultDir / "manifest.json", manifest.pretty())

  proc record(implementation, methodName, args, phase: string; cycle, rows: uint32;
              expectedCount: uint64) =
    let isNim = implementation == "nim"
    let m = observe(transport, runId, implementation,
      if isNim: nimSha else: rustSha,
      if isNim: nimWasmSha else: rustWasmSha,
      if isNim: nimCanister else: rustCanister,
      if isNim: NimDid else: RustDid,
      methodName, args, phase, cycle, rows, expectedCount,
      if isNim: nimBaseline else: rustBaseline)
    csv.add(m.toCsvRow() & "\n")
    jsonl.add($m.toJson() & "\n")
    writeFile(resultDir / "measurements.csv", csv)
    writeFile(resultDir / "measurements.jsonl", jsonl)

  for implementation in ["nim", "rust"]:
    record(implementation, "bench_churn_reset", "(5000)", "reset", 0, 5_000, 5_000)
  for cycle in 0'u32 ..< 100'u32:
    let (deleteStart, deleteRows) = churnDeleteRange(cycle)
    let (insertStart, insertRows) = churnInsertRange(cycle)
    for implementation in ["nim", "rust"]:
      record(implementation, "bench_churn_delete",
        fmt"({deleteStart}, {deleteRows}, {cycle})", "delete", cycle, deleteRows, 4_000)
      record(implementation, "bench_churn_insert",
        fmt"({insertStart}, {insertRows}, {cycle})", "insert", cycle, insertRows, 5_000)
    echo fmt"churn cycle {cycle + 1}/100 complete"
  writeFile(resultDir / "summary.md", "# " & runId & "\n\n" &
    "All 100 churn cycles completed for both implementations. " &
    "Raw memory and SQLite page counts for every step are in measurements.csv.\n")
  echo resultDir

when isMainModule: main()
