# ic-sqlite 開発規約

- 公開 API は `src/ic_sqlite.nim` を正規入口とする。
- SQLite の C ABI・リンク設定・target 判定は `src/ic_sqlite/ffi/` に閉じ込める。
- stable memory への永続書込みは overlay の publish 経路以外から行わない。
- native unit test は stable memory の代わりに `VecStableBackend` を利用する。
