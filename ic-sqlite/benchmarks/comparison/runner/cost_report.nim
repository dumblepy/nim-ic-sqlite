## Explicit scenario estimate from observed churn and a dated rate snapshot.
## Usage: nim c -r runner/cost_report.nim <results/churn-run-id>
import std/[algorithm, json, os]
import ../shared/cost_model

const PricingPath = "/application/ic-sqlite/benchmarks/comparison/pricing_2026-09-27.json"

type Series = object
  deleteInstructions: array[100, uint64]
  insertInstructions: array[100, uint64]
  deleteSeen: array[100, bool]
  insertSeen: array[100, bool]
  resetSeen: bool
  updateInstructionsTotal: uint64
  maxRawBytes: uint64
  maxHeapBytes: uint64
  firstRawBytes: uint64
  lastRawBytes: uint64
  rowsObserved: uint64

proc median(values: var seq[uint64]): uint64 =
  values.sort()
  (values[49] + values[50]) div 2

proc main() =
  if paramCount() != 1: raise newException(ValueError, "pass one completed churn results directory")
  let resultDir = paramStr(1)
  let pricing = parseFile(PricingPath)
  let rates = CycleRates(subnetNodes: pricing["subnet_nodes"].getBiggestInt().uint64,
    updateBaseCyclesPerMessage: pricing["update_base_cycles_per_message"].getBiggestInt().uint64,
    instructionCyclesPerInstruction: pricing["instruction_cycles_per_instruction"].getBiggestInt().uint64,
    storageCyclesPerGiBSecond: pricing["storage_cycles_per_gib_second"].getBiggestInt().uint64)
  var nim, rust: Series
  for line in lines(resultDir / "measurements.jsonl"):
    if line.len == 0: continue
    let row = parseJson(line)
    if not row["success"].getBool(): raise newException(ValueError, "failed churn step cannot be costed")
    let implementation = row["implementation"].getStr()
    let current = if implementation == "nim": addr nim else: addr rust
    let cycle = int(row["cycle"].getBiggestInt())
    let phase = row["phase"].getStr()
    let instructions = uint64(row["instructions_update"].getBiggestInt())
    let raw = uint64(row["raw_stable_bytes"].getBiggestInt())
    if row["heap_bytes"].kind != JNull:
      current.maxHeapBytes = max(current.maxHeapBytes, uint64(row["heap_bytes"].getBiggestInt()))
    current.rowsObserved += 1
    current.updateInstructionsTotal += instructions
    if current.firstRawBytes == 0: current.firstRawBytes = raw
    current.lastRawBytes = raw
    current.maxRawBytes = max(current.maxRawBytes, raw)
    case phase
    of "reset":
      if current.resetSeen: raise newException(ValueError, "duplicate reset")
      current.resetSeen = true
    of "delete":
      if cycle < 0 or cycle >= 100 or current.deleteSeen[cycle]: raise newException(ValueError, "invalid delete step")
      current.deleteInstructions[cycle] = instructions
      current.deleteSeen[cycle] = true
    of "insert":
      if cycle < 0 or cycle >= 100 or current.insertSeen[cycle]: raise newException(ValueError, "invalid insert step")
      current.insertInstructions[cycle] = instructions
      current.insertSeen[cycle] = true
    else: raise newException(ValueError, "unexpected churn phase")
  var output = newJObject()
  output["pricing"] = pricing
  output["scenario"] = %*{
    "description": "retain 5000 rows and perform one 1000-row delete/insert churn cycle per day for 30 days",
    "days": 30, "subnet_nodes": rates.subnetNodes,
    "storage_assumption": "observed maximum raw stable bytes held for all 30 days",
    "heap_bytes": "derived from canister_status.memory_size minus raw stable memory when available",
    "cycles_metrics": "not_available"
  }
  for implementation in ["nim", "rust"]:
    let current = if implementation == "nim": addr nim else: addr rust
    if not current.resetSeen or current.rowsObserved != 201:
      raise newException(ValueError, implementation & " has missing churn rows")
    var cycleInstructions: seq[uint64]
    for cycle in 0 ..< 100:
      if not current.deleteSeen[cycle] or not current.insertSeen[cycle]:
        raise newException(ValueError, implementation & " has missing churn cycle")
      cycleInstructions.add(current.deleteInstructions[cycle] + current.insertInstructions[cycle])
    let medianCycle = median(cycleInstructions)
    let updateCycles = rates.estimateUpdateCycles(60, 30'u64 * medianCycle)
    let storageCycles = rates.estimateStableStorageCycles(current.maxRawBytes, 30'u64 * 86_400)
    let heapCycles = if current.maxHeapBytes == 0: 0.0
      else: rates.estimateStableStorageCycles(current.maxHeapBytes, 30'u64 * 86_400)
    output[implementation] = %*{
      "observed_churn_update_instructions_total": current.updateInstructionsTotal,
      "median_cycle_instructions": medianCycle,
      "raw_stable_bytes_initial": current.firstRawBytes,
      "raw_stable_bytes_final": current.lastRawBytes,
      "raw_stable_bytes_high_water": current.maxRawBytes,
      "heap_bytes_high_water": if current.maxHeapBytes == 0: newJNull() else: %current.maxHeapBytes,
      "estimated_30d_update_cycles": updateCycles,
      "estimated_30d_stable_storage_cycles": storageCycles,
      "estimated_30d_heap_storage_cycles": heapCycles,
      "estimated_30d_subtotal_excluding_other_fees": float64(updateCycles) + storageCycles + heapCycles,
      "sensitivity_34_node_subtotal_cycles": scaleCyclesForNodes(float64(updateCycles) + storageCycles + heapCycles, 13, 34)
    }
  writeFile(resultDir / "cost_estimate.json", output.pretty())
  var summary = readFile(resultDir / "summary.md")
  summary.add("\n## 30-day scenario estimate (13-node rate snapshot)\n\n")
  summary.add("Rates: " & pricing["source"].getStr() & " (retrieved " & pricing["retrieved_utc"].getStr() & ").\n\n")
  summary.add("| Implementation | Update cycles | Stable storage cycles | Heap storage cycles | Subtotal cycles |\n|---|---:|---:|---:|---:|\n")
  for implementation in ["nim", "rust"]:
    let row = output[implementation]
    summary.add("| " & implementation & " | " & $row["estimated_30d_update_cycles"].getBiggestInt() &
      " | " & $row["estimated_30d_stable_storage_cycles"].getFloat() &
      " | " & $row["estimated_30d_heap_storage_cycles"].getFloat() &
      " | " & $row["estimated_30d_subtotal_excluding_other_fees"].getFloat() & " |\n")
  summary.add("\nAssumes one 1000-row delete/insert cycle daily and holds the observed maximum raw stable bytes for 30 days. " &
    "Heap is included only when canister status memory_size was available; ingress, storage reservation, and other fees are excluded. Local query instruction counts are excluded.\n")
  writeFile(resultDir / "summary.md", summary)
  echo resultDir / "cost_estimate.json"

when isMainModule: main()
