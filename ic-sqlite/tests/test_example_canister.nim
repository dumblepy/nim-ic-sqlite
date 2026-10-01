## End-to-end test for the checked-in Nim canister example.
##
## This deliberately drives `icp` from Nim so the test covers the actual
## wasm build, installation lifecycle, stable-memory migration, and Candid
## calls instead of only exercising the native SQLite test backend.
import std/[os, osproc, strformat, strutils, unittest]

const ExampleDir = "/application/ic-sqlite/examples/kv_crud"

proc runExample(command: string): string =
  let originalDir = getCurrentDir()
  try:
    setCurrentDir(ExampleDir)
    let (output, exitCode) = execCmdEx(command)
    if exitCode != 0:
      raise newException(OSError,
        fmt"example canister command failed ({exitCode}): {command}\n{output}")
    output.strip()
  finally:
    setCurrentDir(originalDir)

proc stopExampleNetwork() =
  let originalDir = getCurrentDir()
  try:
    setCurrentDir(ExampleDir)
    discard execCmdEx("icp network stop")
  finally:
    setCurrentDir(originalDir)

proc startExampleNetwork() =
  ## `icp network start -d` daemonizes and leaves stdout inherited by the
  ## launcher. Do not use execCmdEx here: it waits for that inherited pipe.
  let originalDir = getCurrentDir()
  try:
    setCurrentDir(ExampleDir)
    let exitCode = execShellCmd("icp network start -d")
    if exitCode != 0:
      raise newException(OSError, "unable to start example local ICP network")
  finally:
    setCurrentDir(originalDir)

proc call(methodName, args: string; query = false): string =
  let queryFlag = if query: " --query" else: ""
  runExample(fmt"icp canister call backend {methodName} '{args}'{queryFlag}")

proc expectText(output, expected: string) =
  check output.contains("\"" & expected & "\"")

suite "example canister integration":
  test "runs migrations and CRUD through a deployed canister":
    check dirExists(ExampleDir)
    stopExampleNetwork()
    startExampleNetwork()
    defer:
      stopExampleNetwork()

    discard runExample("icp deploy -y")
    expectText(call("migrationCount", "()", query = true), "2")

    expectText(call("put", "(\"alpha\", \"first\")"), "ok")
    expectText(call("get", "(\"alpha\")", query = true), "first")
    expectText(call("update", "(\"alpha\", \"second\")"), "ok")
    expectText(call("get", "(\"alpha\")", query = true), "second")

    # Exercise the transaction macro in the actual Wasm canister, including
    # a failure on the second INSERT after the first INSERT has succeeded.
    expectText(call("putPair", "(\"pair-a\", \"first\", \"pair-b\", \"second\")"), "ok")
    expectText(call("get", "(\"pair-a\")", query = true), "first")
    expectText(call("get", "(\"pair-b\")", query = true), "second")
    let rolledBack = call("putPair", "(\"rolled-back\", \"discarded\", \"pair-b\", \"replacement\")")
    check rolledBack.contains("error: ")
    expectText(call("get", "(\"rolled-back\")", query = true), "not_found")
    expectText(call("get", "(\"pair-b\")", query = true), "second")

    ## An upgrade reopens SQLite from stable memory and reruns migrations.
    ## The migration ledger must remain idempotent and data must survive.
    discard runExample("icp deploy backend -m upgrade -y")
    expectText(call("migrationCount", "()", query = true), "2")
    expectText(call("get", "(\"alpha\")", query = true), "second")

    expectText(call("get", "(\"pair-a\")", query = true), "first")
    expectText(call("get", "(\"pair-b\")", query = true), "second")
    expectText(call("get", "(\"rolled-back\")", query = true), "not_found")

    expectText(call("deleteValue", "(\"alpha\")"), "ok")
    expectText(call("get", "(\"alpha\")", query = true), "not_found")
