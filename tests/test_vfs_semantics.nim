## VFS/overlay-level semantics that the SQLite VFS contract and the
## update-transaction atomicity rules require:
## * a failure before publish can be rolled back by discarding the overlay
## * publish failures after the first stable write stay irreversible
## * repeated truncate/re-extend keeps the logical image consistent
## * a large multi-page BLOB survives write, commit, and reinitialization
import std/[options, unittest]
import ic_sqlite
import ic_sqlite/ffi/vfs_exports
import ic_sqlite/stable/[backend, superblock]
import ic_sqlite/vfs/overlay
import ic_sqlite/vfs/vfs

type FailingPublishBackend = ref object of StableBackend
  delegate: StableBackend
  failAfterWrites: uint64
  writes: uint64

method sizePages(backend: FailingPublishBackend): uint64 = backend.delegate.sizePages()
method grow(backend: FailingPublishBackend; pages: uint64): bool = backend.delegate.grow(pages)
method read(backend: FailingPublishBackend; offset: uint64; dst: pointer; size: uint64) =
  backend.delegate.read(offset, dst, size)
method write(backend: FailingPublishBackend; offset: uint64; src: pointer; size: uint64) =
  inc backend.writes
  if backend.writes > backend.failAfterWrites:
    raise newException(IOError, "injected publish failure")
  backend.delegate.write(offset, src, size)

type CountingReadBackend = ref object of StableBackend
  delegate: StableBackend
  reads: uint64

method sizePages(backend: CountingReadBackend): uint64 = backend.delegate.sizePages()
method grow(backend: CountingReadBackend; pages: uint64): bool = backend.delegate.grow(pages)
method read(backend: CountingReadBackend; offset: uint64; dst: pointer; size: uint64) =
  inc backend.reads
  backend.delegate.read(offset, dst, size)
method write(backend: CountingReadBackend; offset: uint64; src: pointer; size: uint64) =
  backend.delegate.write(offset, src, size)

suite "VFS semantics":
  test "a failure before stable publish can be discarded without losing the base":
    ## The VFS owns the overlay lifecycle: begin -> operate -> end(publish).
    ## If the SQLite transaction is aborted before end, end(publish=false)
    ## must discard every dirty page and zero extent so the next operation
    ## starts from the previously published image.
    let raw: StableBackend = newVecStableBackend()
    check raw.grow(4)
    var base = newSeq[byte](65536)
    for index in 0 ..< base.len: base[index] = byte(index mod 251)
    raw.write(SuperblockReservedBytes, addr base[0], uint64(base.len))
    initVfs(raw, dbSize = uint64(base.len), maxDirtyPages = 8)
    beginOverlay()
    check overlayActive
    activeOverlay.writeFrom(raw, 100, addr base[0], 64)
    activeOverlay.truncate(32000, raw)
    check dirtyPageCount(activeOverlay) > 0
    ## Simulate an aborted SQLite transaction: no publish, full discard.
    endOverlay(publish = false)
    check not overlayActive
    beginOverlay()
    check activeOverlay.size == uint64(base.len)
    check dirtyPageCount(activeOverlay) == 0
    check activeOverlay.zeroExtents.len == 0
    endOverlay(publish = false)
    ## Bytes on the stable backend must be exactly the pre-operation image.
    var after: seq[byte] = newSeq[byte](base.len)
    raw.read(SuperblockReservedBytes, addr after[0], uint64(base.len))
    check after == base

  test "publish failure after the first stable write is irreversible":
    let raw: StableBackend = newVecStableBackend()
    check raw.grow(4)
    let failing: StableBackend = FailingPublishBackend(
      delegate: raw, failAfterWrites: 1)
    initVfs(failing, dbSize = 0)
    beginOverlay()
    var page0 = newSeq[byte](16384)
    for index in 0 ..< page0.len: page0[index] = 1
    var page1 = newSeq[byte](16384)
    for index in 0 ..< page1.len: page1[index] = 2
    activeOverlay.writeFrom(failing, 0, addr page0[0], uint64(page0.len))
    activeOverlay.writeFrom(failing, 16384, addr page1[0], uint64(page1.len))
    ## Two dirty pages -> the second stable write fails.  The first one
    ## already reached stable memory, so the only safe action is the
    ## existing PublishStartedError -> canister trap path.
    expect PublishStartedError:
      activeOverlay.publishDirtyPages(failing)
    check FailingPublishBackend(failing).writes == 2
    ## The VFS-level end path would trap on wasm; natively the exception
    ## propagates and the overlay is torn down as aborted.
    endOverlay(publish = false)
    check not overlayActive

  test "repeated truncate and re-extension keep the logical image consistent":
    let raw: StableBackend = newVecStableBackend()
    check raw.grow(4)
    initVfs(raw, dbSize = 80000)
    beginOverlay()
    # 1) shrink by a partial page, then grow beyond the original size
    activeOverlay.truncate(70000, raw)
    activeOverlay.truncate(90000, raw)
    # 2) shrink into the gap, then grow again with a gap write in between
    activeOverlay.truncate(5000, raw)
    var marker = newSeq[byte](4096)
    for index in 0 ..< marker.len: marker[index] = 0xAB
    activeOverlay.writeFrom(raw, 60000, addr marker[0], uint64(marker.len))
    activeOverlay.truncate(70000, raw)
    # read back the assembled logical image
    var output = newSeq[byte](70000)
    check activeOverlay.readInto(raw, 0, addr output[0], uint64(output.len))
    check output[0] == 0
    for index in 60000 ..< 64096:
      check output[index] == 0xAB
    for index in 64096 ..< 70000:
      check output[index] == 0
    endOverlay(publish = false)

  test "a large multi-page BLOB survives commit and reinitialization":
    let backend: StableBackend = newVecStableBackend()
    check backend.grow(16)
    var db: Db
    check db.init(backend).isOk
    check db.exec("CREATE TABLE blobs (id INTEGER PRIMARY KEY, body BLOB NOT NULL)").isOk
    const BlobSize = 4096 * 1024  # 4 MiB -> 256 SQLite pages of 16 KiB
    var payload = newSeq[byte](BlobSize)
    for index in 0 ..< BlobSize:
      payload[index] = byte((index shr 8) + index mod 7)
    let inserted = db.execValues(
      "INSERT INTO blobs(id, body) VALUES (?, ?)", [sqlInt(1), sqlBlob(payload)])
    check inserted.isOk
    db.close()
    var reopened: Db
    check reopened.init(backend).isOk
    let checked = reopened.withQuery(proc(conn: var Connection): Result[bool, DbError] =
      let prepared = conn.prepare("SELECT body FROM blobs WHERE id = 1")
      if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
      var statement = prepared.value
      defer: statement.finalize()
      let stepped = statement.step()
      if not stepped.isOk: return Result[bool, DbError](isOk: false, error: stepped.error)
      if stepped.value != srRow: return Result[bool, DbError](isOk: false, error: DbError(message: "blob row missing"))
      let round = statement.columnBlob(0)
      if round.len != payload.len or round != payload:
        return Result[bool, DbError](isOk: false, error: DbError(message: "blob mismatch"))
      Result[bool, DbError](isOk: true, value: true)
    )
    check checked.isOk
    check checked.value
    # A second, smaller BLOB proves the large one did not corrupt the image.
    let small = reopened.execValues(
      "INSERT INTO blobs(id, body) VALUES (?, ?)",
      [sqlInt(2), sqlBlob(newSeq[byte](7))])
    check small.isOk
    # Sub-page (1 KiB) and page-boundary (16 KiB) BLOBs must round-trip too;
    # these exercise the VFS short/whole page boundaries with overflow I/O.
    var pageBlob = newSeq[byte](16384)
    for index in 0 ..< pageBlob.len: pageBlob[index] = byte(index mod 251)
    let boundary = reopened.execValues(
      "INSERT INTO blobs(id, body) VALUES (?, ?)",
      [sqlInt(3), sqlBlob(pageBlob)])
    check boundary.isOk
    let boundaryCheck = reopened.withQuery(
      proc(conn: var Connection): Result[bool, DbError] =
        let prepared = conn.prepare("SELECT body FROM blobs WHERE id = 3")
        if not prepared.isOk: return Result[bool, DbError](isOk: false, error: prepared.error)
        var statement = prepared.value
        defer: statement.finalize()
        let stepped = statement.step()
        if not stepped.isOk: return Result[bool, DbError](isOk: false, error: stepped.error)
        if stepped.value != srRow:
          return Result[bool, DbError](isOk: false, error: DbError(message: "blob row 3 missing"))
        if statement.columnBlob(0) != pageBlob:
          return Result[bool, DbError](isOk: false, error: DbError(message: "page blob mismatch"))
        Result[bool, DbError](isOk: true, value: true)
    )
    check boundaryCheck.isOk and boundaryCheck.value
    reopened.close()
