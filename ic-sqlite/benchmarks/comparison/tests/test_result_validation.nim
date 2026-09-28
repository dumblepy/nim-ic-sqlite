import std/[os, strutils, unittest]
import ../runner/validate
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
