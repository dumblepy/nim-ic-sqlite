## Usage: ./prepare_rust.sh && NISQL_COMPARE_NIM_SHA=HEAD nim c -r runner/profile.nim
## Runs comparable profile endpoints on fresh Nim/Rust canisters.
import std/[json, os, osproc, strutils, times]
import ../shared/profile_report
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

proc commandOutput(command: string): string =
  let (output, status) = execCmdEx(command)
  if status != 0: raise newException(OSError, command & ": " & output)
  output.strip()

proc main() =
  if not fileExists(RustWasm):
    raise newException(OSError, "run benchmarks/comparison/prepare_rust.sh first")
  discard commandOutput("cd " & quoteShell(NimBackendDir) & " && nicp productionBuild")
  let runId = "profile-" & now().utc.format("yyyyMMdd'T'HHmmss") & "Z"
  let resultDir = ComparisonDir / "results" / runId
  createDir(resultDir)
  let transport = CliTransport(projectDir: CanisterDir)
  try: transport.stopNetwork()
  except OSError: discard
  transport.startNetwork()
  defer: transport.stopNetwork()
  let nimCanister = transport.createCanister()
  let rustCanister = transport.createCanister()
  transport.install(nimCanister, NimWasm)
  transport.install(rustCanister, RustWasm)
  var measurements = ""
  for profile in ["read", "write", "get_many_in", "growth"]:
    for implementation in ["nim", "rust"]:
      let canister = if implementation == "nim": nimCanister else: rustCanister
      let didPath = if implementation == "nim": NimDid else: RustDid
      let methodName = "bench_" & profile & "_profile"
      let args = if profile == "growth": "(100, 20)" else: "(100)"
      if profile in ["read", "get_many_in"]:
        discard transport.call(canister, didPath, "bench_update_only", "(100)")
      let report = transport.call(canister, didPath, methodName, args,
        query = profile in ["read", "get_many_in"])
      let host = transport.call(canister, didPath, "bench_host_stats", "()", query = true)
      let measurement = profileMeasurement(implementation, profile, runId, report, host)
      measurements.add($measurement.toJson() & "\n")
  writeFile(resultDir / "profile_measurements.jsonl", measurements)
  writeFile(resultDir / "summary.md", "# " & runId & "\n\n" &
    "Common profile fields are in profile_measurements.jsonl. Implementation-specific counters are intentionally excluded from cross-implementation values.\n")
  echo resultDir

when isMainModule: main()
