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

### 假 git 脚本匹配参数必须全量扫描，不能看 `$1`（2026-11-19）

- 结论：给 GitRunner 写假 git 夹具时，判断参数要用 `for a in "$@"` 全量扫描——GitRunner 对所有调用预置 `--literal-pathspecs -c …`，真正的子命令不在 `$1`，按 `$1` 匹配的假脚本永远打不中（先红过一轮才定位到）。
- 原因：GitRunner.swift 的参数前置序列把用户子命令推到了第 N 个位置。
- 证据：Tests/FileVaultTests/ConnectivityProbeContractTests、CredentialStoreProbeTests（全量扫描写法）；slow-git 包装器同款。
- 影响：新增任何进程注入类测试（Connectivity/CredentialStore/GhRepoCreator 模式）先抄这两个文件的参数扫描姿势。

### JS 生成 Swift 源码必须 String.raw 标签模板（2026-11-19）

- 结论：用 JS 模板字面量生成 Swift 测试源码时必须 `String.raw` 标签，否则 `\n`、`\(` 被 JS 转义层吞掉，落盘的 Swift 语义悄悄变化。
- 证据：complete-tests 轮两个测试文件先红一次后修正；落盘内容需逐一复核。
- 影响：agent 写测试文件时的高频坑；写完必读落盘原文而不是内存里的字符串。

### --render-* 截图在无屏幕录制权限的 shell 下静默全空白（2026-11-19）

- 结论：CGWindowListCreateImage 没有 TCC 屏幕录制权限时返回**非 nil 的空白图**，render 流程照样打印 "rendered: path"——不能凭退出码判断截图有效。
- 原因：captureAndExit 拿到 image 就写盘退出，权限缺失不报错。
- 证据：Sources/FileVaultApp/AppState.swift 的 captureAndExit；2026-11-19 实测四窗口全白，screencapture -x 同 shell 报 "could not create image from display"。
- 影响：验证 UI 改动前先确认宿主终端有屏幕权限；无权限就改走测试断言 + diff 审查，别把空白 PNG 当成"窗口没内容"的 bug 排查。

### 取代运行中的推送循环必须认领 pushGenerations 槽位（v4.2.31）

- 结论：cancel 掉推送循环后必须递增 `pushGenerations[repo]`，否则旧循环的 finishPushLoop 仍“拥有”槽位：它会吞掉 `needsPushAgain` 并在 300ms 后重启新循环，与手动推送并发跑第二个 `git push`，绕过 manualPushes 护栏。
- 原因：Task.cancel 打不断已在 git 子进程里的 await；finishPushLoop 只校验代际归属，不感知「被谁取代」。
- 证据：`SyncManager.pushNow` / `configureRemote`（v4.2.31 递增代际）；`SyncPushGenerationTests`（未修复代码上实测变红）。
- 影响：新增任何「打断/取代推送循环」的入口都要同样认领代际；`reset()` 用清空代际达到同效，勿只 cancel task。
- 修正（2026-11-19）：认领代际只堵了 finishPushLoop 的重启门——**enqueuePush 在 task==nil 时会直接 startPushLoop**，换绑（configureRemote/clearRemote）期间一次自动提交照样把内容推到旧远程。修法是 `reconfiguringRepos` 槽位持有：enqueuePush 见持有即记 needsPushAgain 返回，configureRemote 尾部清标记后自己 enqueue（`SyncManager`，`SyncPushGenerationTests.testRebindHoldsPushSlotAgainstCommitsLandingMidSwap` 实测变红转绿）。教训：守卫「重启」的门类，先枚举所有「启动」的门。

### sweep 会复活刚被移除的根：removeRoot 必须先落盘配置（v4.2.31）

- 结论：removeRoot 要先把配置移除写盘再做运行时清理；sweepOnce 重挂前后都要重读配置确认根仍在列表，否则并发 sweep 会给已移除文件夹留下「僵尸 watcher」继续提交并推送。
- 原因：sweep 的 config 快照在 removeRoot 的 await 期间过期；旧代码到函数尾部才 saveConfig，sweep 重挂只看旧快照。
- 证据：`FileVaultService.removeRoot` / `sweepOnce`（v4.2.31 前置 saveConfig + 挂前/挂后配置校验）；`SweepRaceGuardTests.testSweepDoesNotResurrectRootRemovedMidAttach`。
- 影响：绕过 removeRoot 直改 configStore 会造成 attached-但未配置 的不一致态，sweep 的挂后校验会 removeRoot 兜底清掉。
- 修正（2026-11-19）：第一循环修了，**第二个自愈循环（watchers 快照 + commitSerialized）同样会复活**：快照先取、循环体有 await 挂起点，移除落在挂起点后，循环对已移除根 startWatching 复活僵尸 watcher 并提交其脏改动。修法：每轮迭代开头重验 `isStillConfigured`，else 分支 attach 后同样校验回滚（`FileVaultService.sweepOnce`，`SweepRaceGuardTests.testSweepSelfHealSkipsRootRemovedMidLoop` 用 2000 文件慢迭代造窗口实测变红转绿）。教训：sweep 里每个带 await 的循环都要当作「快照可能过期」处理，逐轮重验。

### 注销根要连失败重试状态一起清（v4.2.31）

- 结论：CommitEngine.unregisterRoot 必须清 failureCounts，否则已排定的自动提交重试（scheduleRetry 只看 failureCounts>0）会在用户移除/迁移文件夹后照常提交它。
- 证据：`CommitEngine.unregisterRoot`（v4.2.31）；`CommitEngineRetryCleanupTests.testPendingRetryDiesWhenRootIsUnregistered`。
- 影响：新增「忘记一个根」的路径都要走 unregisterRoot，不能只停 watcher。

### GitHub 超限与分支保护的拒绝摘要行相同，分类先看大小（v4.2.31）

- 结论：deterministicPushRejection 必须先匹配文件超限字样（exceeds GitHub's file size limit）再匹配 pre-receive hook declined / remote rejected。
- 原因：GitHub 超限推送同样以 `! [remote rejected] … (pre-receive hook declined)` 结尾，旧顺序把超限报成「去调分支保护」，大小指引永远走不到。
- 证据：`SyncManager.deterministicPushRejection`（v4.2.31 顺序调整）；`PushRejectionClassificationTests`（未修复代码上实测变红）。
- 影响：新增拒绝分类时先问一句：真实远端 stderr 里哪些短语会互相 shadow，把最具体的放前面。

### MenuBarExtra 弹层已自带材质，面板不要再画不透明底色（v4.2.33）

- 结论：菜单弹层窗口背景就是系统半透明菜单材质；面板里任何不透明填充（`FVTheme.card`/`windowBackgroundColor`，浅色下都接近纯白）都会渲染成贴在系统表面的白方块。
- 原因：v4.2.29 为「与窗口统一设计语言」给每个分区套了不透明卡片底板，结果用户报「菜单有白色背景」；v4.2.33 移除了底板与描边，分区只靠留白分隔。
- 证据：真实弹层截图对比 `/tmp` 实测（浅色像素 255,255,255 → 239,238,237 即材质色）；`MenuContentView.swift` 的 FVMenuCard；提交 de53b8f 引入、本次移除。
- 规避：改菜单面板时只用留白 / 圆角悬停药丸表达层次；`--render-menu` 的预览窗口是普通窗口，画不出真实材质，别用它判断透明度，需用 `screencapture -l<弹层窗口号>` 抓真实弹层。
- 注意：面板高度仍是内容高度（v4.2.29 结论不变）——最后一行下方不要加额外 padding，四边保持 12pt 对称外边距，不要重新引入分隔条。

### 菜单字号与行高用系统实测值，不要手调（v4.2.34）

- 结论：菜单栏面板的字体、行高、内边距一律取系统实测值——**字体 `NSFont.menuFont` = 13pt**、**行高 24pt**、**纵向内边距 10pt**、**横向内缩每边 16pt**；SwiftUI 侧对应 `.body` / `.headline` / `.caption` / `.caption2`，不要写 `.system(size: 11.5)` 这类手调字号。
- 原因：手调字号会让菜单与系统 Wi-Fi / 控制中心菜单在字重与行距上「差一点但说不清」，用户能直接感觉到「不像系统菜单」；工具行缩字号尤其明显（曾 11pt vs 12pt）。
- 证据：`NSFont.menuFont(ofSize: 0).pointSize` = 13.0；`NSMenu.size.height` 对条目数最小二乘 → rowHeight 24.0 / padding 10.0；菜单宽度减标题渲染宽度 → 横向 32pt。取值集中在 `FVTheme.Menu`（`DesignSystem.swift`），渲染实测行距 24.05pt vs 系统 24.0pt。
- 规避：改菜单版式先跑一段 AppKit 探针拿实测值再写常量；不要用 `--render-menu` 截图目测字号，改用像素测行距验证。

### 菜单配色只准用系统语义色，禁止手调透明度凑灰（v4.2.33）

- 结论：菜单行的悬停/选中高亮用 `NSColor.unemphasizedSelectedContentBackgroundColor`（浅色 `#DCDCDC` / 深色 `#464646`），**不要**用 `Color.primary.opacity(0.06)` 这类手调灰；图标走 `.primary/.secondary` 标签层级，不要硬编码 `.orange`；头部不要用 `.opacity(0.95)→(0.62)` 渐变 + 彩色投影（那是 iOS 语言）。
- 原因：手调透明度只近似系统高亮，两种外观下都会偏色；菜单是系统表面，配色应继承系统语义色，用户才会觉得「与系统相符」。
- 证据：`Sources/FileVaultApp/DesignSystem.swift` 的 `menuRowHover`；实测取值 light `#DCDCDC` / dark `#464646`；SwiftUI `.green/.orange/.red/.blue` 经逐字节核对与 `systemGreen/Orange/Red/Blue` 完全相同（可放心用）。
- 影响：任何新增菜单/面板行都复用 `FVTheme.menuRowHover`；不要在菜单里引入新的品牌色或渐变。

### 子进程管道必须在等待前并发读（v4.2.32）

- 结论：`waitUntilExit()` 之后再 `readDataToEndOfFile()` 的写法，在子进程输出超过 64 KB 管道缓冲时会死锁到超时；GitRunner/GitProvisioner 早已并发读，GhRepoCreator 与 SelfUpdater 是漏网的两个（v4.2.32 已改）。
- 原因：pipe 缓冲写满后子进程阻塞在 write，父进程阻塞在 wait，互等。
- 证据：`Sources/FileVaultCore/GhRepoCreator.swift`（reader 在 spawn 前启动、超时阶梯 terminate→SIGKILL→关写端）、`SelfUpdater.replace`（DispatchGroup drain）；`GhRepoCreatorPipeTests`（假 gh 双流各 200 KB）、`SelfUpdaterEdgeCasesTests`。
- 影响：新增任何 Process+Pipe 的代码先问一句「输出会不会超 64 KB」，会就照这两个文件并发读。

### DispatchSourceTimer.cancel 拦不住已入队的事件处理器（v4.2.32）

- 结论：cancel 只阻止尚未派发的触发；GCD 已派发到队列的 handler 仍会跑。防抖器里旧 handler 会误清新调度的 firstTouch 锚点并提前提交，需用「代际令牌」在 handler 内校验归属。
- 证据：`Sources/FileVaultCore/Debouncer.swift` 的 `timerTokens`；`DebouncerStaleHandlerTests`。
- 影响：任何「取消后重建」的定时器/任务都要考虑已派发事件，不能只靠 cancel。

### URL.resolvingSymlinksInPath 不展开 /tmp 这类系统别名（v4.2.32）

- 结论：macOS 上 `/tmp` → `/private/tmp` 的展开不在 `URL.resolvingSymlinksInPath()` 的解析范围内（实测原样返回），只解析用户自建符号链接。
- 原因：系统卷级别名（firmlink/自动挂载）不算 symlink。
- 证据：`PauseLegacyPathTests`（用用户 symlink 构造「未解析路径」的真实场景）；close-sync 2026-11-19 实验。
- 影响：写「路径规范化/去重」逻辑时不要假设它能把 /tmp 与 /private/tmp 归一；测试里构造「未解析路径」要用用户 symlink。

### git reset 后的旧提交不是 dangling（reflog 仍可达）（v4.2.32）

- 结论：`git reset --hard` 后 `git fsck` 不报 dangling——被丢弃的提交仍在 reflog 里算可达；要构造真正的悬空对象须用 `git hash-object -w`（无引用写入）或先 `reflog expire`。
- 证据：`Tests/FileVaultTests/FsckReportContractTests.testDanglingObjectsAreCountedWhileStillOk`（reset 版本 danglingCount=0，hash-object 版本 >0）。
- 影响：写 fsck/gc 相关测试时直接照此构造，别再试 reset。
