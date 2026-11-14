# FileVault

**给普通人的文件时光机 — 基于 Git 的 macOS 菜单栏自动版本管理工具**

FileVault 常驻 macOS 菜单栏，对一个受管根目录下的**第一层子文件夹**，各自独立初始化 Git 仓库；监控到文件变动后自动提交。核心价值：**零操作的文件历史版本管理**——误删误改随时找回，可选绑定远程仓库自动备份上云。

> ⚠️ 命名说明：FileVault 与 macOS 自带的磁盘加密功能同名，存在搜索混淆与审核风险，正式发布前建议评估改名（候选：Vaultkeeper / TimeGit / SnapKeep / Histodeck）。

## 核心功能

1. **零配置起步** — 首次启动自动检测 Git 环境；缺失时自动安装（内嵌 git 优先，其次 Xcode CLT / Homebrew），全程无需命令行。
2. **一级文件夹独立仓库** — 添加一个受管根目录，其下每个第一层子文件夹各自成为独立 Git 仓库；已有 `.git` 的子目录被原样接管复用，绝不破坏。
3. **自动版本管理** — FSEvents 监控文件变动，5 秒防抖聚合后自动 `add + commit`，提交信息自动总结变更（如 `auto: 3 处变更 (+120 -40)，新增 a.md，修改 b.md`）。
4. **远程仓库绑定** — 每个子仓库可单独配置远程地址（GitHub/GitLab 等，SSH/HTTPS），开启「提交后自动推送」，本地优先、失败自动重试。
5. **菜单栏常驻** — 状态图标实时反映整体状态（空闲/同步中/待推送/异常），菜单列出每个文件夹的独立状态（✓ 已同步 / ↑N 待推送 / ⚠ 失败）。
6. **历史时间线** — 查看每个仓库的提交历史，了解文件如何一步步演进。
7. **一键回滚** — 将单个文件或整个仓库恢复到任意历史版本，误删 3 步内找回。
8. **忽略规则** — 自动注入 .gitignore 模板（.DS_Store、node_modules 等），设置窗口内可视化编辑，改动会被自动提交。
9. **大文件保护** — 超过阈值的大文件（默认 200MB）自动排除出版本管理，避免仓库膨胀。
10. **手动暂停** — 一键暂停/恢复自动提交，恢复时自动补一次全量提交。
11. **测试连接** — 配置远程后一键验证可达性与认证（`git ls-remote`），失败原因直接可读。
12. **仓库健康度** — 设置窗口展示每仓库提交数 / 体积 / 最近提交时间；超过 2GB 告警。
13. **每周自动 gc** — 仓库每周自动 `git gc --auto`，控制 .git 膨胀。
14. **SSH 密钥引导** — 配置 SSH 远程时检测 ~/.ssh 密钥，缺失时给出指引。
15. **失败系统通知** — 自动提交/推送失败时发送系统通知（本地提交永远先行，失败不影响本地版本管理）。

## 典型场景

| 场景 | FileVault 的价值 |
|---|---|
| 论文写作误删一整章 | 打开历史时间线，一键恢复到昨晚版本 |
| 设计稿改坏了想反悔 | 回滚到任意历史版本 |
| 笔记库多机使用 | 每个文件夹绑定私有远程仓库，提交后自动推送，多机同步备份 |

## 系统要求

- macOS 14.0+
- Apple Silicon / Intel
- 无需预装 Git（应用会自动准备）

## 自动更新

应用内置更新器（FR-20）：启动后静默检查 GitHub Releases（每日一次），发现新版本发系统通知并在菜单标记；菜单「检查更新…」手动触发。安装流程：下载 → sha256 校验（与 API digest 比对）→ 原子替换 bundle（旧版保留 `.old` 可回滚）→ 自动重启。仅 `.app` 包内运行时可用。

## 下载安装

**最新发布：[v1.1.0](https://github.com/wjw1-Evan/FileVault/releases/tag/v1.1.0)** — [FileVault-1.1.0.zip](https://github.com/wjw1-Evan/FileVault/releases/download/v1.1.0/FileVault-1.1.0.zip)（0.63MB，sha256 `f1f8be8c…c727d`）

解压后将 `FileVault.app` 拖入「应用程序」，首次打开右键 → 打开（ad-hoc 签名提示未公证），菜单栏即可见图标。

## 开发

```bash
swift build          # 构建
swift test           # 运行全部测试（52 项）
.build/debug/FileVaultApp            # 启动菜单栏应用
.build/debug/FileVaultApp --smoke    # 无 UI 冒烟自检
swift run FileVaultApp --help        # 命令行参数
```

## 打包分发

```bash
./scripts/make_app.sh                # release 构建 + 组装 FileVault.app（含图标、ad-hoc 签名）
hdiutil create -volname FileVault -srcfolder build/FileVault.app -format UDZO dist/FileVault.dmg
# 或（沙箱环境替代方案）：
ditto -c -k --keepParent build/FileVault.app dist/FileVault-1.0.0.zip
```

- 产物：`FileVault.app`（LSUIElement 菜单栏模式、bundle 通知可用、设置内可开启「登录时启动」）
- Release 实测：RSS 54–60MB、空闲 CPU **0.07%**（事件驱动刷新后，较轮询架构降低约 14 倍）、二进制 0.8MB
- 代码签名为 ad-hoc（本地验证）；对外分发需正式开发者证书

文档：[产品需求文档](docs/01-产品需求文档-PRD.md) · [技术架构](docs/02-技术架构方案.md) · [开发路线图](docs/03-开发路线图.md) · [风险与竞品](docs/04-风险与竞品分析.md)
