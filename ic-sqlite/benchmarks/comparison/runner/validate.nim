## Validates the complete, paired core-KV and churn result sets before they are
## summarized or costed.
## Usage: nim c -r runner/validate.nim <results/run-id>
import std/[json, os, sets, strformat, strutils]

const
  CorePhases* = ["reset", "read", "update"]
  ChurnPhases = ["reset", "delete", "insert"]
  ProfileNames = ["read", "write", "get_many_in", "growth"]

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

proc validateCoreManifest*(resultDir: string) =
  ## Local status balances are observations only.  Require their full shape and
  ## the explicit classification so a report cannot silently call them fees.
  let manifestPath = resultDir / "manifest.json"
  if not fileExists(manifestPath):
    raise newException(OSError, "missing manifest.json")
  let manifest = parseFile(manifestPath)
  if not manifest.hasKey("run_kind") or
      manifest["run_kind"].getStr() notin ["local_comparison", "external_comparison"]:
    raise newException(ValueError, "manifest is not a core comparison run")
  if not manifest.hasKey("trials") or manifest["trials"].kind == JNull:
    raise newException(ValueError, "manifest is missing trials")
  let trials = manifest["trials"].getBiggestInt()
  if trials < 1: raise newException(ValueError, "manifest trials must be positive")
  let measurementsPath = resultDir / "measurements.jsonl"
  var measuredTrials = initHashSet[int64]()
  for line in lines(measurementsPath):
    if line.len > 0:
      measuredTrials.incl(parseJson(line)["trial"].getBiggestInt())
  for trial in 1 .. trials:
    if trial notin measuredTrials:
      raise newException(ValueError, "manifest trial has no measurements: " & $trial)
  if measuredTrials.len != int(trials):
    raise newException(ValueError, "measurements do not match manifest trial count")
  if not manifest.hasKey("cycle_balance_observations") or
      manifest["cycle_balance_observations"].kind != JArray:
    raise newException(ValueError, "manifest is missing cycle balance observations")
  var seen = initHashSet[string]()
  for observation in manifest["cycle_balance_observations"]:
    for field in ["trial", "cycles_before", "cycles_after",
                  "reserved_cycles_before", "reserved_cycles_after"]:
      requiredNumber(observation, field, "cycle balance observation")
    let implementation = observation["implementation"].getStr()
    let phase = observation["phase"].getStr()
    let trial = observation["trial"].getBiggestInt()
    if implementation notin ["nim", "rust"] or phase notin CorePhases or
        trial < 1 or trial > trials:
      raise newException(ValueError, "invalid cycle balance observation")
    let key = implementation & ":" & $trial & ":" & phase
    if key in seen: raise newException(ValueError, "duplicate cycle balance observation: " & key)
    seen.incl(key)
  for trial in 1 .. trials:
    for implementation in ["nim", "rust"]:
      for phase in CorePhases:
        let key = implementation & ":" & $trial & ":" & phase
        if key notin seen:
          raise newException(ValueError, "missing cycle balance observation: " & key)
  if not manifest.hasKey("notes") or manifest["notes"].kind != JArray:
    raise newException(ValueError, "manifest is missing notes")
  var accountingNoteFound = false
  for note in manifest["notes"]:
    if note.kind == JString and note.getStr().contains("not instruction-only execution costs"):
      accountingNoteFound = true
  if not accountingNoteFound:
    raise newException(ValueError, "manifest does not classify local cycle balances")

const
  ChurnInitialRows* = 5_000
  ChurnStepRows* = 1_000

proc validateChurnResults*(measurementsPath: string) =
  ## P5: mechanically reject a churn run with a failed, missing, or unpaired step.
  ## Each implementation must contribute a reset plus a contiguous delete/insert
  ## cycle range starting at 0 (the full run is 100 cycles, but a shorter
  ## comparison run is accepted) with the expected row counts.
  var seen = initHashSet[string]()
  var implementations = initHashSet[string]()
  var maxCycle = -1
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
    if phase != "reset":
      maxCycle = max(maxCycle, int(cycle))
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
  if maxCycle < 0:
    raise newException(ValueError, "no churn cycles found")
  for phase in ChurnPhases:
    for implementation in ["nim", "rust"]:
      if phase == "reset":
        let key = implementation & ":reset:0"
        if key notin seen: raise newException(ValueError, "missing churn measurement: " & key)
      else:
        for cycle in 0 .. maxCycle:
          let key = implementation & ":" & phase & ":" & $cycle
          if key notin seen: raise newException(ValueError, "missing churn measurement: " & key)

proc validateProfileResults*(measurementsPath: string) =
  var seen = initHashSet[string]()
  for line in lines(measurementsPath):
    if line.len == 0: continue
    let row = parseJson(line)
    let implementation = row["implementation"].getStr()
    let profile = row["profile"].getStr()
    if implementation notin ["nim", "rust"] or profile notin ProfileNames:
      raise newException(ValueError, "unknown profile measurement")
    let key = implementation & ":" & profile
    if key in seen: raise newException(ValueError, "duplicate profile measurement: " & key)
    seen.incl(key)
    for field in ["rows", "instructions", "checksum", "db_size", "stable_pages", "stable_bytes", "raw_stable_pages", "raw_stable_bytes"]:
      requiredNumber(row, field, key)
  for implementation in ["nim", "rust"]:
    for profile in ProfileNames:
      let key = implementation & ":" & profile
      if key notin seen: raise newException(ValueError, "missing profile measurement: " & key)

proc runKind*(measurementsPath: string): string =
  ## `churn_capacity` for churn runs, `local_comparison` for core KV runs.
  ## Rows without a scenario field are core-KV rows (legacy fixtures).
  for line in lines(measurementsPath):
    if line.len == 0: continue
    let row = parseJson(line)
    if row.hasKey("profile"): return "profile"
    let scenario = if row.hasKey("scenario"): row["scenario"].getStr() else: ""
    return if scenario.startsWith("churn_5000x"): "churn_capacity" else: "local_comparison"
  raise newException(ValueError, "no measurements to validate")

proc main() =
  if paramCount() != 1:
    raise newException(ValueError, "pass a comparison result directory")
  let resultDir = paramStr(1)
  let measurementsPath = if fileExists(resultDir / "profile_measurements.jsonl"):
    resultDir / "profile_measurements.jsonl"
  else:
    resultDir / "measurements.jsonl"
  if not fileExists(measurementsPath):
    raise newException(OSError, "missing measurements.jsonl")
  case runKind(measurementsPath)
  of "churn_capacity": validateChurnResults(measurementsPath)
  of "profile": validateProfileResults(measurementsPath)
  else:
    validateCoreResults(measurementsPath)
    validateCoreManifest(resultDir)
  echo fmt"validated {measurementsPath}"

when isMainModule: main()
