# 坑清单

每条都是“看代码看不出来、但会让功能出错”的事实。新增时按“结论 → 原因 → 证据 → 规避”写。

## 云盘占位符会被 Git 当成删除

- 原因：iCloud Drive / Dropbox / OneDrive / Google Drive 的“按需下载”把文件换成占位符，git 看来就是文件被删。
- 证据：README:13（v4.2.13）
- 规避：受保护文件夹放本地目录，或关闭该目录的按需下载；设置页已给出提示。

## 文件名必须按 NUL 解析，不能按行切

- 原因：文件名里可能有空格、换行、引号甚至 `->`；按行解析 git status 会把重命名拆错、把一条记录当成两条。
- 证据：README:13（v4.2.10）
- 规避：新增任何解析 git 输出的代码，一律走 NUL 分隔（`-z`）。

## .git 丢失不等于“没有改动”

- 原因：受保护文件夹的 `.git` 被删后重新初始化会得到空历史，用户会以为版本都在。
- 证据：README:13（v4.2.8）
- 规避：初始化前判断该目录是否曾受保护；重新初始化必须通知并提示重填远程地址。

## github.com 远端有 100 MB 单文件硬限制

- 原因：超过上限的文件推送必然失败，重试也没用。
- 证据：README:22（v4.2.6）；上限跟随远端，本地不设阈值。
- 规避：超限文件排除时必须通知用户“这些文件没有备份”，不能静默排除。

## 同一文件夹只能被一个实例管理

- 原因：两个 FileVault 同时跑（例如“应用程序”里的旧版和设置里的新版）会重复提交与推送。
- 证据：README:13（v4.2.9）
- 规避：以“谁先运行谁管理”为准，另一个实例显示“另一个 FileVault 实例正在管理”，前一个退出后自动接管。

## 回滚/恢复前必须检查未纳入版本管理的文件

- 原因：`.env` 这类被忽略的文件不在 git 里。恢复目录会删掉它们；整仓回滚与单文件恢复的 `reset --hard` / `checkout` 还会**覆盖**同名文件——被覆盖的内容不在任何提交里，隐藏备份 ref 也救不回。
- 证据：`Sources/FileVaultCore/RepoManager.swift` 的 `ignoredFilesInTheWay`/`ignoredConflicts`（回滚前求交集）、`isIgnoredUntracked`（单文件恢复）、`HistoryExtras.restoreDirectory`（目录恢复，v4.2.27 起三处护栏齐全）；README「核心功能」第 7 条（v4.2.16）
- 规避：任何改写工作区的操作先算「目标提交树 ∩ 当前 ignored/untracked」，命中就拒绝并列出文件，绝不静默覆盖。

## git status 失败不等于“没有改动”

- 原因：`status()` 曾把非 0 退出压成 `[]`，强制拉取/合并/恢复据此判断“干净”，随后 `reset --hard` / `checkout` 覆盖未提交内容。
- 证据：Sources/FileVaultCore/RepoManager.swift:121（v4.2.25）
- 规避：任何“是否脏”的安全判断都必须区分“无改动”和“读不到”，读不到就拒绝执行。

## git credential approve 在没有助手时仍返回 0

- 原因：`approve` 只把凭证交给已配置的助手；助手不存在时它照样成功，令牌被静默丢弃。判断助手是否存在也不能只看 127：git 对未知子命令返回 1。
- 证据：Sources/FileVaultCore/CredentialStore.swift:58（v4.2.25）
- 规避：按 stderr 的 “is not a git command” 判定不可用；写入后再 `fill` 读回校验。

## 写进 .git/info/exclude 的路径必须转义

- 原因：文件名里的 `[]*?` 会被 gitignore 当成通配符，规则匹配不到文件，大文件仍被提交并推送失败，界面却提示“已排除”。
- 证据：Sources/FileVaultCore/RepoManager.swift:1830（v4.2.25）
- 规避：规则按字面转义后用 `git check-ignore -q` 自校验，再决定是否告诉用户“已排除”。
## git pathspec 默认按 glob 解释，用户文件名必须字面化

- 原因：`git checkout <hash> -- a[1].txt` 会同时匹配 `a1.txt`，恢复一个文件会连带改写兄弟文件。改用全局 `--literal-pathspecs`，但 **`git check-ignore` 不接受该 magic，会直接 fatal**，必须单独跳过。
- 证据：`Sources/FileVaultCore/GitRunner.swift:98`（check-ignore 例外）、`GitRunner.swift:104`（默认字面化）；`RepoManager.swift:811`
- 规避：新增把用户路径交给 git 的代码，先确认命令是否支持 literal magic；不支持时换实现（如 check-ignore 用原样路径名），并补回归测试。

## JSONEncoder 默认转义 `/`，会让文本脱敏全部失效

- 原因：诊断包先 `JSONEncoder` 编码再按文本替换 `/Users/<name>`；默认输出 `"\/Users\/<name>"`，home 替换与 `/Users/` 正则都匹配不到，报告泄露完整账户路径。
- 证据：`Sources/FileVaultCore/SupportBundle.swift:57`（`.withoutEscapingSlashes`）、`SupportBundle.swift:142`（masked 先规范化 `\/`）
- 规避：对 JSON 文本脱敏前先解码/重编码为不转义斜杠形式，或直接在结构化对象上脱敏；必须补「含转义斜杠」的回归测试。

### 大小写变体会绕过精确匹配的护栏（v4.2.27）

- 结论：恢复/回滚护栏必须做大小写折叠比对——macOS 默认卷上 `Notes.txt` 与 `notes.txt` 是同一个文件。
- 原因：`ls-files` 的 pathspec 匹配是大小写敏感的（即使 core.ignorecase=true），磁盘上的被忽略 `Notes.txt` 查 `notes.txt` 返回空；`git checkout/reset` 在大小写不敏感卷上照样 exit 0 覆盖同一个磁盘文件。而 `check-ignore` 的 gitignore 匹配本身折大小写——两个命令行为不一致就是缺口所在。
- 证据：`RepoManager.ignoredConflicts`（折叠比对）、`isIgnoredUntracked`（check-ignore+未跟踪+磁盘存在三重信号）；`AuditV427Tests.testResetRepoRefusesIgnoredCaseVariant`；2026-11-17 /tmp APFS 实验。
- 规避：新增任何「路径 A 是否等于路径 B」的安全判断时，先问卷区大小写敏感性；比较用折叠匹配，报告磁盘上的真实名字。

### askpass=echo 会把提示语当成凭证（v4.2.27）

- 结论：`git credential fill` 想探测「有没有已存凭证」时，askpass 绝不能是 `echo`。
- 原因：没有存储凭证时 git 会调用 askpass，`echo` 把 "Username for '...':" 原样返回为 username/password（exit 0），探测得到垃圾值——「请填令牌」提示永不出现。
- 证据：`CredentialStore.fill`（GIT_ASKPASS=/usr/bin/true + 空值兜底）；`AuditV427Tests.testCredentialFillReturnsNilWithoutStoredCredential`。
- 规避：无凭证探测要用「无输出即失败」的 askpass（/usr/bin/true），并校验返回值非空。

### 字符串插值只包住第一个 `\(...)`（v4.2.28）

- 结论：往 ref 名 / 路径里拼随机后缀时，每个变量都必须各自被 `\(...)` 包住，否则后半截会变成字面量源码文本。
- 原因：v4.2.27 写作 `"refs/filevault/backup/\(Self.backupStamp())-(UUID().uuidString.prefix(4))"`——只有 `backupStamp()` 在插值里，`-(UUID().uuidString.prefix(4))` 是普通字符。同一秒内的三次快照因此拿到同一个 ref 名，后一次 update-ref 覆盖前一次，被推开的 HEAD 失去引用（gc 可达）。
- 证据：`RepoManager.resetRepo` / `forcePull` / `mergeSync` 三处备份 ref；`AuditV428Tests.testResetRepoBackupRefsAreUniqueWithinTheSameSecond`（断言 `<yyyyMMdd-HHmmss>-<4 hex>` 且不含 `(`）。
- 规避：生成 ref / 路径后加断言或测试钉住格式；review 时看一眼 ref 名里有没有源码文本片段。

### MenuBarExtra 面板高度就是内容高度（v4.2.29）

- 结论：菜单弹层面板即窗口本身——最后一行下方的任何额外 padding 都会渲染成一条空白带；分区表达用卡片，不要用横穿分隔条。
- 原因：v3.2 的 quitRow 在行自身 6pt 底边距外又叠 4pt，面板底部收出 ~10pt 空白带，用户两次指出「无用的横条」；320pt 宽的弹层里 hairline 分隔条也显得零碎。
- 证据：空白带修复 d2b39b6、卡片化重设计 de53b8f（MenuContentView.swift 的 FVMenuCard）；开发渲染像素实测：字形底 y=1074 / 面板底 y=1077（2x）。
- 规避：改菜单布局时保持四边 12pt 对称外边距；新增分区用 FVMenuCard 包裹；最后一行永远不加额外 bottom padding，也不要重新引入 panelDivider。
