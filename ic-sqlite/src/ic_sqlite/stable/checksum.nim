## Non-cryptographic corruption detection for stable-memory metadata.

const Fnv1a64OffsetBasis* = 14695981039346656037'u64
const Fnv1a64Prime* = 1099511628211'u64

proc fnv1a64*(data: openArray[byte]): uint64 =
  result = Fnv1a64OffsetBasis
  for value in data:
    result = (result xor uint64(value)) * Fnv1a64Prime
