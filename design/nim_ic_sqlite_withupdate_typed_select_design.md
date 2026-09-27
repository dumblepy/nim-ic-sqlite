# `withUpdate()` 内の型付き SELECT — `1-method-chain` ブランチ対応設計書

- 対象: [`dumblepy/nim-ic-sqlite` / `1-method-chain`](https://github.com/dumblepy/nim-ic-sqlite/tree/1-method-chain)
- 調査対象コミット: [`f1ba4079f800ec5fd8602465e799eaa379f5800f`](https://github.com/dumblepy/nim-ic-sqlite/tree/f1ba4079f800ec5fd8602465e799eaa379f5800f)（コミット日時 2026-09-27 07:26:55 UTC）
- 比較元: [`humandebri/ic-sqlite-vfs` / `1386239acff1dd7ede5ac78a2f0a22ef495195de`](https://github.com/humandebri/ic-sqlite-vfs/tree/1386239acff1dd7ede5ac78a2f0a22ef495195de)
- 文書改訂: 2026-09-27、v2。前版の「対象ブランチにQuery AST/Typed Readerが存在しない」という記述は誤りであり、本版で訂正した。
- 状態: **ソース調査および実装設計**。この文書作成に伴うリポジトリ変更、Nimコンパイル、テスト実行はしていない。過去の実験で「同じraw handleでも0行」になった真因は未特定。

## 1. 結論

`1-method-chain` には、実行経路を選択する材料が既にある。`Query` は `owner: ptr Db` **だけでなく** `updateOwner: ptr UpdateConnection` も持つ。`table(conn)` は両方を設定し、`executeWrite()` は `updateOwner` があればトランザクション用 `conn.execValues()` を呼ぶ。一方、`get(T)` は `updateOwner` を参照せず、常に `readRows[T](q.owner[], ...)` に渡す。`readRows()` は無条件に `db.withQuery()` を使う。**既存実装で確認できる直接原因は、この非対称なread dispatcher** である。[N1][N2]

最小機能修正は `get/first` を更新用同一接続の型付きread executorにルーティングすること。ただし、既存 `updateOwner` は `withUpdate` 内の**スタック変数を指す生ポインタ**なので、body外へ逃げるQueryの安全性を確保できない。採用案は、既存ASTとSQL compilerを温存し、更新の間だけ有効な共有 **`TransactionLease`**（参照オブジェクト／capability）に置き換えること。既存の `prepare/bind/step/decodeRow/finalize` を共通scannerとして抽出し、通常readerとtransaction readerで共有する。[N1][N2][N3]

**通常の `Db.withQuery()` は更新接続へ転用しない。** Rust版の原則も、更新用 `UpdateConnection` の `&Connection` でSELECTを実行し、独立したread-only connectionは通常Queryに限る、というもの。[R1][R2][R3]

## 2. `1-method-chain` の実装確認（mainではない）

| 対象 | 現行の事実 | 重要な行 |
|---|---|---|
| `query_builder.nim` | `Query.owner` と `Query.updateOwner` を保持。`table(db)` はownerのみ、`table(conn)` は両方を設定。ASTの `where/select/orderBy` 等は `result = q` で元情報をコピーする。 | [L31–46, L63–67, L69–146][N1] |
| `Query.get` | `compile()` の後、無条件に `readRows[T](q.owner[], sql, params)`。更新用read分岐がない。 | [L258–262][N1] |
| `Query.first` | `q.get(T)` で**全件を取得**し、先頭要素だけ返す。`LIMIT 1`相当の短絡は未実装。 | [L264–267][N1] |
| 型付き書込み | `executeWrite` は `updateOwner != nil` なら `UpdateConnection.execValues` を使用し、通常のDb書込みと経路を分けている。 | [L272–275][N1] |
| `typed.nim` | `readRows` は `db.withQuery` の内側でprepare/bind/step/decodeし、列名・型・NULL・結果行数/bytes/paramsを検査する。`defer: statement.finalize()` あり。 | [L22–139][N2] |
| `db.nim` | `UpdateConnection` は `db: ptr Db` だけを保持。`Connection` は `(db, raw)` を保持。`withUpdate` は `BEGIN IMMEDIATE`、`Result`エラー・`CatchableError`ならrollback、成功時COMMIT→overlay publish。 | [L38–54, L469–502][N3] |
| 通常Query | native `:memory:` は同じrawに一時的に `PRAGMA query_only=ON`、stableは別のread-only SQLite接続を開く。 | [L339–369][N3] |
| statement | `Connection.prepare`、`Statement.bind/step/finalize`、`isReadonly`、`queryLimits`、TEXT/BLOB長さ付きコピーが**実装済み**。前版にあった「TEXTがcstring終端で切れる」という指摘は、このブランチには当てはまらない。 | [L371–467][N3] |
| テスト | `test_query_transaction.nim` は更新内複数INSERT、rollbackと例外rollbackを検証するが、**更新内型付きSELECTをまだ検証しない**。`test_query_stable.nim` はclose/reopen後の型付き読取りを検証。 | [N4][N5] |
| 進捗 | Phase 1–4完了、Phase 5は同一トランザクション内SELECTが未達、というブランチ記録。 | [N6] |

`main` との差分には `query_builder.nim`、`typed.nim`、各種typed/queryテストが追加されている。したがって **Query ASTやTyped Readerを新規設計し直す必要はない**。[N1][N2]

## 3. Rust原実装の方式と移植すべき要点

### 3.1 更新readerはwrite connectionに属する

Rustの `DbHandle::update` は `reject_active_read_connection`、read-cacheの無効化、`stable_blob::begin_update`、`write_connection` の取得を行い、`transaction::run_immediate(&connection, f)` を実行する。`UpdateConnection<'connection>` は `&'connection Connection` を保持し、`Deref<Target=Connection>` を実装するので、`connection.query_one/query_optional/query_all/prepare` は**更新トランザクションを持つ同一Connection上で実行**される。新たにread-only接続を生成しない。[R1][R2][R3]

`run_immediate` は `BEGIN → closure → COMMIT → stable_blob::commit_update()`、エラー時は `ROLLBACK → stable_blob::rollback_update()` を行う。Nim側の `BEGIN IMMEDIATE` をRustの `BEGIN` に揃える必要はない。本件で重要なのは接続同一性と処理順である。[R2]

### 3.2 通常readerは別系統、復号器は共通

Rustの `DbHandle::query` は `with_read_connection` を選び、`SQLITE_OPEN_READONLY` と `PRAGMA query_only=ON` を設定する。他方で `Connection::query_optional/query_all` は、どちらのConnectionでも同じ `Statement`、`Rows`、`Row::get<T>` を利用する。`query_all` はループ内で毎行 `output.push(...)` し、`query_optional` は最初の行で値、なければ `None` を返す。statementは `Drop` でfinalizeされる。[R1][R3][R4][R5]

RustのVFSはファイルごとに `read_only` / `read_snapshot` を持ち、read-onlyファイルの `xRead` はコミット済みbaseを、writerの `xRead` はoverlay優先の経路を呼ぶ。この区別はSQLite接続の種類だけでなくVFSにもある。[R6][R7]

**Nimで再現する対象はRustのDeref構文ではなく、更新scope内の型付きreaderがwrite connectionを借用するという設計である。** RustにNimの同形Query Builderが実装されているという意味ではない。

## 4. 症状の原因と「同じraw handleでも0件」の切り分け

確認済みの経路は以下。

```text
UpdateConnection.table("items")
  -> Query(owner = db, updateOwner = addr conn)
  -> where(...).first(StoredItem)
  -> get()                              # updateOwner を見ない
  -> readRows(db, sql, params)
  -> Db.withQuery()
     ├─ native :memory: : db.raw に query_only=ON/OFF
     └─ stable VFS     : 新しい read-only sqlite3* を開く
  -> 更新トランザクションへの専用read経路を喪失
```

SQLite公式のisolation説明では、**同じ接続でSELECT開始前に完了したINSERT/UPDATEは未コミットでもSELECTから見える**。一般的な別接続では未コミット変更は見えない。したがってstable版の独立read接続経路はread-your-writesの手段ではない。[S1]

ただし**native `:memory:` の `withQuery` は実際には同じ `db.raw` を使う**。したがって、この枝で0行になる事実を「別ハンドルだから」だけで説明するのは不正確。`query_only` の切替え、INSERT結果を `discard` していること、試作時の実際のprepare先、compiler/bind、型付き結果蓄積を切り分けなければならない。`PRAGMA query_only` は更新を禁じる設定であり、未コミット行を意図的に消す仕組みではない。[N3][S2]

**raw-handle試作で0行だった原因はソースだけでは特定できない。** 次の診断順を必須とする。観測結果が出るまではVFSやSQLiteそのものの不具合と断定しない。

| 段階 | 同一 `sqlite3*` を使った検査 | 結果による分岐 |
|---|---|---|
| D0 | INSERTの `Result.isOk` / `sqlite3_changes` / rawアドレス、`sqlite3_get_autocommit()==0` を記録 | insert失敗、rollback済み、実際の接続不一致を先に除外。診断時は`discard insert`禁止 |
| D1 | `SELECT count(*) FROM items` をQuery BuilderもTyped Readerも通さず直接prepare/bind/step | 行が見えなければinsert/transaction/connectionを追う |
| D2 | `SELECT count(*) FROM items WHERE name = ?` を同じrawにbind | D1だけ成功なら値・bind位置・型・TEXT長・照合を追う |
| D3 | `q.compile().sql`、paramsの個数/型/順序をD1と同じ低レベルscannerへ渡す | D2だけ成功ならSQL compiler/Queryコピー/パラメータ順を追う |
| D4 | D3と同じprepared statementから `decodeRow(StoredItem)` する | D3だけ成功なら列名/型/Resultとseq蓄積を追う |
| D5 | 修正した `Query.get/first` を呼ぶ | `prepare` 先rawとstepの `SQLITE_ROW/DONE/error` を比較 |

診断用ログにはraw identity、`sqlite3_get_autocommit`、変更行数、**展開前SQL**、bind数/SQLite型、各stepの戻り値、集約件数を記録する。アプリの値本体・PIIを本番ログに出さない。SQLiteがエラー時にトランザクションを自動rollbackした可能性も調べる。[S3]

## 5. 推奨内部アーキテクチャ

### 5.1 経路を選ぶQuery、読取りを行う共通scanner

```text
Db.table(...): Query(updateScope=nil)
  └─ get/first ── Db.withQuery(...) ─────┐
                                          │
UpdateConnection.table(...):              │
  Query(updateScope=active lease)         │
  └─ get/first ── withUpdateQueryRead(...) ┤
                 (同じ db.raw を借用)      ▼
                          scanRowsOnConnection[T](Connection,
                            sql, params, firstOnly)
                             ├─ prepare / readonly確認 / count / bind
                             ├─ step / decodeRow / rowBytes / limits
                             └─ finalize (全経路)
```

`Query.compile`、Predicate、SQL bind設計、`decodeRow`、`readColumn` は原則そのまま残す。既存 `typed.nim` の `readRows` の中身を独立した `scanRowsOnConnection[T]` に抽出し、`Db.withQuery` は単なる通常実行wrapperとする。`UpdateConnection` 用に復号処理を複製しない。[N1][N2]

### 5.2 `updateOwner: ptr UpdateConnection` は共有leaseへ置換

現行 `table(conn)` は `addr conn` をQueryへ保存する。`conn` は `withUpdate` の局所変数なのでQueryをbody外にコピーするとポインタがダングリングする。`q.updateOwner.isNil` だけでは期限切れを検出できず、次回トランザクションのスタック番地が再利用される可能性もある。[N1][N3]

第一候補は、**毎回のBEGIN成功後に新しい `ref TransactionLease` を生成し、QueryとUpdateConnectionに共有させる**こと。次は設計上の擬似コードであり、Nimの実際の `Result` コンストラクタ等に合わせて調整する。

```nim
# db.nim（公開型を追加するならフィールドは非公開にする）
type
  TransactionLease* = ref object
    active: bool
    db: ptr Db                       # active時だけ参照可

  UpdateConnection* = object
    db: ptr Db
    lease: TransactionLease

  Db* = object
    # 既存フィールド...
    currentUpdate: TransactionLease  # nil または有効lease

# query_builder.nim
# 既存ownerは通常Query用として残してよい。
# updateOwner: ptr UpdateConnection は除去し、コピー安全な参照に置換。
type Query* = object
  owner: ptr Db
  updateScope: TransactionLease
  # 既存ASTの残り...

proc table*(conn: var UpdateConnection; name: string; alias = ""): Query =
  Query(owner: conn.ownerDb(), updateScope: conn.transactionLease(),
        tableName: name, tableAlias: alias)
```

`TransactionLease` の同一参照を `Query` の全派生物が保持するので、既存の `result=q` によるQueryコピーでも有効性情報を引き継げる。`withUpdate()` は**BEGIN成功後**にscopeを発行し、開始直後に `defer` で `lease.active=false; lease.db=nil; db.currentUpdate=nil` を登録する。Resultエラー、例外、COMMIT失敗、publish完了のすべてで無効化する。別のトランザクションでは必ず新たなrefを作り、失効したものを再度activeにしない。これによりtokenの数値衝突を避ける。

**検証時は有効性を調べる前に `q.owner` や旧 `updateOwner` をdereferenceしない。** `validateUpdateLease` は `lease!=nil && lease.active && lease.db!=nil && lease.db[].currentUpdate == lease && lease.db[].raw!=nil` を確認してから接続を借りる。`sqlite3_get_autocommit`（未実装ならFFIを追加）は診断および異常状態の補助検出に用いる。単独のautocommit判定だけをcapabilityとして使わない。

### 5.3 既存書込みもscope検査する

新しい `Query.executeWrite` は、`updateScope != nil` の場合、通常 `Db.execValues` へ**決してフォールバックしない**。scopeを検証した後で、既存 `UpdateConnection.execValues` の実行本体を抽出した `execValuesInTransaction(scope, sql, params)` へルーティングする。これによりstack pointer依存を読取りだけでなく書込みからも取り除く。`insertId` の `lastInsertId` も同じscopeへ結び付ける。[N1][N3]

差分を段階的に小さくする場合、第一パッチで現行 `updateOwner` を残し「共有leaseを検証したときだけ `updateOwner[]` を使用」、次のパッチでscope直接実行へ移行してもよい。ただし最終形は生のstack pointer非依存とする。

### 5.4 `db.nim` に追加するreader wrapper

```nim
# 説明用擬似コード。型/コンストラクタ/公開範囲は実装時に合わせる。
proc withUpdateQueryRead*[T](lease: TransactionLease;
    body: proc(conn: var Connection): Result[T, DbError] {.closure.}
  ): Result[T, DbError] =
  let valid = validateUpdateLease(lease)
  if not valid.isOk: return err[T](valid.error)
  var borrowed = Connection(db: lease.db, raw: lease.db[].raw)
  # Connectionはborrowed view。rawの所有者はDb。閉じない・query_onlyを設定しない。
  body(borrowed)
```

`UpdateConnection` のreader専用wrapperは **新しいSQLite接続/新しいoverlay/COMMIT/ROLLBACKを行わない**。`Statement` の `errorSource` は借用した正しいrawのままにする。`withUpdate` 本体の同期closure内で読取りを完結させ、statementやSQLite buffer pointerを外に返さない。[N3]

`Db.withQuery()` には `currentUpdate != nil && currentUpdate.active` の場合 `dekInvalidState` を返すguardを置く。native `:memory:` のwriter rawへ一時的にquery_onlyを入れないため、stable側の通常readerをoverlay読取りへ混入させないためである。合わせて、更新中に通常 `Db.exec/execText/execValues` を使ってtransaction境界を迂回しないよう入口を検証する。**更新中の操作は `UpdateConnection` 経由に限定**する。`withUpdate`のネストと`Db.close/init`の更新中実行も明示的に禁止/ガードする（closeがvoidの現APIなら変更方法は別途API互換性と合わせて決める）。[N3][N7]

### 5.5 `typed.nim` の具体的な抽出対象

現在の `readRows` の L101–140 を、接続選択とscannerに分ける。[N2]

```nim
# 説明用擬似コード: Resultの生成は実コードの規約に合わせる。
proc scanRowsOnConnection*[T](conn: var Connection; sql: string;
    params: openArray[SqlValue]; firstOnly: bool): Result[seq[T], DbError] =
  let prepared = conn.prepare(sql)
  if not prepared.isOk: return errorResult[seq[T]](prepared.error)
  var statement = prepared.value
  defer: statement.finalize()

  let limits = statement.queryLimits()
  # 既存のparameter数/placeholder数/readonly検査を移植
  # sqlite3_stmt_readonly だけをSQL文種別の完全なホワイトリストとみなさない
  for i, value in params:
    let b = statement.bind(i + 1, value)
    if not b.isOk: return errorResult[seq[T]](b.error)

  var output: seq[T] = @[]       # closureやResult暗黙resultへ蓄積しない
  var rowIndex = 0
  var totalBytes = 0'u64
  while true:
    let s = statement.step()
    if not s.isOk: return errorResult[seq[T]](s.error)
    if s.value == srDone: break
    # 既存のrow/byte limitを維持。超過を成功や途中までのseqに変換しない。
    let decoded = decodeRow(statement, T, rowIndex)
    if not decoded.isOk: return errorResult[seq[T]](decoded.error)
    output.add(decoded.value)
    inc rowIndex
    if firstOnly: break
  okResult(output)
```

上のlimit検査箇所は省略表記。実装では現行 `maxQueryParams` / `maxResultRows` / `maxResultBytes` と `rowBytes` の検証ロジックを省かず移植する。エラー時にも `defer finalize`、TEXT/BLOBのコピー、カラム不足・重複・型不一致・NULL/Option等の `decodeRow` の動作を保存する。現行 `readRows` は毎行 `result.value.add(decoded.value)` しており、抽出後は明示的な `var output: seq[T]` を使って結果集約を非回帰化する。[N2]

```nim
proc readRows*[T](db: var Db; sql: string;
    params: openArray[SqlValue] = []): Result[seq[T], DbError] =
  let copied = @params
  db.withQuery(proc(c: var Connection): Result[seq[T], DbError] =
    scanRowsOnConnection[T](c, sql, copied, false))

proc get*[T](q: Query; typ: typedesc[T]): Result[seq[T], DbError] =
  let compiled = q.compile()
  if not compiled.isOk: return errorResult[seq[T]](compiled.error)
  if q.updateScope != nil:
    return withUpdateQueryRead(q.updateScope,
      proc(c: var Connection): Result[seq[T], DbError] =
        scanRowsOnConnection[T](c, compiled.value.sql, compiled.value.params, false))
  readRows[T](q.owner[], compiled.value.sql, compiled.value.params)
```

実際には `q.owner` のnil検査をコンパイル前または通常分岐で維持し、**期限切れの `updateScope` は通常分岐に落とさず `dekInvalidState`** にする。`readFirst` / `Query.first` は `firstOnly=true` にするか共通scanner内の早期終了を別戻り型wrapperに組み直す。現在の `first -> get -> 全件読取り` は、複数行で上限超過しうるだけでなく、先頭1行しか要らないAPIとして無駄である。`q.limitValue=0` や既存ORDER BY/OFFSETの意味を上書きしないよう、**現行SQLをそのまま実行して最初の `SQLITE_ROW` で終了・finalize**するのが単純な初期実装である。[N1][N2]

**注:** `sqlite3_stmt_readonly()` はBEGIN/COMMIT/ROLLBACKなどでもtrueになり得る。内部Query BuilderはSELECT SQLを生成するのでその信頼境界を維持し、raw SQL入口で「厳密にSELECTのみ」を約束する場合は別途文種別の制限が必要。[S4]

### 5.6 statement寿命・例外・失敗経路

`prepare`成功直後に `defer finalize` を設置。bind不一致、SQLite step失敗、decoder失敗、結果上限超過、先頭行の早期return、CatchableErrorですべてfinalizeする。`Connection.prepare` は現在 `sqlite3_prepare_v2` のtailを受け取っておらず、partial statementのnil検査も強化候補。`readRows` のpublic raw SQLで複数statementを拒否するなら `tail` 検査とprepare失敗後partial stmtのfinalizeを追加する（Rustはこの2点を実装済み）。これはread-your-writesと別の防御改善である。[N3][R3]

`withUpdate` の既存順序（BEGIN後body、エラーならROLLBACK+overlay破棄、成功ならCOMMIT+publish）を変更しない。lease無効化は **defer/finally** で全終了経路をカバー。publish途中失敗は既存 `PublishStartedError` → trap の原子性方針を維持する。外からcatchできる例外のみ通常の `DbError` rollbackへ変換し、trap/fatal異常を通常エラーとして回復できたことにしない。[N3][N7]

## 6. stable VFSとの関係：今回の修正と独立させること

`1-method-chain` の `vfs.nim` はグローバル `overlayActive` で `readFile/fileSize` の読取先を選び、`FileState` にはRustの `read_only` / `read_snapshot` がない。よって更新がactiveの間の**通常reader**をRustと同程度に分離する保証はない。[N7][R6]

今回の対象である `UpdateConnection.table(...).get/first` は **writer自身の同一SQLite接続**を使うため、独立したread-onlyファイルによるsnapshot機構を先に作らなくても設計できる。通常 `Db.withQuery` の更新中実行はまず明示拒否する。将来的に「更新中でも通常Db Queryがコミット済みだけを見る」を要件にする場合、別PRで `(1)` `FileState` にopen flags/readOnlyを保持、`(2)` read-only `readFile/fileSize` はbase/snapshot参照、`(3)` read-only `writeFile/truncateFile` は拒否、`(4)` read-cache失効/active reader管理、を実装・検証する。[N7][R1][R6]

**`PRAGMA query_only` とVFSのsnapshot分離は別問題**。SQLiteのstatement read-only検査だけでファイルoverlay可視性は制御できない。[S2][S4]

## 7. 修正対象ファイルと順序

| 順 | ファイル | 変更 |
|---|---|---|
| 0 | `tests/test_query_transaction.nim` | INSERT結果を確認し、同じbody内で `first(StoredItem)` が `some`、`get` が複数行を返す再現テストを追加。まず失敗を固定する。 |
| 1 | `ffi/sqlite_api.nim` / test helper | 診断専用に `sqlite3_get_autocommit`、必要なら `sqlite3_next_stmt` を追加。D0–D5で障害箇所を確定。 |
| 2 | `db.nim` | `TransactionLease`、`UpdateConnection`/`Db.currentUpdate`、有効性検証、`withUpdateQueryRead`、`withUpdate`のdefer無効化、通常Queryの更新中guard。 |
| 3 | `typed.nim` | `readRows` を `scanRowsOnConnection` と通常wrapperに分割。各種decoderとリソース上限を共用。 |
| 4 | `query_builder.nim` | `updateOwner` を `updateScope` に置換し、`get/first` をscopeでディスパッチ。更新メソッドもscope検査付きに変更。 |
| 5 | `tests/test_typed_row.nim` / `test_query_stable.nim` | 複数行蓄積・TEXT NUL・strict decoding・stable close/reopenを回帰確認。 |
| 6 | `vfs/vfs.nim` | このバグだけのためには改修しない。通常readerの同時snapshot分離が別途要件化した場合に限定。 |

### 7.1 具体的な追加テスト

同じ可能なテストを `initMemoryForTest()` と `VecStableBackend` / `init()` の両方で走らせる。既存 `test_query_transaction.nim` と `test_query_stable.nim` を基礎にする。[N4][N5]

| ID | 操作 | 期待結果 |
|---|---|---|
| T01 | 更新内INSERT後に `conn.table(...).where(...).first(StoredItem)` | `isOk && isSome`、フィールド値一致 |
| T02 | 2行INSERT後に `get(StoredItem).orderBy(...)` | 2行とも取得。順序・重複・結果集約が正しい |
| T03 | UPDATE後にfirst、DELETE後にfirst | 未コミットの更新値が見え、DELETE対象は`none` |
| T04 | 未一致WHERE | `first`は`isOk && isNone`、SQL/decoderエラーとは区別 |
| T05 | body `Result.err` | body内では行が見え、rollback後通常Queryでは消える |
| T06 | body `CatchableError` | rollback、lease失効、次回updateが動く |
| T07 | `first` を先に読み、その後同じbodyでINSERT/COMMIT | 早期終了でもstatementがfinalizeされる |
| T08 | `get`/`first`を繰り返す | 以前の「Typed Readerの結果蓄積回帰」がない |
| T09 | `update`由来Queryをbody外へ保存 | COMMIT/ROLLBACK後いずれも`dekInvalidState`、次transactionで再活性化しない |
| T10 | `update`由来Queryをbody外でinsert/update/delete/insertId | stale scopeを通常Db更新へフォールバックせず拒否 |
| T11 | 更新中に通常`db.table().get`または `db.withQuery` | 明示 `dekInvalidState`。writerのquery_onlyを変更しない |
| T12 | 通常read経路でwrite SQLを渡す | 既存query-only/readonly/statement検査により拒否 |
| T13 | bind数不一致、prepare/step error、decoder error | それぞれ適切なErr。`none`へ潰さずリークなし |
| T14 | INTEGER/REAL/bool/TEXT埋込みNUL/BLOB/Option/NULL | 既存 `decodeRow` と同じ型規則とコピー結果 |
| T15 | maxRows/maxBytes/maxParams超過 | `dekResourceLimit`、途中までの成功seqを返さない |
| T16 | stable update成功→close/reopen、失敗→close/reopen | 成功のみ永続化、失敗は元のデータを保持 |
| T17 | `SELECT`のstep継続中の書込み | 公開行iteratorを出さず、scannerは同期的にfinalize。可視性未定義の並行stepを設計として避ける |
| T18 | `first`にORDER BY/OFFSET/LIMIT 0を併用 | 既存QueryのSQL意味と`first`の返却規則を維持 |
| T19 | 直後のD0–D5診断 | insert changes/autocommit/raw同一性/compiled bind/decoderを段階的に照合 |

`T11` は**新たに導入する明示仕様**であり、既存の全利用者に対して現状その動作が保証されていたという意味ではない。互換性影響をテスト/CHANGELOGで明記する。

### 7.2 実行コマンド（未実行）

```sh
cd ic-sqlite
nim c -r tests/test_query_transaction.nim
nim c -r tests/test_typed_row.nim
nim c -r tests/test_query_stable.nim
nim c -r tests/test_query_builder.nim
nim c -r tests/test_query_compiler.nim
nim c -r tests/test_typed_write.nim
nimble test
nimble build
./scripts/build_sqlite.sh   # wasm32向けの既存ビルド手順を維持
```

nativeでの動作確認後、canister／Wasm経路で同期closure・stable publishの原子性を確認する。**この調査で上記コマンドに合格したとは主張しない。**

## 8. 受入条件

1. `UpdateConnection.table(...).get/first` は `Db.withQuery` に入らず、更新に使った正確に同一の `sqlite3*` 上でSELECTする。
2. 現行 `Query.compile`、bind順序、`decodeRow`、strict型規則、TEXT/BLOB完全コピー、結果上限とエラー伝播が変わらない。
3. `get` は全行を独立したseqに回収し、`first` は1行で終了してstatementをfinalizeする。
4. Queryの期限切れを共有leaseで検出し、すべての更新read/writeがscope終了後に拒否される。
5. 通常Queryのquery-only/read-only経路と既存transaction/overlay/publish/rollbackの境界を維持する。
6. D0–D5により、過去のraw handle実験が0行になった理由を実測で特定する。**同一handleでも0行だった観測を無視してread dispatchの変更だけで修正完了としない。**

## 9. 根拠・固定コミットのソースリンク

**Nim `1-method-chain`（N）**

- [N1] [`ic-sqlite/src/ic_sqlite/query_builder.nim`](https://github.com/dumblepy/nim-ic-sqlite/blob/f1ba4079f800ec5fd8602465e799eaa379f5800f/ic-sqlite/src/ic_sqlite/query_builder.nim#L31-L67)、[get/firstとexecuteWrite](https://github.com/dumblepy/nim-ic-sqlite/blob/f1ba4079f800ec5fd8602465e799eaa379f5800f/ic-sqlite/src/ic_sqlite/query_builder.nim#L258-L275)。 
- [N2] [`ic-sqlite/src/ic_sqlite/typed.nim` — decodeRowとreadRows](https://github.com/dumblepy/nim-ic-sqlite/blob/f1ba4079f800ec5fd8602465e799eaa379f5800f/ic-sqlite/src/ic_sqlite/typed.nim#L67-L146)。
- [N3] [`ic-sqlite/src/ic_sqlite/db.nim` — 型](https://github.com/dumblepy/nim-ic-sqlite/blob/f1ba4079f800ec5fd8602465e799eaa379f5800f/ic-sqlite/src/ic_sqlite/db.nim#L18-L54)、[書込みとwithQuery/Statement](https://github.com/dumblepy/nim-ic-sqlite/blob/f1ba4079f800ec5fd8602465e799eaa379f5800f/ic-sqlite/src/ic_sqlite/db.nim#L264-L467)、[withUpdate](https://github.com/dumblepy/nim-ic-sqlite/blob/f1ba4079f800ec5fd8602465e799eaa379f5800f/ic-sqlite/src/ic_sqlite/db.nim#L469-L502)。
- [N4] [`tests/test_query_transaction.nim`](https://github.com/dumblepy/nim-ic-sqlite/blob/f1ba4079f800ec5fd8602465e799eaa379f5800f/ic-sqlite/tests/test_query_transaction.nim#L1-L35)。
- [N5] [`tests/test_query_stable.nim`](https://github.com/dumblepy/nim-ic-sqlite/blob/f1ba4079f800ec5fd8602465e799eaa379f5800f/ic-sqlite/tests/test_query_stable.nim#L1-L24)。
- [N6] [`.agent/progress.md` — Phase5の未達事項](https://github.com/dumblepy/nim-ic-sqlite/blob/f1ba4079f800ec5fd8602465e799eaa379f5800f/.agent/progress.md#L51-L82)、[ブランチルールの14節](https://github.com/dumblepy/nim-ic-sqlite/blob/f1ba4079f800ec5fd8602465e799eaa379f5800f/.agent/rules/branch/1-method-chain.mdc#L883-L934)。
- [N7] [`vfs/vfs.nim` — FileStateとglobal overlay、readFile](https://github.com/dumblepy/nim-ic-sqlite/blob/f1ba4079f800ec5fd8602465e799eaa379f5800f/ic-sqlite/src/ic_sqlite/vfs/vfs.nim#L14-L109)。

**Rust原実装（R）**

- [R1] [`src/db/mod.rs` — update/query/connection pool](https://github.com/humandebri/ic-sqlite-vfs/blob/1386239acff1dd7ede5ac78a2f0a22ef495195de/src/db/mod.rs#L181-L313)。
- [R2] [`src/db/transaction.rs` — UpdateConnectionのDeref、run_immediate](https://github.com/humandebri/ic-sqlite-vfs/blob/1386239acff1dd7ede5ac78a2f0a22ef495195de/src/db/transaction.rs#L11-L89)。
- [R3] [`src/db/connection.rs` — read-only openとquery_*](https://github.com/humandebri/ic-sqlite-vfs/blob/1386239acff1dd7ede5ac78a2f0a22ef495195de/src/db/connection.rs#L98-L112)、[prepare/query_all等](https://github.com/humandebri/ic-sqlite-vfs/blob/1386239acff1dd7ede5ac78a2f0a22ef495195de/src/db/connection.rs#L194-L357)。
- [R4] [`src/db/statement.rs` — query_optional/query_allとRows](https://github.com/humandebri/ic-sqlite-vfs/blob/1386239acff1dd7ede5ac78a2f0a22ef495195de/src/db/statement.rs#L406-L488)。
- [R5] [`src/db/row.rs` — 型付き列のコピー](https://github.com/humandebri/ic-sqlite-vfs/blob/1386239acff1dd7ede5ac78a2f0a22ef495195de/src/db/row.rs#L1-L170)。
- [R6] [`src/sqlite_vfs/file.rs` — read_only/read_snapshotとxRead](https://github.com/humandebri/ic-sqlite-vfs/blob/1386239acff1dd7ede5ac78a2f0a22ef495195de/src/sqlite_vfs/file.rs#L17-L155)。
- [R7] [`src/sqlite_vfs/stable_blob.rs` — overlay優先read](https://github.com/humandebri/ic-sqlite-vfs/blob/1386239acff1dd7ede5ac78a2f0a22ef495195de/src/sqlite_vfs/stable_blob.rs#L154-L186)。

**SQLite公式仕様（S）**

- [S1] [Isolation in SQLite](https://www.sqlite.org/isolation.html) — 同一接続の先行未コミット更新が後続SELECTに見えること、別接続の通常隔離。
- [S2] [PRAGMA query_only](https://www.sqlite.org/pragma.html#pragma_query_only) — database file変更を抑止する設定。snapshot選択用スイッチではない。
- [S3] [Transaction](https://www.sqlite.org/lang_transaction.html) / [sqlite3_get_autocommit](https://www.sqlite.org/c3ref/get_autocommit.html) — 自動rollbackとtransaction状態確認。
- [S4] [sqlite3_stmt_readonly](https://www.sqlite.org/c3ref/stmt_readonly.html) — transaction制御文でもtrueになり得る、直変更のみの検査。
