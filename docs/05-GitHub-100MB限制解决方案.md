# GitHub 100 MB 文件限制解决方案

版本：v1.0 · 日期：2026-11-15 · 状态：方案（本仓库守卫已落地，产品改造待排期）

## 0. 结论先行

GitHub 的 100 MB 不是「额度」，而是**单个 Git blob 的硬墙**：

- 超过 **50 MiB**：`git push` 打印警告，但**仍然可以推送成功**；
- 超过 **100 MiB**：GitHub **直接拒绝整个 push**（报 `GH001` / `exceeds GitHub's file size limit`）；
- 一旦大文件进了历史，即使后续删除文件，blob 仍留在 `.git` 和历史里；仓库会永久变胖，除非**重写历史**。

因此解决方案按优先级分三层，**默认永远选第一层**：

| 优先级 | 策略 | 适用 | 代价 |
|---|---|---|---|
| ① 不进 Git | 大文件放仓库外（iCloud/网盘/对象存储），或写进 `.git/info/exclude` | 90% 的「大文件」：视频、设计稿、数据集、构建产物 | 无；文件没有版本历史 |
| ② 必须随代码走 | **Git LFS**：单文件 ≤ 2 GiB（Free/Pro），免费额度 10 GiB 存储 + 10 GiB/月流量 | 需要版本管理、团队共享的二进制 | 依赖 git-lfs；超额计费；克隆需拉 LFS |
| ③ 只做分发 | **GitHub Releases**：单个资产 < 2 GiB，每个 Release 最多 1000 个，总量/流量不限 | 安装包、模型、演示素材 | 无版本控制语义，只是下载 |

对 FileVault 来说，问题不只是「某个文件怎么传」，而是**产品把用户文件推到 GitHub 时，必须按 GitHub 的口径提前拦截**——详见第 4 节。本仓库自身则已按第 3 节落地了守卫脚本与 CI。

---

## 1. 事实核对（2026-11，GitHub 官方文档）

| 项目 | 限制 | 说明 |
|---|---|---|
| 普通 Git 单文件 | **100 MiB 硬限制** | 超过则整个 push 被拒；恰好 100 MiB 可通过 |
| 普通 Git 单文件 | **50 MiB 警告** | 仅警告，push 成功；建议此时就改用 LFS |
| 网页上传 | 25 MiB | 浏览器直接拖文件的上限 |
| 仓库体积 | 建议 < 1 GB，**强烈建议 < 5 GB** | 过大可能收到 GitHub 支持邮件，克隆极慢 |
| Git LFS 单文件 | Free/Pro **2 GiB**，Enterprise Cloud 5 GiB | 超过 2 GiB 的文件 LFS 也接不住 |
| Git LFS 免费额度 | Free/Pro：**10 GiB 存储 + 10 GiB/月流量**；Team/Enterprise：250 GiB | 超额按量计费；只下载到指针文件说明额度用尽 |
| Release 资产 | 每个 < **2 GiB**，每个 Release 最多 **1000** 个 | 总量与下载流量不限 |

> GitHub 文档用 **MiB**（1 MiB = 1,048,576 B），FileVault 设置里的「MB」按 1024 进制换算，二者数值恰好一致；但 Finder 显示的是十进制 MB，所以「看起来 99 MB」的文件仍可能超过 100 MiB。**以字节数为准**。

失败时的典型输出：

~~~text
remote: error: File video/final.mp4 is 120.00 MB; this exceeds GitHub's file size limit of 100.00 MB
remote: error: GH001: Large files detected.
! [remote rejected] main -> main (pre-receive hook declined)
~~~

此时：**本地提交完好、远程未被修改**；重试没有任何意义，必须先处理那个 blob。

---

## 2. 决策树：这个文件到底该放哪？

~~~text
文件是否必须跟随代码做版本管理？
├─ 否 ──→ ① 不进 Git
│         · 加入 .gitignore（团队共享）或 .git/info/exclude（仅本机，FileVault 现有做法）
│         · 原文件留在原地，用 iCloud/网盘/对象存储/S3 备份
│
├─ 是，且单文件 ≤ 2 GiB，总量可控 ──→ ② Git LFS
│         · git lfs install && git lfs track "*.psd"
│         · 注意免费额度 10 GiB、克隆需拉取、历史迁移会改写 commit
│
└─ 是，但 > 2 GiB / 体积持续增长 / 不值得进 Git ──→ ③ 外部对象存储 + 仓库存「引用」
          · 仓库只存 URL + sha256 + 版本清单；必要时写下载脚本
          · 对外分发用 GitHub Releases（单资产 < 2 GiB）

发布产物（.app / .dmg / .zip / 数据快照）──→ GitHub Releases，永远不进版本库
~~~

**不推荐**：把大文件切成 `.part01/.part02` 塞进仓库、用 submodule 指向另一个大仓库、先压缩再入库、force push 后不通知协作者。它们只是把问题推迟或放大。

## 2.1 FAQ：能不能 push 时自动拆分、本地自动合并？

**结论：不能。** 本地 Git 确实没有单文件大小限制，但 GitHub 的限制发生在**服务端接收阶段**，而 Git 的 push 是「对象原样传输」——没有任何钩子/过滤器能在这个阶段把一个大文件改写成多个小文件，同时让远端历史与本地保持一致。

原因拆开看：

1. **push 不改内容**：`git push` 把 commit/tree/blob 原样发送；GitHub 在 `pre-receive` 里检查每个 blob 的大小，> 100 MiB 直接拒绝整个 push。客户端没有「推送时自动分片」的开关。
2. **Git 过滤器是一对一**：`clean`/`smudge` filter 的契约是「一个工作区文件 ↔ 一个 blob」。它可以改变内容（例如 LFS 写成指针），但**不能把一个文件变成多个 tree entry**；LFS 也是把内容搬到独立存储，而不是拆文件。
3. **pre-push 钩子救不了**：客户端钩子只能阻止 push 或改推另一个 ref。如果 push 时临时生成「分片提交」推到另一个分支，远端提交哈希与本地不同，`pull`/`merge`/PR/回滚都会失配，GitHub 就不再是一个普通 git remote。
4. **「提交前拆分 + 检出时合并」技术上能跑，但代价很大**：
   - 分片内容仍进入 Git 历史，每次修改都新增 blob，仓库体积随版本增长，很快撞上 1 GB / 5 GB 的仓库建议线；
   - hook 不随 `git clone` 下发，新机器、同事、CI 默认检出的都是分片文件；「自动合并」要求先安装 FileVault/脚本；
   - GitHub 网页、Desktop、`git archive`、CI checkout 看到的都是分片；
   - 二进制分片没有有意义的 diff/merge；固定大小分片遇到头部插入会导致所有后续分片变化，必须用内容定义分块（CDC），实现复杂度高；
   - 只绕过「单文件」限制，绕不过「仓库总体积」和克隆成本。
5. **github.com 没有提额通道**；只有自建 GitHub Enterprise Server 才可能由管理员调整策略（视版本）。

### 如果一定要「本地无感」，可选架构

| 方案 | 原理 | 用户透明度 | 主要代价 |
|---|---|---|---|
| **Git LFS** | 仓库存指针，内容存 LFS；clean/smudge 自动同步 | 高（需装 git-lfs） | 单文件 ≤ 2 GiB；免费 10 GiB 存储+流量；克隆依赖 LFS |
| **自建/第三方 LFS + 对象存储** | 同上，LFS 服务端把对象分片存 S3/B2 等 | 高 | 需维护服务；GitHub 只存指针 |
| **FileVault 大文件旁路**（对本品最现实） | 大文件不进 Git；FileVault 按 sha256 存本地/对象存储，仓库只提交 manifest；检出/拉取后守护进程还原 | 对 FileVault 用户接近无感 | 历史/回滚要经过 FileVault；标准 git 工具看不到大文件内容 |
| **分片镜像 + 自定义同步层** | FileVault 维护「正常历史」与「分片镜像」两套，GitHub 只收镜像 | 低 | GitHub 不再是普通 remote，PR/协作/回滚全部要自研 |
| **Release 分片** | 只做分发：大文件切块作为 Release 资产 | 无（不参与版本控制） | 只能下载，clone 得不到文件 |

**推荐顺序**：不需要版本管理 → 不进 Git；需要 → Git LFS（单文件 ≤ 2 GiB）；超过 2 GiB 或需要完全透明 → 外部对象存储 + manifest（FileVault 旁路）。把大文件切碎塞进 Git，只在「文件数少、版本极少、且所有客户端都装了同一套钩子」时才勉强可行，不适合作为产品默认能力。

---

## 3. 本仓库（FileVault 自身）的落地方案

### 3.1 现状审计

- 仓库 `.git` 当前约 424 KB，历史中**没有 > 5 MB 的 blob**，健康。
- `build/`、`dist/`、`.build/` 已被 `.gitignore` 忽略；发布 zip 在 `dist/` 下（每个约 0.8 MB），从未入库。
- 风险点在**未来**：技术架构里计划「内嵌静态 git 二进制」（约 50–60 MB）。若直接提交：
  - 每个用户克隆都要多拉 50 MB；
  - 一旦某天换版本，历史里会留下多份 git 二进制；
  - 距离 100 MiB 只差一个 debug 符号。

### 3.2 规则

1. **Release 资产不进 Git**：`dist/` 保持忽略，zip 只作为 Release 附件上传。
2. **内嵌 git 二进制改为「按需下载」**：放到 Release 资产（< 2 GiB），首次启动下载到 `~/Library/Application Support/FileVault/bin/`，校验 sha256 后使用；不要提交进仓库。
3. **演示素材/大截图**：放 Release 或文档外链；确需入库的少量素材走 LFS。
4. **本地 + CI 双保险**：提交前 hook 拦截，push/PR 时 CI 再扫一遍历史（见 3.3）。

### 3.3 已落地守卫

| 文件 | 作用 |
|---|---|
| `scripts/check-large-files.sh` | 检查暂存区或历史中的 blob 大小；≥ 50 MiB 警告，> 100 MiB 失败（退出码 1） |
| `.githooks/pre-commit` | 提交前自动执行 `--staged` 检查，直接阻止大文件进入本地历史 |
| `scripts/install-git-hooks.sh` | 一键启用 `.githooks`（`git config core.hooksPath`） |
| `.github/workflows/repo-size-guard.yml` | push / PR 时扫描全历史，防止有人用 `--no-verify` 绕过本地 hook |

使用方式：

~~~bash
./scripts/install-git-hooks.sh        # 每个克隆执行一次
./scripts/check-large-files.sh        # 手动全历史体检（默认模式）
./scripts/check-large-files.sh --staged   # 只查暂存区（hook 用）
./scripts/check-large-files.sh --history origin/main..HEAD  # 只查未推送提交
~~~

CI 或紧急情况下也可以直接用一条命令找出历史大文件：

~~~bash
git rev-list --objects --all |
  git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' |
  awk '$1=="blob" && $3 > 100*1024*1024 { printf "%.1f MiB  %s\n", $3/1048576, substr($0, index($0,$4)) }' |
  sort -rn
~~~

> 注意：`git rm` 只是让文件不再出现在**新提交**里，历史中的 blob 仍然存在，push 仍会被拒；必须重写历史（见第 5 节）。

---

## 4. 产品侧方案：FileVault 管理用户仓库时的 GitHub 防护

FileVault 的核心场景是「用户文件夹 → 本地 Git 仓库 → 自动 push 到 GitHub」。用户不会知道 100 MiB 限制，**产品必须在提交和推送两个环节替用户挡住**，否则会出现「本地一直成功、远程永远失败、菜单栏一直重试」的坏体验。

### 4.1 现状缺口（代码位置）

| 缺口 | 位置 | 后果 |
|---|---|---|
| 默认阈值 200 MB，高于 GitHub 硬限制 100 MiB | `Sources/FileVaultCore/RepoManager.swift:346`、`ConfigStore.swift:30`、`CommitEngine.swift:13` | 100–200 MB 的文件会被正常提交，push 必失败（**v3.1.3 已修复：本地阈值整体移除，阈值只来自远端**） |
| 只排除「新增」文件，不检查已跟踪文件的修改 | `RepoManager.swift:361`（`where e.change == .added`） | 一个已跟踪文件长到 150 MB，仍会被提交 |
| 未区分远端类型，阈值一刀切 | 全局配置 | 用户给 GitHub 仓库配 200 MB 阈值时没有提示（**v3.1.3 已修复：每仓库按远端解析**） |
| push 失败统一按瞬时错误指数退避重试 | `SyncManager.swift:107-140` | 体积超限是**永久错误**，重试永远不会成功，还反复弹通知 |
| 健康度只统计 `.git` 总大小 > 2 GB | `RepoHealth.swift` | 看不到「哪个文件超限」，用户无从下手 |
| 无历史大文件体检、无修复引导、无 LFS | — | 用户只能看到 GitHub 的英文报错 |

### 4.2 设计原则

1. **本地历史优先不变**：大文件不阻断本地自动提交，只阻断「进入版本库 / 推送」。
2. **口径只取远端**：GitHub 远端强制 100 MiB；其他远端不提供公开上限，就不设限（v3.1.3 起本地不再有阈值设置，远端是唯一权威）。
3. **可解释、可操作**：每一次跳过/阻断都要给出「文件、大小、原因、下一步」。
4. **不自动改写历史**：历史重写必须用户确认，并先导出备份。
5. **永久错误不重试**：网络/认证问题继续重试，体积问题立即停止并提示。

### 4.3 分层阈值

| 常量 | 值 | 行为 |
|---|---|---|
| `githubWarnBytes` | 50 MiB | 提交时提示「建议改用 LFS / 移出仓库」，但放行 |
| `githubBlockBytes` | 100 MiB | 不进入提交；已在历史中则 push 前阻断 |
| `githubLfsMaxBytes` | 2 GiB | 超过则 LFS 也无法承载，只能外部存储 |
| `repoRecommendedBytes` | 1 GiB | 健康面板黄色提示 |
| `repoHardBytes` | 5 GiB | 健康面板红色告警 |
| 本地阈值 | **已移除**（v3.1.3） | 不再接受用户配置；GitHub 远端 = 100 MiB，其他远端 = 0（不设限），UI 只展示远端值 |

远端判定：解析 `git remote get-url origin`，兼容 `https://github.com/...`、`git@github.com:...`、`ssh://git@github.com/...`；仅 `github.com` 命中内置限制，GitHub Enterprise 自定义域名先按普通远端处理（后续可配置）。

### 4.4 提交前守卫（P0，改动最小、收益最大）

在 `CommitEngine.runCommitPipeline` 中：

1. 读取远端 URL（`RepoManager.remoteURL`），计算 `effectiveThreshold`；
2. `excludeLargeFiles` 从「只看新增」扩展为「看新增 + 修改」；
3. 新增文件超限：写入 `.git/info/exclude`（现有机制）并记录原因；
4. **已跟踪文件**超限：不能靠 exclude 生效，改为 pathspec 排除暂存（`git add -A -- . ':(exclude,literal)<path>'`），保留本地文件；
5. 提交信息追加 `, 1 large file skipped`，并通过通知告知完整原因；
6. 每次排除结果进入 `onCommit` 回调，供 UI 展示。

建议的常量与接口：

~~~swift
public enum GitHubLimits {
    public static let warnBytes: UInt64 = 50 * 1024 * 1024
    public static let blockBytes: UInt64 = 100 * 1024 * 1024
    public static let lfsMaxBytes: UInt64 = 2 * 1024 * 1024 * 1024
    public static let repoRecommendedBytes: UInt64 = 1 * 1024 * 1024 * 1024
    public static let repoHardBytes: UInt64 = 5 * 1024 * 1024 * 1024

    /// github.com 远端 → 100 MiB；其他远端/无远端 → 0（不设限）。
    public static func effectiveThreshold(remoteURL: String?) -> UInt64
}

/// 被跳过的文件及原因，供提交信息与 UI 使用。
public struct SkippedFile: Equatable, Sendable {
    public var path: String
    public var bytes: UInt64
    public var reason: SkipReason   // .githubFileLimit / .userThreshold
}
~~~

边界：`.git/info/exclude` 只影响未跟踪文件，对已跟踪文件无效——这是现有实现会漏掉「文件长大后超限」的根因，必须单独处理。

### 4.5 推送前预检（P1，必须做）

提交前守卫只能挡住「从现在开始」的文件；如果用户先建了仓库、后绑定 GitHub，历史里可能已经有 300 MB 的 blob。push 前必须再查一次：

~~~bash
# 未推送的提交（首次 push 时 --remotes 为空，等价于全历史）
git rev-list --objects HEAD --not --remotes |
  git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' |
  awk '$1=="blob" && $3 > 100*1024*1024'
~~~

实现要点：

- 结果按 `HEAD` 缓存，避免每次重试都扫描；
- 命中时抛出专用错误 `PushBlockedError.oversizedBlobs([...])`，`SyncManager` 捕获后：
  - 状态置为「失败（含大文件）」而不是 `pendingPush`；
  - **不做指数退避重试**；
  - 同一 `HEAD` 只通知一次；
  - 菜单项提供「查看处理建议」，跳转帮助文档/体检面板；
- LFS 指针文件只有约 130 B，不会误报；
- 对超大仓库，扫描放到后台队列并限制输出（取 Top N），不要阻塞菜单栏。

错误分类是本次改造的关键：

| push 失败原因 | 分类 | 行为 |
|---|---|---|
| 网络超时 / 5xx / DNS | 瞬时 | 指数退避重试 |
| 认证失败 / 403 / 凭证过期 | 可修复 | 停止重试，触发认证巡检（现有 FR-16） |
| `GH001` / `file size limit` / `pre-receive hook declined` | **永久** | 立即停止，提示清理，不再重试 |

### 4.6 历史遗留大文件处理

体检入口（设置页「仓库健康度」旁）展示：最大 blob、超 100 MiB 的 blob 数量、Top 10 文件（路径/大小/首次进入的提交/是否已推送到远程）。

处理分两种情况：

**A. 只存在于本地、尚未推送的提交**

相对安全：这些 commit 重写后不影响任何人。推荐流程：

~~~bash
# 1) 先备份
git bundle create ~/Desktop/repo-backup-$(date +%F).bundle --all

# 2) 重写历史（需安装 git-filter-repo，brew install git-filter-repo）
git filter-repo --strip-blobs-bigger-than 100M

# 3) 检查
git log --oneline -5
git count-objects -vH

# 4) 重新绑定 remote 并推送
git remote add origin <url>
git push -u origin main
~~~

**B. 已经推送到 GitHub**

必须重写远程历史，影响所有协作者、fork 和未合并 PR：

~~~bash
git filter-repo --strip-blobs-bigger-than 100M
git push --force-with-lease origin main
~~~

注意事项：

- 提前通知协作者 `git fetch && git reset --hard origin/main`；
- fork 会保留旧对象，需要各自清理或删除重建；
- GitHub 侧旧对象不会立刻释放，仓库体积可能仍偏大；可联系 GitHub Support 请求 GC（引用 `GH001`）；
- 如果仓库历史价值不高、协作复杂，**新建一个干净仓库**通常比修历史更省事（FileVault 可提供「以当前文件重建远程仓库」按钮，本地旧历史打成 bundle 归档）。

FileVault 产品侧只做「检测 + 解释 + 复制命令 + 备份」，**不要静默执行历史重写**。

### 4.7 Git LFS 可选支持（P2）

- 检测 `git lfs version`；未安装时给出指引（Homebrew：`brew install git-lfs`；应用不擅自安装）；
- 每个仓库一个开关「用 Git LFS 管理大文件」，默认关闭；
- 开启后对常见二进制扩展名 `git lfs track`（`.psd .ai .sketch .mp4 .mov .zip .dmg .sqlite` 等），生成 `.gitattributes` 并提交；
- 明确提示：单文件 ≤ 2 GiB、免费 10 GiB 存储 + 10 GiB/月流量、克隆/CI 需要 LFS、超额会计费；
- 历史迁移 `git lfs migrate import --everything --include="*.psd"` 会**改写 commit**，必须走 4.6 的备份与确认流程；
- LFS 不是万能：它减少的是 Git 对象库压力，`.git/lfs` 仍占本地磁盘；超过 2 GiB 的文件只能外部存储。

### 4.8 可观测性与文案

`RepoHealth` 扩展：

~~~swift
public struct RepoHealth {
    public var commitCount: Int
    public var sizeBytes: UInt64
    public var lastCommitDate: Date?
    public var largestBlobBytes: UInt64        // 新增
    public var oversizedBlobCount: Int         // 新增，> 100 MiB
    public var pushRisk: PushRisk              // 新增：.ok / .nearLimit / .blocked
}
~~~

菜单栏/设置页文案示例：

- 正常：`✓ 已同步 · 最大文件 12 MB`
- 接近：`⚠️ 有 2 个文件 > 50 MB，建议移出仓库或改用 LFS`
- 阻断：`⛔ 含 1 个 320 MB 文件，GitHub 无法接收；点此查看处理方式`

### 4.9 实施计划与验收

| 阶段 | 内容 | 涉及文件 | 预估 |
|---|---|---|---|
| P0 | GitHub 阈值常量 + 远端判定 + 提交前排除（新增/修改）+ 通知文案 | `GitHubLimits.swift`（新建）、`RepoManager.swift`、`CommitEngine.swift`、`ConfigStore.swift` | 0.5 天（常量/远端判定/移除本地阈值已在 v3.1.3 落地） |
| P1 | push 前 blob 预检 + 永久错误不重试 + 健康度字段 + 设置页提示 | `SyncManager.swift`、`RepoHealth.swift`、`SettingsWindowController.swift`、`MenuBuilder` | 1 天 |
| P2 | 历史体检面板 + 修复命令/备份 + LFS 开关 + 帮助文档 | 新窗口控制器、`HistoryService`/`RepoManager`、`docs/` | 1.5 天 |

验收标准：

- [ ] GitHub 远端下，100–200 MB 的文件**永远不会**出现在新提交里（新增文件已达成，v3.1.3；已跟踪文件增长待补）；
- [ ] 已跟踪文件增长到 > 100 MiB 时，提交被跳过且用户收到可读提示；
- [ ] 历史含 > 100 MiB blob 时，push 前失败并停止重试，错误信息包含文件与大小；
- [ ] 网络类错误仍然按原逻辑重试，行为不回归；
- [x] 设置页**按仓库展示远端上限**（GitHub → 100 MB；其他远端 → 不限制），本地不再有阈值输入框（v3.1.3）；
- [x] 所有新增逻辑有单元/集成测试（v3.1.3：117 项测试全部通过）。

### 4.10 风险与取舍

| 风险 | 应对 |
|---|---|
| 误排除用户确实想版本管理的文件 | 提示中给出「移出仓库 / 改用 LFS / 换用无限制的远端」三条路；排除记录可见 |
| 用户用终端手动 push 仍可能被拒 | 文档说明 + 应用内体检；终端场景无法拦截，但可在下次刷新时提示 |
| 历史重写破坏协作 | 强制备份 bundle、二次确认、文档步骤；默认不自动执行 |
| 扫描大仓库耗时 | 仅 push 前扫描未推送范围，按 HEAD 缓存，后台执行 |
| LFS 配额超限 | 开启前展示额度与计费；超出后 GitHub 只返回指针文件，健康度面板红色告警 |

---

## 5. 应急手册：现在已经被 GitHub 拒绝了

按顺序执行，**不要**直接反复 `git push`。

### 5.1 判断大文件在哪

~~~bash
# 工作区里超过 95 MiB 的文件
find . -type f -size +95M -not -path './.git/*'

# 最近一次提交是否包含大文件
git show --stat HEAD

# 全历史中的大文件（Top 20）
git rev-list --objects --all |
  git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' |
  awk '$1=="blob" && $3 > 100*1024*1024' |
  sort -k3 -rn | head -20
~~~

### 5.2 情况一：大文件只在最新一次提交（还没 push 成功）

~~~bash
git rm --cached path/to/big.mp4        # 只从索引移除，本地文件保留
echo "path/to/big.mp4" >> .git/info/exclude   # 或 .gitignore
git commit --amend --no-edit
git push
~~~

### 5.3 情况二：大文件已在历史中

先备份，再二选一：

~~~bash
# 方案 A：git-filter-repo（推荐，快且干净）
brew install git-filter-repo
git bundle create ~/Desktop/backup-$(date +%F).bundle --all
git filter-repo --strip-blobs-bigger-than 100M
git push --force-with-lease origin main

# 方案 B：BFG（Java）
brew install bfg
git bundle create ~/Desktop/backup-$(date +%F).bundle --all
bfg --strip-blobs-bigger-than 100M
git reflog expire --expire=now --all && git gc --prune=now --aggressive
git push --force-with-lease origin main
~~~

force push 前确认：分支没有保护规则、协作者已知晓、fork/PR 已评估。推送后如仓库体积不降，联系 GitHub Support 清理不可达对象。

### 5.4 情况三：历史/协作太复杂

新建干净仓库，把当前工作区作为第一个 commit：

~~~bash
# 在旧仓库里先归档历史
git bundle create ~/Desktop/old-history.bundle --all

# 新建仓库（保留文件、不保留历史）
rm -rf .git
git init -b main
git add .
git commit -m "chore: 重新初始化仓库（旧历史见 bundle 归档）"
git remote add origin <new-repo-url>
git push -u origin main
~~~

对 FileVault 用户，这对应产品里的「重建远程仓库」动作，必须在 UI 里明确提示「旧历史仅本地保留」。

---

## 6. 验收清单（方案级）

- [ ] 团队/产品对「默认不进 Git」达成一致，LFS 仅作为例外；
- [ ] 本仓库启用 hook + CI，历史扫描通过（当前无 > 5 MB blob）；
- [ ] FileVault 产品 P0 落地：GitHub 远端阈值 ≤ 100 MiB，100–200 MB 文件不再进入提交；
- [ ] FileVault 产品 P1 落地：push 前预检、永久错误不重试、健康度可解释；
- [ ] 发布流程固定为「构建 → 上传 Release 资产」，`dist/` 永不入库；
- [ ] 内嵌 git 二进制方案改为运行时下载 + sha256 校验；
- [ ] 应急手册进入用户帮助文档，UI 报错能一键跳转。

---

## 7. 参考

- [About large files on GitHub](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github)
- [About Git Large File Storage](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-git-large-file-storage)
- [Git LFS billing](https://docs.github.com/en/billing/concepts/product-billing/git-lfs)
- [About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)
- [git-filter-repo](https://github.com/newren/git-filter-repo)
- [BFG Repo-Cleaner](https://rtyley.github.io/bfg-repo-cleaner/)
- [git-lfs migrate](https://github.com/git-lfs/git-lfs/blob/main/docs/man/git-lfs-migrate.adoc)
