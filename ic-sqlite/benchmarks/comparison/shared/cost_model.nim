## A transparent estimate from a dated official rate snapshot, never a measured charge.
type
  CycleRates* = object
    subnetNodes*: uint64
    updateBaseCyclesPerMessage*: uint64
    instructionCyclesPerInstruction*: uint64
    storageCyclesPerGiBSecond*: uint64

proc estimateUpdateCycles*(rates: CycleRates; messages, instructions: uint64): uint64 =
  rates.updateBaseCyclesPerMessage * messages +
    rates.instructionCyclesPerInstruction * instructions

proc estimateStableStorageCycles*(rates: CycleRates; rawStableBytes,
                                   seconds: uint64): float64 =
  ## Heap, ingress, storage reservation, and compute allocation are excluded.
  float64(rawStableBytes) / float64(1024'u64 * 1024 * 1024) *
    float64(rates.storageCyclesPerGiBSecond) * float64(seconds)

proc scaleCyclesForNodes*(cycles: float64; baselineNodes, nodes: uint64): float64 =
  ## Scale the final estimate as a rational factor to avoid fee rounding.
  if baselineNodes == 0: raise newException(ValueError, "baseline node count must be positive")
  if nodes == 0: raise newException(ValueError, "subnet node count must be positive")
  cycles * float64(nodes) / float64(baselineNodes)
