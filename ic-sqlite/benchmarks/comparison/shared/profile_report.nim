## Common profile artifact fields. Implementation-specific counters stay in
## `details` and are never treated as cross-implementation values.
import std/json
import nicp_cdk/ic_types/candid_types
import nicp_cdk/ic_types/ic_record except `%`, `%*`

type ProfileMeasurement* = object
  implementation*, profile*, runId*: string
  rows*, instructions*, checksum*, dbSize*, stablePages*, stableBytes*: uint64
  rawStablePages*, rawStableBytes*: uint64
  details*: JsonNode

proc profileMeasurement*(implementation, profile, runId: string;
                         report, host: CandidRecord): ProfileMeasurement =
  result.implementation = implementation
  result.profile = profile
  result.runId = runId
  result.rows = report["rows"].getNat64()
  result.instructions = report["instructions"].getNat64()
  result.checksum = report["checksum"].getNat64()
  result.dbSize = report["db_size"].getNat64()
  result.stablePages = report["stable_pages"].getNat64()
  result.stableBytes = report["stable_bytes"].getNat64()
  result.rawStablePages = host["raw_stable_pages"].getNat64()
  result.rawStableBytes = host["raw_stable_bytes"].getNat64()
  result.details = newJObject()

proc toJson*(measurement: ProfileMeasurement): JsonNode =
  result = %*{
    "implementation": measurement.implementation,
    "profile": measurement.profile,
    "run_id": measurement.runId,
    "rows": measurement.rows,
    "instructions": measurement.instructions,
    "checksum": measurement.checksum,
    "db_size": measurement.dbSize,
    "stable_pages": measurement.stablePages,
    "stable_bytes": measurement.stableBytes,
    "raw_stable_pages": measurement.rawStablePages,
    "raw_stable_bytes": measurement.rawStableBytes
  }
  result["details"] = measurement.details
