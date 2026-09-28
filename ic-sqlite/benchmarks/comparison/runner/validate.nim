## Validates the complete, paired core-KV result set before it is summarized.
## Usage: nim c -r runner/validate.nim <results/run-id>
import std/[json, os, sets, strformat]

const CorePhases* = ["reset", "read", "update"]

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

proc main() =
  if paramCount() != 1:
    raise newException(ValueError, "pass a core comparison result directory")
  let measurementsPath = paramStr(1) / "measurements.jsonl"
  if not fileExists(measurementsPath):
    raise newException(OSError, "missing measurements.jsonl")
  validateCoreResults(measurementsPath)
  echo fmt"validated {measurementsPath}"

when isMainModule: main()
