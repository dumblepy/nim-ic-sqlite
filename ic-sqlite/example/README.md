# Hello World

Welcome to your new `example` project. It demonstrates a Nim backend canister built with `nicp` and managed by `icp-cli`.

## Overview

This project consists of one or two canisters:

- [backend](./backend/): a Nim canister with its [`backend.did`](./backend/backend.did) file.
- [frontend](./frontend/): a React webapp deployed in an asset canister.


## Build and Deploy

First, start a local network:

```bash
icp network start -d
```

Then, deploy the project:

```bash
icp deploy
```

You can call the backend directly:

```bash
icp canister call backend migrationCount '()' --query
icp canister call backend put '("hello", "world")'
icp canister call backend get '("hello")' --query
icp canister call backend update '("hello", "updated")'
icp canister call backend deleteValue '("hello")'
```

`backend` は起動時と upgrade 時に migration を実行します。`kv` テーブルは
migration 1、`kv_value_idx` は migration 2 で作成され、`migrationCount` は適用済み
migration 数を返します。

## Local Backend Iteration

If you want to build the backend directly, run:

```bash
cd backend
nicp dev
```

Use `nicp build` instead of `nicp dev` for a release-oriented build.
Pass `none` as the second argument to `nicp new` if you want a backend-only project.

If you want to work on the frontend, use the generated React app in [`frontend/app`](./frontend/app).

Finally, stop the local network with:

```bash
icp network stop
```
