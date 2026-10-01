# AGENTS

- `.agent/rules/project.mdc` を必ず読み、プロジェクトルールと達成目標を確認する。
- `.agent/rules/branch.mdc` を必ず読み、ブランチルールを確認する。
- 現在のブランチ名と一致するファイル名のファイルが、リポジトリのルートから見て `.agent/rules/branch/` 配下にあった場合は、それを読み込んで。
- 設計書はブランチルールと別で作成するのではなく、ブランチルールの中に書くこと。明示的に別ファイルで作ると指定した時だけ別ファイルで作る。
- ここはDockerコンテナ内であり、エージェントはDockerコンテナ内で動作する。
- Think harder.
- Deep research.
- Internal reasoning compression. You may use internal reasoning, but do not output it. Keep internal reasoning minimal but sufficient for correctness. Do not over-explore edge cases unless explicitly asked. Return only the final answer in concise form.
- git add, git commitのコマンド操作は禁止。
- 常に日本語で回答する。
- `/application/.agent/progress.mdc` を使って自律ループの中で最終ゴールまで継続して実装を進めること。

## ic-sqlite 開発規約

- 公開 API は `src/ic_sqlite.nim` を正規入口とする。
- SQLite の C ABI・リンク設定・target 判定は `src/ic_sqlite/ffi/` に閉じ込める。
- stable memory への永続書込みは overlay の publish 経路以外から行わない。
- native unit test は stable memory の代わりに `VecStableBackend` を利用する。