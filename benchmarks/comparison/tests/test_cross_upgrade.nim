## Opt-in local replica test for the two pinned benchmark artifacts.
import std/[os, unittest]
import nicp_cdk/ic_types/ic_record
import ../runner/transport

const
  ComparisonDir = "/application/benchmarks/comparison"
  NimWasm = ComparisonDir / "nim_canister/backend/main.wasm"
  NimDid = ComparisonDir / "nim_canister/backend/backend.did"
  RustWasm = ComparisonDir / ".cache/ic-sqlite-vfs/benchmarks/kv-canister/target/wasm32-unknown-unknown/release/ic_sqlite_vfs_kv_bench.wasm"
  RustDid = ComparisonDir / ".cache/ic-sqlite-vfs/benchmarks/kv-canister/kv_bench.did"

suite "cross implementation upgrade":
  test "both canisters reopen churn table and preserve rows":
    check fileExists(NimWasm)
    check fileExists(RustWasm)
    let transport = CliTransport(projectDir: ComparisonDir / "nim_canister")
    try: transport.stopNetwork()
    except OSError: discard
    transport.startNetwork()
    defer: transport.stopNetwork()
    for (wasmPath, didPath) in [(NimWasm, NimDid), (RustWasm, RustDid)]:
      let canister = transport.createCanister()
      transport.install(canister, wasmPath)
      check transport.call(canister, didPath, "bench_churn_reset", "(5)")["row_count"].getNat64() == 5
      transport.upgrade(canister, wasmPath)
      check transport.call(canister, didPath, "bench_churn_delete", "(0, 2, 0)")["row_count"].getNat64() == 3
      check transport.call(canister, didPath, "bench_churn_insert", "(5, 2, 0)")["row_count"].getNat64() == 5
