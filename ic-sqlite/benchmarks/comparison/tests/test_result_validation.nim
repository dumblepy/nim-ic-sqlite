import std/[os, strutils, unittest]
import ../runner/validate

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
