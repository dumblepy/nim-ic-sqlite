import std/[json, options, strutils, unittest]
import ../shared/bench_report

suite "comparison measurement format":
  test "CSV has all required columns and quotes text safely":
    var measurement = Measurement(runId: "run,1", implementation: "nim", repoSha: "a",
      wasmSha256: "b", scenario: "C02", phase: "seed", errorKind: "",
      trial: 1, cycle: 0, rows: 1_000, success: true, instructionWindow: iwCore,
      instructionsUpdate: some(42'u64))
    let row = measurement.toCsvRow()
    check MeasurementCsvHeader.split(',').len == 26
    check row.startsWith("\"run,1\"")

  test "JSON preserves unavailable values as null":
    let measurement = Measurement(runId: "run-1", implementation: "nim", repoSha: "a",
      wasmSha256: "b", scenario: "C04", phase: "read", errorKind: "not_available",
      success: false, instructionWindow: iwQuery)
    let encoded = measurement.toJson()
    check encoded["instructions_update"].kind == JNull
    check encoded["instructions_query"].kind == JNull
    check encoded["raw_stable_pages"].kind == JNull
    check encoded["heap_bytes"].kind == JNull
    check encoded["success"].getBool == false

  test "growth and ratios do not hide invalid baselines":
    check rawGrowthPages(10, 14) == 4
    check rawGrowthPages(10, 9) == 0
    check ratioOrNone(10, 0).isNone
    check ratioOrNone(10, 4).get == 2.5
