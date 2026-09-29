## Version-checked icp CLI transport. Responses are decoded from Candid bytes.
import std/[json, os, osproc, strformat, strutils]
import nicp_cdk/ic_types/[candid_types, ic_record]
import nicp_cdk/ic_types/candid_message/candid_decode

type CliTransport* = object
  projectDir*: string
  network*: string
  initialCycles*: string

proc networkArgs*(transport: CliTransport): string =
  if transport.network.len == 0: ""
  else: " --network " & quoteShell(transport.network)

proc parseCliNat*(value: JsonNode): uint64 =
  ## `icp canister status --json` prints large counters as strings with `_`.
  let text = if value.kind == JString: value.getStr().replace("_", "") else: $value.getBiggestInt()
  parseBiggestUInt(text).uint64

proc runCommand*(transport: CliTransport; command: string): string =
  let previous = getCurrentDir()
  try:
    setCurrentDir(transport.projectDir)
    let (output, status) = execCmdEx(command)
    if status != 0: raise newException(OSError, fmt"{command}: {output}")
    output.strip()
  finally:
    setCurrentDir(previous)

proc startNetwork*(transport: CliTransport) =
  let previous = getCurrentDir()
  try:
    setCurrentDir(transport.projectDir)
    if execShellCmd("icp network start -d") != 0:
      raise newException(OSError, "unable to start local icp network")
  finally:
    setCurrentDir(previous)

proc stopNetwork*(transport: CliTransport) =
  discard transport.runCommand("icp network stop")

proc createCanister*(transport: CliTransport): string =
  let cycles = if transport.initialCycles.len == 0: ""
    else: " --cycles " & quoteShell(transport.initialCycles)
  parseJson(transport.runCommand("icp canister create --detached --json" &
    transport.networkArgs() & cycles))["canister_id"].getStr()

proc install*(transport: CliTransport; canister, wasmPath: string) =
  discard transport.runCommand("icp canister install " & quoteShell(canister) &
    " --wasm " & quoteShell(wasmPath) & " -y" & transport.networkArgs())

proc upgrade*(transport: CliTransport; canister, wasmPath: string) =
  discard transport.runCommand("icp canister install " & quoteShell(canister) &
    " --wasm " & quoteShell(wasmPath) & " -m upgrade -y" & transport.networkArgs())

proc canisterStatus*(transport: CliTransport; canister: string): JsonNode =
  parseJson(transport.runCommand("icp canister status " & quoteShell(canister) &
    " --json" & transport.networkArgs()))

proc canisterMemoryBytes*(transport: CliTransport; canister: string): uint64 =
  let status = transport.canisterStatus(canister)
  status["memory_size"].parseCliNat()

proc canisterCycles*(status: JsonNode): uint64 =
  if not status.hasKey("cycles"):
    raise newException(ValueError, "canister status does not expose cycles")
  status["cycles"].parseCliNat()

proc canisterReservedCycles*(status: JsonNode): uint64 =
  if not status.hasKey("reserved_cycles"):
    raise newException(ValueError, "canister status does not expose reserved_cycles")
  status["reserved_cycles"].parseCliNat()

proc call*(transport: CliTransport; canister, didPath, methodName, args: string;
           query = false): CandidRecord =
  let queryFlag = if query: " --query" else: ""
  let command = "icp canister call " & quoteShell(canister) & " " & quoteShell(methodName) &
    " " & quoteShell(args) & " --candid " & quoteShell(didPath) & queryFlag &
    " --json" & transport.networkArgs()
  let response = parseJson(transport.runCommand(command))
  let hex = response["response_bytes"].getStr()
  if hex.len mod 2 != 0: raise newException(ValueError, "odd Candid hex length")
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
