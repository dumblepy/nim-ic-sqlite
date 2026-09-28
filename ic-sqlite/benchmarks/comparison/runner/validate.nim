## Validates the complete, paired core-KV and churn result sets before they are
## summarized or costed.
## Usage: nim c -r runner/validate.nim <results/run-id>
import std/[json, os, sets, strformat]

const
  CorePhases* = ["reset", "read", "update"]
  ChurnPhases = ["reset", "delete", "insert"]

proc requiredNumber(row: JsonNode; field, label: string) =
  if not row.hasKey(field) or row[field].kind == JNull:
    raise newException(ValueError, label & " is missing " & field)

proc validateCoreResults*(measurementsPath: string) =
  var seen = initHashSet[string]()
  var trials = initHashSet[uint64]()
  for line in lines(measurementsPath):
    if line.len == 0: continue
    let row = parseJson(line)
    let implementation = row["implementation"].getStr()
    if implementation notin ["nim", "rust"]:
      raise newException(ValueError, "unknown implementation: " & implementation)
    let phase = row["phase"].getStr()
    if phase notin CorePhases:
      raise newException(ValueError, "unexpected core phase: " & phase)
    if not row["success"].getBool:
      raise newException(ValueError, implementation & " " & phase & " did not succeed")
    let trial = uint64(row["trial"].getBiggestInt())
    if trial == 0: raise newException(ValueError, "trial must be positive")
    let key = implementation & ":" & $trial & ":" & phase
    if key in seen: raise newException(ValueError, "duplicate measurement: " & key)
    seen.incl(key)
    trials.incl(trial)
    requiredNumber(row, if phase == "read": "instructions_query" else: "instructions_update", key)
    requiredNumber(row, "raw_stable_pages", key)
    requiredNumber(row, "raw_stable_bytes", key)
    requiredNumber(row, "heap_bytes", key)
  if trials.len == 0: raise newException(ValueError, "no core measurements")
  for trial in trials:
    for implementation in ["nim", "rust"]:
      for phase in CorePhases:
        let key = implementation & ":" & $trial & ":" & phase
        if key notin seen: raise newException(ValueError, "missing paired measurement: " & key)

const
  ChurnCycles* = 100
  ChurnInitialRows* = 5_000
  ChurnStepRows* = 1_000

proc validateChurnResults*(measurementsPath: string) =
  ## P5: mechanically reject a churn run with a failed, missing, or unpaired step.
  ## Each implementation must contribute exactly 201 successful rows
  ## (1 reset + 100 delete + 100 insert) with the expected row counts.
  var seen = initHashSet[string]()
  var implementations = initHashSet[string]()
  for line in lines(measurementsPath):
    if line.len == 0: continue
    let row = parseJson(line)
    let implementation = row["implementation"].getStr()
    if implementation notin ["nim", "rust"]:
      raise newException(ValueError, "unknown implementation: " & implementation)
    implementations.incl(implementation)
    let phase = row["phase"].getStr()
    if phase notin ChurnPhases:
      raise newException(ValueError, "unexpected churn phase: " & phase)
    if not row["success"].getBool:
      raise newException(ValueError,
        implementation & " churn step did not succeed: " & row["error_kind"].getStr())
    let cycle = uint64(row["cycle"].getBiggestInt())
    let key = implementation & ":" & phase & ":" & $cycle
    if key in seen: raise newException(ValueError, "duplicate churn measurement: " & key)
    seen.incl(key)
    let expectedCount = case phase
      of "reset": ChurnInitialRows
      of "delete": ChurnInitialRows - ChurnStepRows
      else: ChurnInitialRows
    if row["row_count"].getBiggestInt().uint64 != uint64(expectedCount):
      let actualCount = row["row_count"].getBiggestInt()
      raise newException(ValueError,
        fmt"{key}: expected {expectedCount} rows, got {actualCount}")
    requiredNumber(row, "instructions_update", key)
    requiredNumber(row, "raw_stable_pages", key)
    requiredNumber(row, "raw_stable_bytes", key)
    requiredNumber(row, "sqlite_page_count", key)
    requiredNumber(row, "sqlite_freelist_count", key)
  for phase in ChurnPhases:
    for implementation in ["nim", "rust"]:
      if phase == "reset":
        let key = implementation & ":reset:0"
        if key notin seen: raise newException(ValueError, "missing churn measurement: " & key)
      else:
        for cycle in 0 ..< ChurnCycles:
          let key = implementation & ":" & phase & ":" & $cycle
          if key notin seen: raise newException(ValueError, "missing churn measurement: " & key)

proc runKind*(measurementsPath: string): string =
  ## `churn_capacity` for churn runs, `local_comparison` for core KV runs.
  ## Rows without a scenario field are core-KV rows (legacy fixtures).
  for line in lines(measurementsPath):
    if line.len == 0: continue
    let row = parseJson(line)
    let scenario = if row.hasKey("scenario"): row["scenario"].getStr() else: ""
    return if scenario == "churn_5000x100": "churn_capacity" else: "local_comparison"
  raise newException(ValueError, "no measurements to validate")

proc main() =
  if paramCount() != 1:
    raise newException(ValueError, "pass a comparison result directory")
  let measurementsPath = paramStr(1) / "measurements.jsonl"
  if not fileExists(measurementsPath):
    raise newException(OSError, "missing measurements.jsonl")
  case runKind(measurementsPath)
  of "churn_capacity": validateChurnResults(measurementsPath)
  else: validateCoreResults(measurementsPath)
  echo fmt"validated {measurementsPath}"

when isMainModule: main()
