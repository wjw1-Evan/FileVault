# 0004 · 自动提交/推送统一跳过 git hooks（--no-verify）

- 日期：2026-11-17
- 状态：已采纳（v4.2.27）

## 结论

自动管线的 `commit` 与 `push` 一律加 `--no-verify`，用户 hooks 不参与后台快照提交。

## 原因

hook 是为人发起的提交设计的。一个失败的 pre-commit 会永久否决自动提交（与「自动提交始终开启、不可关闭」的产品承诺直接冲突）；常见 lint hook 超过 30s 提交预算会被 SIGTERM 强杀，60s 后重试再来一轮。自动提交本就是低风险的快照行为，hook 该拦的是人的错误。

## 证据

- `RepoManager.commitAll`（`["commit", "--no-verify", ...]`，含身份重试分支）、`mergeSync` 的 commit、`SyncManager.push`（`["push", "--no-verify", ...]`）。
- 回归测试：`Tests/FileVaultTests/AuditV427Tests.swift::testAutoCommitSkipsUserHooks`（失败 hook 下 commitAll 必须成功）。
- 旧行为的测试 `CommitFailureRecoveryTests` 已按新行为改写（用只读 .git 制造失败，hook 否决不再是预期路径）。

## 影响

- 在 FileVault 受保护仓库里想跑 hook 的用户需手动提交（人发起的 git 操作不受影响）。
- 未来若要支持「在 FileVault 提交上跑 hook」，应做成每仓库配置项且默认关闭。
