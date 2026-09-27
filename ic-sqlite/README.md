# ic_sqlite

Internet Computer の stable memory を SQLite の永続領域として使う Nim ライブラリです。

実装は設計書 `../design/nim_ic_sqlite_vfs_design.md` に従い、SQLite C ABI を薄い
C shim に閉じ込めます。利用側の正規入口は `import ic_sqlite` です。

ネイティブの骨組み確認は次で行います。

```sh
nimble test
```
