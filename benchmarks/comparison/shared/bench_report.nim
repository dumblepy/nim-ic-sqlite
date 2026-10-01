## Unit-explicit result model. `none` means unavailable, never zero by assumption.
import std/[json, options, sequtils, strutils]

type
  InstructionWindow* = enum
    iwCore, iwLegacy, iwQuery
  Measurement* = object
    runId*, implementation*, repoSha*, wasmSha256*, scenario*, phase*, errorKind*: string
    trial*, cycle*: uint32
    rows*, dbSize*, sqlitePageSize*, sqlitePageCount*, sqliteFreelistCount*: uint64
    sqliteVirtualPages*, rowCount*, valueChecksum*: uint64
    rawStablePages*, rawStableBytes*, rawGrowthPages*: Option[uint64]
    dirtyPagesPeak*, heapBytes*: Option[uint64]
    instructionsUpdate*, instructionsQuery*: Option[uint64]
    success*: bool
    instructionWindow*: InstructionWindow

const MeasurementCsvHeader* = "run_id,implementation,repo_sha,wasm_sha256,scenario,trial,cycle,phase,rows,success,error_kind,instructions_update,instructions_query,db_size,sqlite_page_size,sqlite_page_count,sqlite_freelist_count,sqlite_virtual_pages,raw_stable_pages,raw_stable_bytes,raw_growth_pages,dirty_pages_peak,heap_bytes,row_count,value_checksum,instruction_window"

proc csvEscape(value: string): string =
  if value.contains(',') or value.contains('"') or value.contains('\n') or value.contains('\r'):
    '"' & value.replace("\"", "\"\"") & '"'
  else:
    value

proc optionalNumber(value: Option[uint64]): string =
  if value.isSome: $value.get else: ""

proc toCsvRow*(measurement: Measurement): string =
  [measurement.runId, measurement.implementation, measurement.repoSha,
   measurement.wasmSha256, measurement.scenario, $measurement.trial,
   $measurement.cycle, measurement.phase, $measurement.rows, $measurement.success,
   measurement.errorKind, optionalNumber(measurement.instructionsUpdate),
   optionalNumber(measurement.instructionsQuery), $measurement.dbSize,
   $measurement.sqlitePageSize, $measurement.sqlitePageCount,
   $measurement.sqliteFreelistCount, $measurement.sqliteVirtualPages,
   optionalNumber(measurement.rawStablePages), optionalNumber(measurement.rawStableBytes),
   optionalNumber(measurement.rawGrowthPages), optionalNumber(measurement.dirtyPagesPeak),
   optionalNumber(measurement.heapBytes), $measurement.rowCount, $measurement.valueChecksum,
   $measurement.instructionWindow].mapIt(csvEscape(it)).join(",")

proc putOptional(node: JsonNode; key: string; value: Option[uint64]) =
  node[key] = if value.isSome: newJInt(int64(value.get)) else: newJNull()

proc toJson*(measurement: Measurement): JsonNode =
  result = newJObject()
  result["run_id"] = newJString(measurement.runId)
  result["implementation"] = newJString(measurement.implementation)
  result["repo_sha"] = newJString(measurement.repoSha)
  result["wasm_sha256"] = newJString(measurement.wasmSha256)
  result["scenario"] = newJString(measurement.scenario)
  result["trial"] = newJInt(int64(measurement.trial))
  result["cycle"] = newJInt(int64(measurement.cycle))
  result["phase"] = newJString(measurement.phase)
  result["rows"] = newJInt(int64(measurement.rows))
  result["success"] = newJBool(measurement.success)
  result["error_kind"] = newJString(measurement.errorKind)
  result.putOptional("instructions_update", measurement.instructionsUpdate)
  result.putOptional("instructions_query", measurement.instructionsQuery)
  result["db_size"] = newJInt(int64(measurement.dbSize))
  result["sqlite_page_size"] = newJInt(int64(measurement.sqlitePageSize))
  result["sqlite_page_count"] = newJInt(int64(measurement.sqlitePageCount))
  result["sqlite_freelist_count"] = newJInt(int64(measurement.sqliteFreelistCount))
  result["sqlite_virtual_pages"] = newJInt(int64(measurement.sqliteVirtualPages))
  result.putOptional("raw_stable_pages", measurement.rawStablePages)
  result.putOptional("raw_stable_bytes", measurement.rawStableBytes)
  result.putOptional("raw_growth_pages", measurement.rawGrowthPages)
  result.putOptional("dirty_pages_peak", measurement.dirtyPagesPeak)
  result.putOptional("heap_bytes", measurement.heapBytes)
  result["row_count"] = newJInt(int64(measurement.rowCount))
  result["value_checksum"] = newJInt(int64(measurement.valueChecksum))
  result["instruction_window"] = newJString($measurement.instructionWindow)

proc rawGrowthPages*(initial, current: uint64): uint64 {.inline.} =
  if current >= initial: current - initial else: 0'u64

proc ratioOrNone*(numerator, denominator: uint64): Option[float64] =
  if denominator == 0: none(float64) else: some(float64(numerator) / float64(denominator))
