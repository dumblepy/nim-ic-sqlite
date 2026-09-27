import std/unittest
import ../shared/cost_model

suite "cost estimate arithmetic":
  let rates = CycleRates(subnetNodes: 13, updateBaseCyclesPerMessage: 5_000_000,
    instructionCyclesPerInstruction: 1, storageCyclesPerGiBSecond: 127_000)
  test "update base fee and instructions are separate":
    check rates.estimateUpdateCycles(2, 3_000_000) == 13_000_000
  test "one GiB-day uses the dated stable storage rate":
    check rates.estimateStableStorageCycles(1024'u64 * 1024 * 1024, 86_400) == 10_972_800_000.0
  test "subnet scaling retains the 13-node baseline":
    check scaleCyclesForNodes(13_000_000.0, 13, 13) == 13_000_000.0
    check scaleCyclesForNodes(13_000_000.0, 13, 34) == 34_000_000.0
