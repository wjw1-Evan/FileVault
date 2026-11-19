# AGENTS.md — Pastward 工作区指引

面向在本仓库工作的 AI 智能体。人类贡献者请看 [README.md](README.md)。

## 项目速览

- 产品：Pastward（v4.2.31 前叫 FileVault），macOS 菜单栏常驻的 Git 自动版本管理工具（当前 v4.2.31）。面向用户一律用新名；模块名 FileVaultCore/FileVaultApp、bundle id、配置目录与 refs/filevault/backup 是**刻意保留**的机器标识，不要顺手改。
- 技术栈：Swift 6（工具链 6.0，源码按 `swiftLanguageMode(.v5)` 编译）、SwiftUI、macOS 14+。
- 目录：
  - `Sources/FileVaultCore/` — 纯逻辑（Git、同步、恢复、更新、配置），不依赖 UI。
  - `Sources/FileVaultApp/` — SwiftUI 界面、菜单栏、本地化资源。
  - `Tests/FileVaultTests/` — 单元与回归测试。
  - `docs/` — 编号中文设计文档；`docs/memory/` — 长期记忆（见下）。
  - `scripts/` — 打包、发布与守卫脚本。

## 常用命令

| 目的 | 命令 |
| --- | --- |
| 编译 | `swift build` |
| 测试 | `swift test` |
| 打包 .app | `./scripts/make_app.sh <版本> [构建号]` |
| 大文件守卫（CI 同款） | `./scripts/check-large-files.sh` |
| 安装 git hooks | `./scripts/install-git-hooks.sh` |

改完代码至少跑 `swift build`，动到逻辑再跑相关测试；不要提交失败的用例。

## 代码约定

- 业务逻辑放 `FileVaultCore`，UI 只负责展示与编排，便于测试。
- 面向用户的错误必须可读：不要把 `error 1`、裸退出码直接抛给用户（参考 v4.1.1 的修复，见 README「核心功能」第 3 条）。
- 文案走本地化（默认 `zh-Hans`），中英文案同步补齐，别在代码里硬编码中文再到英文界面露出。
- 产品红线：不做遥测、不上传文件内容、不引入账号体系、不因付费墙阉割功能。
- 构建产物 `build/`、`dist/`、`.build/` 已在 `.gitignore` 中，不要提交或手改。
- 新增源文件后确认 `Package.swift` 的 target 能自动收集（SwiftPM 按目录收集，通常无需改动）。

## 文档约定

- 方案/设计文档进 `docs/`，命名 `NN-主题.md`，编号顺延。
- 行为变化要同步更新 `README.md` 对应段落和版本说明；文档用中文，术语首次出现给英文原文。

## 记忆协议（重要）

跨会话能留下来的只有文件。规则见 [docs/memory/README.md](docs/memory/README.md)。

- **开工前**：任务涉及“以前怎么做的、为什么这样设计、有没有踩过坑”时，先在 `docs/memory/` 里按索引检索，只读命中的条目，不要整目录通读。
- **收工时**：仅在三种情况写一条——做出有取舍的技术决策、修好非显而易见的 bug、确立新约定。
- **写法**：一句结论 + 原因 + 证据（`路径:行` / 提交 / 日期）+ 影响面，单条不超过 10 行。
- **不写**：过程流水账、代码里一眼可见的事实、密钥令牌与个人信息、临时状态。
- 同一事实出现新旧两条时，保留有证据的新的那条，删掉旧的。

## 给智能体的边界

- 只改与任务相关的文件，别顺手重排格式。
- 不确定产品意图时先问，不要自行删功能（例如自动提交不可关闭是刻意的设计，见 README「核心功能」第 3 条与第 10 条）。
- 破坏性操作（重置、清空历史、强制推送）未经确认不要执行。
