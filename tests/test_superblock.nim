import std/[options, unittest]
import nicp_cdk/storage/stable_backend
import ic_sqlite/stable/superblock

suite "Superblock":
  let original = Superblock(formatVersion: SuperblockFormatVersion, sqlitePageSize: 16384,
    dbSize: 81920, schemaVersion: 7, lastTxId: 9, flags: 3, dbChecksum: 42,
    zeroExtents: @[ZeroExtent(startPage: 2, endPage: 4)])
  test "uses fixed LE encoding and round-trips all fields":
    let decoded = decodeSuperblock(encodeSuperblock(original))
    check decoded.isOk
    check decoded.value == original
  test "rejects foreign and checksum-corrupted images":
    var foreign = encodeSuperblock(original)
    foreign[0] = byte(ord('X'))
    check not decodeSuperblock(foreign).isOk
    var corrupt = encodeSuperblock(original)
    corrupt[16] = corrupt[16] xor 1
    check not decodeSuperblock(corrupt).isOk
  test "distinguishes fresh memory from foreign memory":
    let storage: StableBackend = newVecStableBackend()
    check readExistingSuperblock(storage).value.isNone
    check storage.grow(1)
    check readExistingSuperblock(storage).value.isNone
    var foreign = [byte 1, 2, 3, 4, 5, 6, 7, 8]
    storage.write(0, addr foreign[0], uint64(foreign.len))
    check not readExistingSuperblock(storage).isOk

  test "persists database size and transaction metadata in stable storage":
    let storage: StableBackend = newVecStableBackend()
    check storage.grow(1)
    let encoded = encodeSuperblock(original)
    storage.write(0, unsafeAddr encoded[0], uint64(encoded.len))
    let restored = readExistingSuperblock(storage)
    check restored.isOk
    check restored.value.isSome
    check restored.value.get.dbSize == 81920
    check restored.value.get.lastTxId == 9
