# FileVault

**给普通人的文件时光机 — 基于 Git 的 macOS 菜单栏自动版本管理工具**

FileVault 常驻 macOS 菜单栏，对一个受管根目录下的**第一层子文件夹**，各自独立初始化 Git 仓库；监控到文件变动后自动提交。核心价值：**零操作的文件历史版本管理**——误删误改随时找回，可选绑定远程仓库自动备份上云。

> ⚠️ 命名说明：FileVault 与 macOS 自带的磁盘加密功能同名，存在搜索混淆与审核风险，正式发布前建议评估改名（候选：Vaultkeeper / TimeGit / SnapKeep / Histodeck）。

## 核心功能

1. **零配置起步** — 首次启动自动检测 Git 环境；缺失时自动安装（内嵌 git 优先，其次 Xcode CLT / Homebrew），全程无需命令行。
2. **一级文件夹独立仓库** — 添加一个受管根目录，其下每个第一层子文件夹各自成为独立 Git 仓库；已有 `.git` 的子目录被原样接管复用，绝不破坏。
3. **自动版本管理** — FSEvents 监控文件变动，5 秒防抖聚合后自动 `add + commit`，提交信息自动总结变更（如 `auto: 3 处变更 (+120 -40)，新增 a.md，修改 b.md`）。
4. **远程仓库绑定** — 每个子仓库可单独配置远程地址（GitHub/GitLab/Azure DevOps 等）与**身份验证**（自动 gh 凭证助手 / 用户名+访问令牌入钥匙串 / SSH 密钥），开启「提交后自动推送」，本地优先、失败自动重试；**凭证过期/认证失败主动巡检提醒**（每 6 小时，去重不骚扰）。
5. **菜单栏常驻** — 状态图标实时反映整体状态（空闲/同步中/待推送/异常）；菜单只保留一行摘要「N 个仓库 · 正常」+ 每个根目录一个子菜单（内含各仓库状态图标）+ 常用操作，详情都在主面板/设置里（v3.1.5 精简，不再堆砌健康度文字与版本号）。
6. **历史时间线** — 查看每个仓库的提交历史，了解文件如何一步步演进。
6.5 **快速打开** — 菜单栏与设置窗口均可一键在 Finder 中打开已添加的目录。
6.6 **主控面板** — 菜单「打开主面板」(⇧⌘D)：状态总览 + 跨仓库最近活动流 + 目录卡片。
7. **一键回滚** — 整仓回滚到任意提交；**单文件恢复**一步到位：选中提交后，它包含的每个文件旁都有「恢复」按钮，误删 3 步内找回。
8. **忽略规则** — 自动注入 .gitignore 模板（.DS_Store、node_modules 等），设置窗口内可视化编辑，改动会被自动提交。
9. **大文件保护** — 单文件上限**跟随远端**（无本地阈值设置）：github.com 远端自动按 100 MB 硬限制排除文件，其他远端不设限；设置页按仓库展示远端上限，避免仓库膨胀或推送必然失败。
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

应用内置更新器（FR-20）：启动 **20 秒后**静默检查一次 GitHub Releases，之后**每日一次**；检查失败 **10 分钟**后重试（并显示失败状态）；设置里重新打开「自动检查更新」会立即恢复检查（v3.1.4），**发现新版本自动下载安装并重启**（受「自动检查更新」开关门控）。安装流程：字节级下载（实时百分比+字节数）→ sha256 校验 → **更新包签名/身份校验**（v3.3.0：校验 bundle id 与代码签名，正式签名版还会钉住 Team ID）→ 原子替换 bundle（旧版保留 `.old` 可回滚）→ 自动重启。**启动失败自动回退**（v3.3.0）：新版本连续 3 次未能正常启动时，自动换回上一版本并通知。仅 `.app` 包内运行时可用。

**进度只在菜单里看（v3.1.7）**：更新不再弹出任何窗口或对话框。打开菜单栏图标即可看到一行实时状态——`正在下载更新 42%… · 840 KB / 2 MB` → `正在校验更新…` → `正在安装更新…` → `更新完成，正在重启…`；手动「检查更新…」的结果也写在菜单里（如 `已是最新版本（v3.1.5）`、`更新失败：…`），不会打断你正在做的事。

## 永久免费

FileVault **永久免费**：无试用期、无激活码、无账号、无订阅、无遥测。

- 所有功能完整开放：多根目录、自动推送、历史回滚、诊断包导出
- 没有服务端账号体系；除自动更新检查外，使用全程不需要联网
- 数据完全属于你：每个文件夹都是标准 Git 仓库，随时可以用任何 Git 工具接管
- 个人与商业使用均免费

如果它帮到了你：欢迎在 [GitHub](https://github.com/wjw1-Evan/FileVault) 点 Star、提 Issue，或把诊断包发给支持邮箱。

- **法务**：[最终用户许可协议](LICENSE) · [隐私政策](PRIVACY.md)（无遥测、无云端中转、不上传文件内容）
- **发布与商用化分析**：[06 商用化与发布方案](docs/06-商用化方案.md)

## 下载安装

**最新发布：[v3.3.0](https://github.com/wjw1-Evan/FileVault/releases/tag/v3.3.0)** — [FileVault-3.3.0.zip](https://github.com/wjw1-Evan/FileVault/releases/download/v3.3.0/FileVault-3.3.0.zip)（sha256 `095195f8…18e42edf`）

解压后将 `FileVault.app` 拖入「应用程序」，首次打开右键 → 打开（ad-hoc 签名提示未公证），菜单栏即可见图标。

## 开发

```bash
swift build          # 构建
swift test           # 运行全部测试（156 项）
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
- 本地构建默认 ad-hoc 签名；**对外分发必须正式签名 + 公证**：
  `CODESIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" NOTARY_PROFILE=fv-notary ./scripts/make_app.sh 3.2.0`
  （公证需先执行一次 `xcrun notarytool store-credentials fv-notary --apple-id … --team-id … --password …`）

## 仓库卫生：GitHub 100 MiB 限制

GitHub 对普通 Git 仓库的单文件有 **100 MiB 硬限制**（50 MiB 起警告，超限直接拒绝 push）。本仓库约定：构建产物与发布包一律不进 Git，二进制分发只走 Releases。新克隆请执行一次：

```bash
./scripts/install-git-hooks.sh   # 启用 pre-commit 守卫（阻止 > 100 MiB 文件）
./scripts/check-large-files.sh   # 手动全历史体检
```

完整方案与应急处理：[GitHub 100 MB 文件限制解决方案](docs/05-GitHub-100MB限制解决方案.md)

文档：[产品需求文档](docs/01-产品需求文档-PRD.md) · [技术架构](docs/02-技术架构方案.md) · [开发路线图](docs/03-开发路线图.md) · [风险与竞品](docs/04-风险与竞品分析.md) · [GitHub 大文件方案](docs/05-GitHub-100MB限制解决方案.md) · [商用化方案](docs/06-商用化方案.md) · [许可协议](LICENSE) · [隐私政策](PRIVACY.md)
