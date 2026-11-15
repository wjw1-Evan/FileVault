# 07 · Git 自动安装与下载镜像源（FR-01）

> 一句话结论：**用户机器上没有 git 时，FileVault 先用应用自带的 git（零下载）；没有自带才联网，按 5 个镜像地址逐个尝试，逐个 sha256 校验；全部失败才回退 Apple 的 Xcode CLT。** 用户不会卡在"下载失败"死路上。

## 1. 改之前是什么样的（问题）

旧实现 `GitEnvGuard.install()` 只有两条路：

1. 找 `FileVault.app/Contents/Resources/git` —— 但打包脚本从来没往里放过任何东西，等于永远不存在；
2. 直接 `/usr/bin/xcode-select --install`，弹 Apple 的系统对话框，下载 **Xcode Command Line Tools（约 1.5 GB）**。

所以"自动安装 git"实际是"引导用户去装 1.5 GB 的开发者工具"：需要管理员密码、卡住无法取消、国内网络下 `swcdn.apple.com` 常常几十 KB/s 甚至直接失败。这正是"网络不通畅"风险的来源。

## 2. 改之后：三层策略（先省网络，再谈下载）

| 顺序 | 策略 | 需要联网 | 体积 | 大致耗时 | 失败后 |
|---|---|---|---|---|---|
| 1 | **内嵌 git**（`Contents/Resources/git`） | 否 | App 内已有 | 0 | 进入第 2 层 |
| 2 | **镜像下载**自包含 git（5 个地址逐个试，校验 sha256） | 是 | 63.5 / 67.5 MB | 1–10 分钟（视镜像） | 进入第 3 层 |
| 3 | **Xcode CLT**（`xcode-select --install`） | 是 | ~1.5 GB | 很长，且要系统弹窗 | 报错并说明原因 |

顺序上有两个原则：

- **能用本地的绝不上网**：已内嵌或已下载过（`~/Library/Application Support/FileVault/git/<版本>-<架构>/bin/git`）就直接用，绝不重复下载；
- **能自己下载的绝不弹 Apple 的大包**：CLT 只在最后兜底。

代码位置：
- `Sources/FileVaultCore/GitProvisioner.swift`：下载 / 校验 / 解压 / 安装 / 环境变量
- `Sources/FileVaultCore/GitEnvGuard.swift`：三层策略链 + 定位（含已下载的 git）
- `Sources/FileVaultCore/GitRunner.swift`：给自包含 git 注入 `GIT_EXEC_PATH` 等环境变量

## 3. 下载的是什么（版本 + 校验和锁定）

上游用 **desktop/dugite-native**：GitHub Desktop 同款、自包含的 macOS git 打包（git + curl + openssl + CA 证书都在包内，不依赖 Xcode / Homebrew / /usr/local）。架构、版本、大小、sha256 全部**写死在代码里**（`GitBuildCatalog`），任何地址下载到的文件都必须与校验和一致才会被解压使用。

当前锁定版本：**git 2.56.1**（dugite-native `v2.56.1-238326e`，2026-11-10 发布）

上游包解压后约 **150 MB**，其中约 110 MB 是用不到的 **Git Credential Manager**（自带 .NET/Avalonia 运行时的 GUI 程序）。FileVault 的凭证走 gh / 钥匙串 / SSH，从不调用 GCM，所以**校验通过后会把 GCM 相关文件删掉**（`*.dll`、`*.dylib`、`createdump`、`git-credential-manager*`、GCM 的本地化目录），装好的 git 从 150 MB 降到约 **40 MB**。删除有护栏：只有检测到 GCM 启动器时才删、只删 `libexec/git-core` 里的、删完立刻再跑一次 `git --version` 验证。

| 架构 | 文件名 | 大小（字节） | sha256 |
|---|---|---|---|
| Apple Silicon | `dugite-native-v2.56.1-238326e-macOS-arm64.tar.gz` | 63,505,330 | `a882ec6882416b57d212a22bac845ae27944f96cf73453a864f6a12c17863a79` |
| Intel | `dugite-native-v2.56.1-238326e-macOS-x64.tar.gz` | 67,474,588 | `3fdb0c2f102fe0273d64b5d5fb77315c19f2b4648a154593723cb9ed98f2bc7d` |

Rosetta 说明：如果 x86_64 版 App 跑在 Apple Silicon 上，会通过 `sysctl hw.optional.arm64` 识别宿主架构，下载 arm64 的包，而不是让用户继续用模拟版 git。

**为什么不用其他来源**

| 候选 | 结论 |
|---|---|
| git-scm.com 官方 macOS 下载页 | 只给源码，macOS 二进制作者在 SourceForge + Homebrew + CLT 三个去处 |
| SourceForge `git-osx-installer` | `latest/download` 实测解析到 **git 2.6.2（2015 年）**，太旧，且有安装包弹窗 |
| Homebrew bottle | 可以，但 git 依赖一串库（pcre2/openssl/curl/gettext…），还要求用户先装 Homebrew、写 `/opt/homebrew`，不适合"普通人零配置" |
| Xcode CLT | 1.5 GB + 管理员弹窗，只配当兜底 |

## 4. 镜像阶梯（多准备下载地址，就是这个列表）

`GitMirror.defaultLadder`，按顺序尝试，任一成功即停止：

| # | id | 地址模板 | 2026-11-15 实测（国内网络，无代理） |
|---|---|---|---|
| 1 | github | `https://github.com/desktop/dugite-native/releases/download/{tag}/{asset}` | 首块 4 MB 用 9.8 s ≈ **427 KB/s**；但整包下到 36% 断流，需重试/续传 |
| 2 | ghfast | `https://ghfast.top/https://github.com/.../{tag}/{asset}` | ≈ **302 KB/s**，稳定 |
| 3 | gh-proxy | `https://gh-proxy.com/https://github.com/.../{tag}/{asset}` | ≈ **90 KB/s**，可用但慢 |
| 4 | ghproxy-cfd | `https://ghproxy.cfd/https://github.com/.../{tag}/{asset}` | ≈ **20 KB/s**，最后手段 |
| 5 | filevault | `https://github.com/wjw1-Evan/FileVault/releases/download/git-{version}/{asset}` | **已上线**：release `git-2.56.1` 已上传 arm64/x64 两个包（206 可下，sha256 与代码锁定值一致），完全自己控制 |

实测**当前不可用**（2026-11-15，已从默认列表剔除，保留记录供以后复查）：

`ghproxy.net`、`hub.gitmirror.com`、`ghp.ci`、`gh.llkk.cc`、`ghproxy.cc`、`github.moeyy.xyz`、`mirror.ghproxy.com`、`gh.6yit.com`、`gh.xxooo.cf` —— 连接失败或返回非文件内容。

可用的中国大陆镜像站（2026-11-15 探测可达，作为**备选思路**记录）：清华 TUNA / 中科大 USTC / 阿里云 / 腾讯云的 Homebrew bottles 镜像、`registry.npmmirror.com`。它们不直接托管 dugite 包，所以没有进默认列表；如果将来要把包托管到自有对象存储（OSS/COS）或 Gitee Release，加到 `GitMirror.defaultLadder` 即可，无需改别的代码。

## 5. 失败如何转移（不是"死等一个地址"）

| 关卡 | 判定 | 结果 |
|---|---|---|
| 连接 | 10 s 连不上 | 换下一个地址 |
| 传输 | 60 s 没有任何数据（idle）或单地址总预算 600 s 超时 | 中断，换下一个地址 |
| 完整性 | 文件大小不符 / **sha256 不符** | 删掉，换下一个地址（绝不使用可疑文件） |
| 解包 | `tar` 失败 / 包里没有 `bin/git` | 换下一个地址 |
| 可用性 | `git --version` 跑不起来 | 换下一个地址 |

全部失败时抛 `GitEnvError.provisionFailed`，错误文案**逐条列出每个地址的失败原因**（连接超时 / DNS 解析失败 / TLS 握手失败 / 校验失败…），并同时：

- 发系统通知（"Git 环境未就绪" + 具体原因）
- 主面板状态行显示原因（不再是一句无信息的"Git 环境未就绪"）
- 继续走第 3 层 Xcode CLT 兜底

## 6. 自包含 git 需要导出的环境变量

下载/内嵌的 git 不在系统默认路径上，`GitRunner` 会按 payload 目录自动注入（`baseEnvironment`）：

| 变量 | 值（相对 payload 根） | 作用 |
|---|---|---|
| `GIT_EXEC_PATH` | `libexec/git-core` | 子命令（`git-add` 等）所在目录；不设会警告 templates not found |
| `GIT_TEMPLATE_DIR` | `share/git-core/templates` | `git init` 模板 |
| `GIT_SSL_CAINFO` | `ssl/cacert.pem`（**可选**：当前 payload 未附带，代码只在文件存在时才设） | HTTPS 根证书 |
| `PATH` | 追加 Apple 的 `git-credential-osxkeychain` 目录（`/usr/libexec/git-core`、CLT/Xcode 的 `usr/libexec/git-core`） | **关键**：payload 不自带 osxkeychain 助手，不加这个目录，钥匙串里的 HTTPS 凭证就取不到 |

实测：加上 PATH 后，用内嵌 git 执行 `git credential fill` 能正常从钥匙串取到用户名 —— 凭证能力与系统 git 一致（前提是这台 Mac 有 Xcode / CLT 提供助手；没有时改走 gh 助手或 SSH，并在设置里提示）。

系统 git（`/usr/bin/git`、Homebrew）不会注入这些变量，保持原有行为。

## 7. 打包时把 git 内嵌进 App（最稳的"防网络不通"）

```bash
./scripts/vendor-git.sh --arch all     # 下载 + 校验 + 解压到 build/vendor/git/{arm64,x64}
./scripts/make_app.sh 4.0.0            # 自动拷进 Contents/Resources/git
```

- 内嵌后**首次启动完全不需要网络**，FR-01 的第 1 层直接命中；
- 体积代价：下载 arm64 包 63.5 MB / x64 包 67.5 MB；剔除 GCM 后打进 App 的 git 约 **40 MB**（实测 `build/FileVault.app` 总计 44 MB）；
- 提审/公证：make_app.sh 的签名步骤在拷贝之后执行，`--deep` 会一并给内嵌 git 签名。

实测输出：

```
==> dugite-native-v2.56.1-238326e-macOS-arm64.tar.gz
  已缓存且校验通过
  已移除 GCM（.NET 运行时）
  git version 2.56.1
  体积:  40M	build/vendor/git/arm64
```

## 8. 维护手册

**升级 git 版本**

1. 取上游 `desktop/dugite-native` 最新 release 的 assets（`sha256` 用 GitHub API 的 `digest` 字段或 `shasum -a 256`）；
2. 改 `Sources/FileVaultCore/GitProvisioner.swift` 的 `GitBuildCatalog`（version / tag / asset / sha256 / size）；
3. 同步改 `scripts/vendor-git.sh` 顶部四个常量（VERSION / TAG / ASSET_VERSION_TOKEN / ASSET_SHA）；
4. 更新本文档第 3 节表格；
5. `swift test --filter GitProvisionerTests`（含"清单自洽"测试）。

**更新自建镜像（第 5 个地址）**

```bash
# 注意：必须加 --prerelease，否则这个"资源发布"会抢到 releases/latest，
# 让 App 的自动更新拿到错误的最新版本（更新器只认 vX.Y.Z 应用发布）。
gh release create git-2.56.1 --prerelease --title "git 2.56.1 镜像包" \
  --notes "sha256 / 大小见 docs/07" \
  dugite-native-v2.56.1-238326e-macOS-arm64.tar.gz dugite-native-v2.56.1-238326e-macOS-x64.tar.gz
# 上传后确认 latest 仍是应用版本：
gh api repos/wjw1-Evan/FileVault/releases/latest --jq .tag_name
```

文件名必须与 `GitBuildCatalog` 里的 `asset` 完全一致，否则 App 端拼出的 URL 404。

**镜像失效**

改 `GitMirror.defaultLadder`（删、调顺序、加新地址），跑同一套测试，发版。默认列表的测试会校验：至少 3 个地址、顺序以 GitHub 开头、每个模板都能展开成合法 URL、id 唯一。

## 9. 验证记录（2026-11-15，本机实测）

| 验证项 | 结果 |
|---|---|
| 官方 sha256 | 下载到的 63,505,330 字节包与锁定值 `a882ec…5ba4` 一致 |
| 解包布局 | `bin/git`、`libexec/git-core`、`share/git-core/templates` 平铺在根，与定位逻辑一致 |
| 版本 | `git version 2.56.1`（cpu: arm64） |
| 基础操作 | init / add / commit / log / status（含中文目录）/ branch / restore / gc 全部正常 |
| 远程能力 | `git ls-remote https://github.com/...` 可通（HTTPS/TLS 正常） |
| 凭证 | 加上 PATH 后 `git credential fill` 能从钥匙串取到已存用户名 |
| 第 1 层（内嵌） | `make_app.sh` 后 `FileVaultApp --smoke` → `source=bundled`，**SMOKE OK** |
| 第 2 层（已下载） | 隐藏内嵌 git、在 `~/Library/Application Support/FileVault/git/2.56.1-arm64` 放置同一 payload → `source=downloaded`，**SMOKE OK** |
| 单测 | `swift test`：245+ 项全绿；新增 `GitProvisionerTests` 覆盖镜像回退、sha256 拒绝、断流、超时、缓存复用、GCM 剔除 |
| 下载实况 | 直连 GitHub 首块 427 KB/s，但整包下到 55 MB 时断流；换 `ghfast.top` 续传（`curl -C -`）后完成，全程约 10 分钟 → 这正是需要多镜像 + 断点记录的原因 |

## 10. 已知边界

- 内嵌 git 只覆盖**构建机架构**（因为 `swift build` 产物本身是单架构）；做 universal 包需要额外把 git 也做 universal 合并，目前不在范围内。
- 下载在应用启动早期的后台 Task 里进行，进度只体现在菜单状态与通知，不阻塞主窗口。
- 走系统代理设置；若企业代理需要认证，URLSession 会失败 → 回退 CLT 或提示手动安装。
- 不会静默安装 Homebrew，也不会调用 `sudo`。
- payload 不自带 `git-credential-osxkeychain`：有 Xcode/CLT 的机器靠 PATH 借用 Apple 的助手（已验证）；完全没有开发者工具的机器上，凭证走 gh 助手 / SSH，或按设置页提示改用令牌（不会静默失败）。
- x64 payload 的 sha256/大小来自上游 release 元数据，但**尚未在 Intel 机器上实跑**；改用 payload 前请在 Intel 机器上执行一次 `--smoke`。
