import std/[json, os, strutils, unittest]
import ../benchmarks/comparison/runner/validate
import std/strformat

const ValidRows = """{"implementation":"nim","phase":"reset","trial":1,"success":true,"instructions_update":1,"instructions_query":null,"raw_stable_pages":1,"raw_stable_bytes":65536,"heap_bytes":2}
{"implementation":"rust","phase":"reset","trial":1,"success":true,"instructions_update":1,"instructions_query":null,"raw_stable_pages":1,"raw_stable_bytes":65536,"heap_bytes":2}
{"implementation":"nim","phase":"read","trial":1,"success":true,"instructions_update":null,"instructions_query":1,"raw_stable_pages":1,"raw_stable_bytes":65536,"heap_bytes":2}
{"implementation":"rust","phase":"read","trial":1,"success":true,"instructions_update":null,"instructions_query":1,"raw_stable_pages":1,"raw_stable_bytes":65536,"heap_bytes":2}
{"implementation":"nim","phase":"update","trial":1,"success":true,"instructions_update":1,"instructions_query":null,"raw_stable_pages":1,"raw_stable_bytes":65536,"heap_bytes":2}
{"implementation":"rust","phase":"update","trial":1,"success":true,"instructions_update":1,"instructions_query":null,"raw_stable_pages":1,"raw_stable_bytes":65536,"heap_bytes":2}
"""

proc withRows(rows: string; body: proc(path: string)) =
  let path = getTempDir() / "nisql-result-validation.jsonl"
  defer: removeFile(path)
  writeFile(path, rows)
  body(path)

proc churnRow(implementation, phase: string; cycle: int64;
              success: bool = true; count: int64 = -1): string =
  let expected = case phase
    of "reset": 5_000
    of "delete": 4_000
    else: 5_000
  let rowsValue = if count < 0: $expected else: $count
  let errorKind = if success: "" else: "injected"
  let successValue = if success: "true" else: "false"
  fmt"""{{"implementation":"{implementation}","scenario":"churn_5000x100","phase":"{phase}","cycle":{cycle},"rows":{rowsValue},"success":{successValue},"error_kind":"{errorKind}","instructions_update":1000,"instructions_query":null,"db_size":1,"sqlite_page_size":16384,"sqlite_page_count":1,"sqlite_freelist_count":0,"sqlite_virtual_pages":1,"raw_stable_pages":1,"raw_stable_bytes":65536,"raw_growth_pages":0,"dirty_pages_peak":null,"heap_bytes":null,"row_count":{rowsValue},"value_checksum":0,"instruction_window":"iwCore"}}"""

proc buildChurnRows(failImplementation = "", failCycle = -1,
                    countOverride = -1, missingImplementation = ""): string =
  var text = ""
  for implementation in ["nim", "rust"]:
    if implementation == missingImplementation: continue
    for phase in ["reset", "delete", "insert"]:
      if phase == "reset":
        let failed = implementation == failImplementation and failCycle == -2
        text.add(churnRow(implementation, phase, 0,
          success = not failed, count = countOverride) & "\n")
      else:
        for cycle in 0 ..< 100:
          let failed = implementation == failImplementation and failCycle == cycle
          text.add(churnRow(implementation, phase, cycle,
            success = not failed, count = countOverride) & "\n")
  text

proc buildProfileRows(missingField = ""): string =
  var text = ""
  for implementation in ["nim", "rust"]:
    for profile in ["read", "write", "get_many_in", "growth"]:
      var row = fmt"""{{"implementation":"{implementation}","profile":"{profile}","rows":100,"instructions":10,"checksum":100,"db_size":16384,"stable_pages":2,"stable_bytes":131072,"raw_stable_pages":4,"raw_stable_bytes":262144,"details":{{}}}}"""
      if missingField.len > 0: row = row.replace("\"" & missingField & "\":100,", "")
      text.add(row & "\n")
  text

proc writeCoreManifest(dir: string; includeAccountingNote = true;
                       runKind = "local_comparison") =
  var observations = newJArray()
  for implementation in ["nim", "rust"]:
    for phase in ["reset", "read", "update"]:
      observations.add(%*{
        "trial": 1, "implementation": implementation, "phase": phase,
        "cycles_before": 10, "cycles_after": 9,
        "reserved_cycles_before": 0, "reserved_cycles_after": 0
      })
  let notes = if includeAccountingNote:
    %*["cycle_balance_observations are not instruction-only execution costs."]
  else: %*["cycle balances were observed locally."]
  writeFile(dir / "manifest.json", $(%*{
    "run_kind": runKind, "trials": 1,
    "cycle_balance_observations": observations, "notes": notes
  }))

proc withCoreArtifact(includeAccountingNote: bool; body: proc(path: string)) =
  let dir = getTempDir() / "nisql-core-artifact-validation"
  createDir(dir)
  defer: removeDir(dir)
  writeFile(dir / "measurements.jsonl", ValidRows)
  writeCoreManifest(dir, includeAccountingNote)
  body(dir)

suite "core comparison result validation":
  test "accepts paired complete measurements":
    withRows(ValidRows, proc(path: string) = validateCoreResults(path))

  test "rejects a missing observation":
    expect ValueError:
      withRows(ValidRows.replace("\"heap_bytes\":2", "\"heap_bytes\":null"),
        proc(path: string) = validateCoreResults(path))

  test "rejects an unpaired phase":
    expect ValueError:
      withRows(ValidRows.replace("{\"implementation\":\"rust\",\"phase\":\"update\",\"trial\":1,\"success\":true,\"instructions_update\":1,\"instructions_query\":null,\"raw_stable_pages\":1,\"raw_stable_bytes\":65536,\"heap_bytes\":2}\n", ""),
        proc(path: string) = validateCoreResults(path))

  test "accepts complete local accounting observations":
    withCoreArtifact(true, proc(path: string) = validateCoreManifest(path))

  test "rejects an unclassified local accounting observation":
    expect ValueError:
      withCoreArtifact(false, proc(path: string) = validateCoreManifest(path))

  test "accepts accounting observations from an external comparison":
    let dir = getTempDir() / "nisql-external-core-artifact-validation"
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "measurements.jsonl", ValidRows)
    writeCoreManifest(dir, runKind = "external_comparison")
    validateCoreManifest(dir)

suite "churn comparison result validation":
  test "accepts a complete paired churn run":
    withRows(buildChurnRows(), proc(path: string) = validateChurnResults(path))

  test "rejects a failed churn step":
    expect ValueError:
      withRows(buildChurnRows(failImplementation = "nim", failCycle = 7),
        proc(path: string) = validateChurnResults(path))

  test "rejects a failed churn reset":
    expect ValueError:
      withRows(buildChurnRows(failImplementation = "rust", failCycle = -2),
        proc(path: string) = validateChurnResults(path))

  test "rejects an unexpected row count":
    expect ValueError:
      withRows(buildChurnRows(countOverride = 3_999),
        proc(path: string) = validateChurnResults(path))

  test "rejects a missing churn implementation":
    expect ValueError:
      withRows(buildChurnRows(missingImplementation = "rust"),
        proc(path: string) = validateChurnResults(path))

suite "run kind detection":
  test "detects churn_capacity from the scenario field":
    withRows(buildChurnRows(), proc(path: string) =
      doAssert(runKind(path) == "churn_capacity"))

  test "detects local_comparison from the scenario field":
    withRows(ValidRows, proc(path: string) =
      doAssert(runKind(path) == "local_comparison"))

suite "profile result validation":
  test "accepts all paired profile measurements":
    withRows(buildProfileRows(), proc(path: string) = validateProfileResults(path))

  test "rejects a missing common field":
    expect ValueError:
      withRows(buildProfileRows("rows"), proc(path: string) = validateProfileResults(path))

  test "detects profile artifacts":
    withRows(buildProfileRows(), proc(path: string) =
      doAssert(runKind(path) == "profile"))
