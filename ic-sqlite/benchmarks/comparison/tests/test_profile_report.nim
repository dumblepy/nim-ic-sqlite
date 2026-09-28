import std/[json, unittest]
import nicp_cdk/ic_types/candid_types
import nicp_cdk/ic_types/ic_record except `%`, `%*`
import ../shared/profile_report

proc record(fields: openArray[(string, uint64)]): CandidRecord =
  result = CandidRecord(kind: ckRecord)
  for (name, value) in fields:
    result[name] = newCandidNat64(value)

suite "common profile artifact":
  test "keeps common fields separate from implementation details":
    let report = record([("rows", 3'u64), ("instructions", 10'u64), ("checksum", 75'u64),
      ("db_size", 16384'u64), ("stable_pages", 2'u64), ("stable_bytes", 131072'u64)])
    let host = record([("raw_stable_pages", 4'u64), ("raw_stable_bytes", 262144'u64)])
    var measurement = profileMeasurement("nim", "read", "run-1", report, host)
    measurement.details["stable_read_calls"] = %2
    let encoded = measurement.toJson()
    check encoded["instructions"].getBiggestInt() == 10
    check encoded["raw_stable_pages"].getBiggestInt() == 4
    check encoded["details"]["stable_read_calls"].getBiggestInt() == 2
