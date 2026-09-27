import std/unittest
import ic_sqlite
import ic_sqlite/stable/backend

suite "bounded stable region isolation":
  test "SQLite writes do not change another owner's prefix":
    let raw = newVecStableBackend()
    check raw.grow(4)
    let sentinel = [byte 0x4D, 0x47, 0x52, 0x01, 0xA5]
    raw.write(0, unsafeAddr sentinel[0], uint64(sentinel.len))
    let region: StableBackend = newRegionStableBackend(raw,
      StableRegion(baseOffset: 2 * StablePageSize, maxBytes: 2 * StablePageSize))
    var database: Db
    check database.init(region).isOk
    check database.exec("CREATE TABLE isolated (key TEXT PRIMARY KEY, value TEXT)").isOk
    check database.execText("INSERT INTO isolated(key, value) VALUES (?, ?)", ["a", "b"]).isOk
    database.close()
    var after: array[5, byte]
    raw.read(0, addr after[0], uint64(after.len))
    check after == sentinel
    var byteValue: byte
    expect ValueError:
      region.read(2 * StablePageSize, addr byteValue, 1)
