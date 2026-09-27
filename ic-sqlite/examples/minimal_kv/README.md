# minimal_kv

最小の `ic-sqlite` canister 例です。SQLite image は ICP stable memory に保存されます。

```sh
cd examples/minimal_kv
icp deploy backend -e local
icp canister call backend put '("hello", "world")' -e local
icp canister call backend get '("hello")' -e local
icp deploy backend -e local
icp canister call backend get '("hello")' -e local
```

`canister_init` と `canister_post_upgrade` は同じ migration-aware 初期化を実行します。
