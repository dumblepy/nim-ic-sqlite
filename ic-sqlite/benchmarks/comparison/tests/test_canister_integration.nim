## Opt-in end-to-end test: nim c -r tests/test_canister_integration.nim
## Uses a fresh local icp network and decodes the binary Candid response.
import std/[json, os, osproc, strformat, strutils, unittest]
import nicp_cdk/ic_types/[candid_types, ic_record]
import nicp_cdk/ic_types/candid_message/candid_decode

const CanisterDir = "/application/ic-sqlite/benchmarks/comparison/nim_canister"

proc run(command: string): string =
  let previous = getCurrentDir()
  try:
    setCurrentDir(CanisterDir)
    let (output, status) = execCmdEx(command)
    if status != 0: raise newException(OSError, fmt"{command}: {output}")
    output.strip()
  finally:
    setCurrentDir(previous)

proc decodedReply(methodName, args: string; query = false): CandidRecord =
  let queryFlag = if query: " --query" else: ""
  let output = run(fmt"icp canister call backend {methodName} '{args}'{queryFlag} --json")
  let hex = parseJson(output)["response_bytes"].getStr()
  var bytes = newSeq[byte](hex.len div 2)
  for index in 0 ..< bytes.len:
    bytes[index] = byte(parseHexInt(hex[index * 2 .. index * 2 + 1]))
  let decoded = decodeCandidMessage(bytes)
  if decoded.values.len != 1 or decoded.values[0].kind != ctVariant:
    raise newException(ValueError, "expected one Candid result variant")
  let variant = decoded.values[0].variantVal
  if variant.tag == candidHash("Err"):
    raise newException(ValueError, "benchmark rejected call: " & candidValueToCandidRecord(variant.value).getStr())
  if variant.tag != candidHash("Ok"):
    raise newException(ValueError, "unexpected benchmark result variant")
  candidValueToCandidRecord(variant.value)

proc rejectedUpdate(methodName, args: string) =
  let previous = getCurrentDir()
  try:
    setCurrentDir(CanisterDir)
    let (_, status) = execCmdEx(fmt"icp canister call backend {methodName} '{args}' --json")
    if status == 0: raise newException(ValueError, "expected update to trap")
  finally:
    setCurrentDir(previous)

proc stopNetwork() =
  ## Stopping an already stopped local network is harmless in test setup.
  let previous = getCurrentDir()
  try:
    setCurrentDir(CanisterDir)
    discard execCmdEx("icp network stop")
  finally:
    setCurrentDir(previous)

proc startNetwork() =
  let previous = getCurrentDir()
  try:
    setCurrentDir(CanisterDir)
    if execShellCmd("icp network start -d") != 0:
      raise newException(OSError, "unable to start local icp network")
  finally:
    setCurrentDir(previous)

suite "Nim benchmark canister":
  test "CRUD, churn, memory observations, and upgrade survive local replica":
    stopNetwork()
    startNetwork()
    defer: stopNetwork()
    discard run("icp deploy -y")

    let initial = decodedReply("bench_host_stats", "()", query = true)
    check initial["raw_stable_pages"].getNat64() >= 1
    let reset = decodedReply("bench_reset", "(3)")
    check reset["rows"].getNat64() == 3
    check decodedReply("bench_read", "(3)", query = true)["checksum"].getNat64() == 75
    discard decodedReply("bench_update_only", "(3)")
    check decodedReply("bench_read", "(3)", query = true)["checksum"].getNat64() == 81

    let churn = decodedReply("bench_churn_reset", "(5)")
    check churn["row_count"].getNat64() == 5
    check decodedReply("bench_churn_delete", "(0, 2, 0)")["row_count"].getNat64() == 3
    check decodedReply("bench_churn_insert", "(5, 2, 0)")["row_count"].getNat64() == 5
    let stats = decodedReply("db_stats", "()", query = true)
    check stats["sqlite_page_size"].getNat64() == 16_384
    check stats["sqlite_page_count"].getNat64() > 0
    let raw = decodedReply("bench_host_stats", "()", query = true)
    check raw["raw_stable_pages"].getNat64() >= stats["stable_pages"].getNat64()
    check decodedReply("bench_large_blob", "(65536)")["checksum"].getNat64() == 65_536
    check decodedReply("bench_join", "(100)")["checksum"].getNat64() == 100
    check decodedReply("bench_many_rows", "(3)", query = true)["checksum"].getNat64() == 81
    check decodedReply("bench_read_public_helper", "(3)", query = true)["checksum"].getNat64() == 81
    check decodedReply("bench_read_prepare_each", "(3)", query = true)["checksum"].getNat64() == 81
    let readProfile = decodedReply("bench_read_profile", "(3)", query = true)
    check readProfile["checksum"].getNat64() == 81
    check readProfile["stable_read_calls"].getNat64() > 0
    check decodedReply("bench_get_many_in", "(3)", query = true)["checksum"].getNat64() == 81
    let getManyProfile = decodedReply("bench_get_many_in_profile", "(3)", query = true)
    check getManyProfile["checksum"].getNat64() == 81
    check getManyProfile["stable_read_calls"].getNat64() > 0
    check decodedReply("bench_unbounded_order_by", "(10)")["checksum"].getNat64() > 0
    check decodedReply("bench_growth", "(10, 20)")["checksum"].getNat64() == 20
    let capacity = decodedReply("bench_capacity_growth_guard", "(10, 20)")
    check capacity["checksum"].getNat64() == 20
    check capacity["db_size_before"].getNat64() == capacity["db_size_after"].getNat64()
    check capacity["sqlite_virtual_pages_before"].getNat64() == capacity["sqlite_virtual_pages_after"].getNat64()
    check capacity["raw_stable_pages_before"].getNat64() == capacity["raw_stable_pages_after"].getNat64()
    let growthProfile = decodedReply("bench_growth_profile", "(10, 20)")
    check growthProfile["checksum"].getNat64() == 20
    check growthProfile["instructions"].getNat64() > 0
    check growthProfile["stable_write_calls"].getNat64() > 0
    let writeProfile = decodedReply("bench_write_profile", "(3)")
    check writeProfile["checksum"].getNat64() == 3
    check writeProfile["stable_write_calls"].getNat64() > 0

    discard run("icp deploy backend -m upgrade -y")
    check decodedReply("bench_read", "(3)", query = true)["checksum"].getNat64() == 81
    check decodedReply("db_stats", "()", query = true)["sqlite_page_count"].getNat64() > 0

  test "stable publish failure traps and rolls back the whole update message":
    stopNetwork()
    startNetwork()
    defer: stopNetwork()
    let previousFailpoint = getEnv("NISQL_ENABLE_FAILPOINT")
    putEnv("NISQL_ENABLE_FAILPOINT", "1")
    defer:
      if previousFailpoint.len == 0: delEnv("NISQL_ENABLE_FAILPOINT")
      else: putEnv("NISQL_ENABLE_FAILPOINT", previousFailpoint)
    discard run("icp deploy -y")

    let seeded = decodedReply("bench_reset", "(1000)")
    let beforeChecksum = decodedReply("bench_read", "(1000)", query = true)["checksum"].getNat64()
    let beforePages = decodedReply("bench_host_stats", "()", query = true)["raw_stable_pages"].getNat64()
    check seeded["rows"].getNat64() == 1000
    rejectedUpdate("bench_failpoint_update", "(1000)")
    check decodedReply("bench_read", "(1000)", query = true)["checksum"].getNat64() == beforeChecksum
    check decodedReply("bench_host_stats", "()", query = true)["raw_stable_pages"].getNat64() == beforePages
