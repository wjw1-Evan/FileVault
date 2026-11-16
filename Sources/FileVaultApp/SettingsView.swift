import SwiftUI
import UniformTypeIdentifiers
import FileVaultCore

// MARK: - Data structures

struct RepoSection: Identifiable, Equatable {
    let id: String          // repo path
    let name: String
    var statusGlyph: String = "circle.dashed"
    var statusColor: Color = Color(nsColor: .systemGray)
    var health: String = "…"
    var urlText: String = ""
    var authMode: RepoManager.AuthMode = .auto
    var authUser: String = ""
    var authToken: String = ""
    /// A token for this remote already lives in the local credential store.
    var authTokenSaved: Bool = false
    /// Remote-derived single-file ceiling, e.g. "100 MB（GitHub 硬限制）".
    var remoteLimit: String = "…"
    /// Configured remote names (several → the user picks which one to sync with).
    var remoteNames: [String] = []
    var message: String = ""
    var messageIsError: Bool = false
}

struct RootCard: Identifiable, Equatable {
    let id: String          // root path (= the one repo's id)
    var name: String
    var path: String
    var paused: Bool
    /// v4.0: one repo per protected folder.
    var repo: RepoSection
}

struct ConnectionAlert: Identifiable {
    let id = UUID()
    var ok: Bool
    var detail: String
}

struct GitignoreEditorState: Identifiable {
    let id = UUID()
    let repoPath: String
    let repoName: String
    var draft: String
}

// MARK: - Model

/// Settings model: general preferences + per-root cards + per-repo actions.
/// Every button action is a method here (v3.0.0 SwiftUI migration).
@MainActor
final class SettingsModel: ObservableObject {
    @Published var rootCards: [RootCard] = []
    @Published var loginIntent: Bool = false
    @Published var notificationsEnabled: Bool = true
    @Published var autoCheckUpdates: Bool = true
    @Published var debounceSeconds: Int = 5
    /// "system" | "zh-Hans" | "en" (v3.4.0); applies on relaunch.
    @Published var language: String = "system"
    @Published var showFileImporter = false
    @Published var connectionAlert: ConnectionAlert?
    @Published var gitignoreEditor: GitignoreEditorState?
    @Published var createRepoTarget: String?
    @Published var createRepoName = ""

    /// Paths the user typed into — async refill must not wipe them.
    private var editedPaths: Set<String> = []
    /// Folders with a remote pull/sync already running (reentrancy guard).
    private var busyRepos: Set<String> = []
    private var generalCommitted = false
    private var app: AppState?

    func bind(_ app: AppState) {
        guard self.app == nil else { return }
        self.app = app
        reload()
        // A window opened during startup (login launch, or --open-ui) can appear
        // before FileVaultService exists. Without this the page stays stuck on
        // "还没有受保护的目录" with default preferences forever.
        guard service == nil else { return }
        Task { @MainActor [weak self] in
            for _ in 0..<50 where self?.service == nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let self, self.service != nil else { return }
            self.reload()
        }
    }

    private var service: FileVaultService? { app?.service }

    // MARK: - Load / rebuild

    func reload() {
        guard let svc = service else { return }
        let general = svc.configStore.load().general
        loginIntent = general.launchAtLoginRequested || LaunchAtLogin.isEnabled
        notificationsEnabled = general.notificationsEnabled
        autoCheckUpdates = general.autoCheckUpdates
        debounceSeconds = general.debounceSeconds
        language = general.language
        generalCommitted = true

        rootCards = svc.rootsSnapshot().map { root in
            let cfgRoot = svc.configStore.load().roots.first { $0.path == root }
            let name = (root as NSString).lastPathComponent
            return RootCard(id: root, name: name,
                            path: root, paused: cfgRoot?.paused ?? false,
                            repo: RepoSection(id: root, name: name))
        }
        for card in rootCards {
            fillRepoDetails(id: card.repo.id)
        }
    }

    /// Async fill: url/toggle/health/status/auth.
    private func fillRepoDetails(id: String) {
        guard let svc = service else { return }
        Task { [weak self] in
            let url = await svc.repoManager.remoteURL(path: id)
            let healthInfo = await svc.repoManager.health(path: id)
            let foreignInstancePID = svc.repoManager.foreignInstancePID(path: id)
            let st = await svc.sync.status(for: id)
            let mode = await svc.repoManager.authMode(path: id)
            let remoteNames = await svc.repoManager.remoteNames(path: id)
            // The remote is the only authority on the single-file ceiling, so
            // the UI just mirrors it (v3.1.3: no local threshold setting).
            let limitText: String
            if GitHubLimits.isGitHubRemote(url) {
                limitText = NSLocalizedString("100 MB（GitHub 硬限制）", comment: "repo limit")
            } else if let url, !url.isEmpty {
                limitText = NSLocalizedString("不限制（远端未提供单文件上限）", comment: "repo limit")
            } else {
                limitText = NSLocalizedString("不限制（未配置远端）", comment: "repo limit")
            }
            var stored: (username: String, password: String)?
            if let url, !url.isEmpty {
                stored = await CredentialStore.fill(runner: svc.repoManager.runner, url: url)
            }
            await MainActor.run { [weak self] in
                guard let self, let idx = self.indexOf(id) else { return }
                // Never wipe text the user is typing.
                if !self.editedPaths.contains(id) {
                    self.rootCards[idx].repo.urlText = url ?? ""
                }
                if let foreignInstancePID {
                    self.rootCards[idx].repo.health = String(
                        format: NSLocalizedString("⚠️ 另一个 FileVault 实例正在管理（pid %d）",
                                                  comment: "repo health"), foreignInstancePID)
                } else if let provider = CloudFolderAdvice.provider(for: id) {
                    self.rootCards[idx].repo.health = healthInfo.summary + String(
                        format: NSLocalizedString(" · ☁️ %@ 目录（按需下载可能被误判为删除）",
                                                  comment: "repo health"), provider)
                } else {
                    self.rootCards[idx].repo.health = healthInfo.summary
                }
                let glyph = Self.repoGlyph(st)
                self.rootCards[idx].repo.statusGlyph = glyph.symbol
                self.rootCards[idx].repo.statusColor = glyph.color
                self.rootCards[idx].repo.authMode = mode
                self.rootCards[idx].repo.remoteLimit = limitText
                self.rootCards[idx].repo.remoteNames = remoteNames
                if let stored {
                    self.rootCards[idx].repo.authUser = stored.username
                    self.rootCards[idx].repo.authTokenSaved = !stored.password.isEmpty
                } else {
                    self.rootCards[idx].repo.authTokenSaved = false
                }
            }
        }
    }

    /// Root-card index for a repo id (v4.0: the root path IS the repo id).
    func indexOf(_ id: String) -> Int? {
        rootCards.firstIndex(where: { $0.repo.id == id })
    }

    /// Testable status glyph mapping (FR menu parity).
    static func repoGlyph(_ status: SyncStatus) -> (symbol: String, color: Color) {
        switch status {
        case .noRemote: return ("circle.dashed", Color(nsColor: .systemGray))
        case .synced: return ("checkmark.circle", Color(nsColor: .systemGreen))
        case .pendingPush: return ("arrow.up.circle", Color(nsColor: .systemOrange))
        case .pushing: return ("arrow.triangle.2.circlepath", Color(nsColor: .systemBlue))
        case .failed: return ("exclamationmark.triangle", Color(nsColor: .systemRed))
        }
    }

    // MARK: - General settings

    func commitGeneral() {
        guard generalCommitted, let svc = service else { return }
        svc.updateGeneral { g in
            g.notificationsEnabled = notificationsEnabled
            g.autoCheckUpdates = autoCheckUpdates
            g.debounceSeconds = debounceSeconds
        }
    }
    // MARK: - Support (v3.2.1: the app is free — no licence, only diagnostics)

    @Published var supportMessage: String?
    @Published var supportMessageIsError = false

    /// Build a privacy-conscious diagnostics zip users can attach to support mail.
    func exportDiagnostics() {
        guard let svc = service, let app else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(format: NSLocalizedString("FileVault-诊断-%@.zip", comment: "diagnostics file name"), Self.dayStamp())
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let report = SupportBundle.report(appVersion: app.version,
                                          config: svc.configStore.load(),
                                          gitDescription: svc.detection.map { "\($0.gitPath) (\($0.version))" },
                                          roots: svc.rootsSnapshot())
        do {
            _ = try SupportBundle.export(report: report,
                                         configDirectory: svc.configStore.directory,
                                         destination: dest)
            supportMessage = String(format: NSLocalizedString("✓ 诊断包已保存到 %@", comment: "settings"), dest.path)
            supportMessageIsError = false
        } catch {
            supportMessage = String(format: NSLocalizedString("⚠️ %@", comment: "settings"), error.localizedDescription)
            supportMessageIsError = true
        }
    }
    private static func dayStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    /// Changing the interface language: persist, point the bundle at the new
    /// localisation and relaunch (SwiftUI only resolves it at launch).
    func setLanguage(_ code: String) {
        guard let svc = service else { return }
        language = code
        svc.updateGeneral { $0.language = code }
        AppLanguage.apply(AppLanguage.storedValue(code))
        relaunchSoon()
    }

    private func relaunchSoon() {
        let path = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6 && /usr/bin/open " + Self.shellQuote(path)]
        try? p.run()
        NSApp.terminate(nil)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Toggling "自动检查更新" back on resumes checking immediately (v3.1.4).
    func setAutoCheckUpdates(_ on: Bool) {
        let wasOn = autoCheckUpdates
        autoCheckUpdates = on
        commitGeneral()
        if on && !wasOn {
            app?.resumeUpdateChecksIfEnabled()
        }
    }

    func toggleLoginIntent(_ on: Bool) {
        loginIntent = on
        Task { @MainActor in
            do {
                try LaunchAtLogin.setEnabled(on)
                service?.updateGeneral { $0.launchAtLoginRequested = on }
            } catch {
                loginIntent = LaunchAtLogin.isEnabled
                await alert(NSLocalizedString("设置登录自启失败", comment: "settings alert"), error.localizedDescription)
            }
        }
    }

    func openConfigFile() {
        guard let file = service?.configStore.directory.appendingPathComponent("config.json") else { return }
        // `open -t` (default TEXT editor) is deliberate: NSWorkspace.open on a
        // .json depends on LaunchServices' public.json handler, which can be
        // missing on some Macs and silently opens nothing (v2.6.7).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", file.path]
        try? p.run()
    }

    // MARK: - Root cards

    func pauseRoot(_ card: RootCard, to paused: Bool) {
        guard let svc = service else { return }
        Task { [weak self] in
            await svc.setRootPaused(paused, root: card.path)
            await MainActor.run { self?.reload() }
        }
    }

    func removeRoot(_ card: RootCard) {
        guard let svc = service else { return }
        Task { [weak self] in
            await svc.removeRoot(path: card.path)
            await MainActor.run { self?.reload() }
        }
    }

    func addRoot(at url: URL) {
        guard let svc = service else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await svc.addRoot(path: url.path)
                reload()
            } catch {
                // Never swallow add-root failures silently (v2.6.1).
                await alert(NSLocalizedString("添加文件夹失败", comment: "settings alert"), error.localizedDescription)
            }
        }
    }

    // MARK: - Per-repo actions

    func urlBinding(_ id: String) -> Binding<String> {
        Binding(get: { [weak self] in self?.indexOf(id).flatMap { self?.rootCards[$0].repo.urlText } ?? "" },
                set: { [weak self] text in
                    guard let self, let idx = self.indexOf(id) else { return }
                    self.rootCards[idx].repo.urlText = text
                    self.editedPaths.insert(id)
                })
    }

    /// "用户名 + 访问令牌" mode: user name field (optional on GitHub).
    func authUserBinding(_ id: String) -> Binding<String> {
        Binding(get: { [weak self] in self?.indexOf(id).flatMap { self?.rootCards[$0].repo.authUser } ?? "" },
                set: { [weak self] text in
                    guard let self, let idx = self.indexOf(id) else { return }
                    self.rootCards[idx].repo.authUser = text
                })
    }

    /// "用户名 + 访问令牌" mode: the token itself. Never written to git config.
    func authTokenBinding(_ id: String) -> Binding<String> {
        Binding(get: { [weak self] in self?.indexOf(id).flatMap { self?.rootCards[$0].repo.authToken } ?? "" },
                set: { [weak self] text in
                    guard let self, let idx = self.indexOf(id) else { return }
                    self.rootCards[idx].repo.authToken = text
                })
    }

    func authModeBinding(_ id: String) -> Binding<RepoManager.AuthMode> {
        Binding(get: { [weak self] in self?.indexOf(id).flatMap { self?.rootCards[$0].repo.authMode } ?? .auto },
                set: { [weak self] v in
                    guard let self, let idx = self.indexOf(id) else { return }
                    self.rootCards[idx].repo.authMode = v
                })
    }

    func message(_ id: String) -> (String, Color)? {
        guard let idx = indexOf(id) else { return nil }
        let s = rootCards[idx].repo
        return s.message.isEmpty ? nil : (s.message, s.messageIsError ? Color(nsColor: .systemRed) : Color(nsColor: .secondaryLabelColor))
    }

    private func setMessage(_ id: String, _ text: String, error: Bool = false) {
        guard let idx = indexOf(id) else { return }
        rootCards[idx].repo.message = text
        rootCards[idx].repo.messageIsError = error
    }

    /// Reentrancy guard: only one pull/sync/force-pull per folder at a time, so
    /// two overlapping git operations can never race each other (v4.1.4).
    private func beginRepoOp(_ id: String) -> Bool {
        guard !busyRepos.contains(id) else {
            setMessage(id, NSLocalizedString("正在处理上一个操作，请稍候…", comment: "settings status"))
            return false
        }
        busyRepos.insert(id)
        return true
    }

    private func endRepoOp(_ id: String) {
        busyRepos.remove(id)
    }

    /// Shared save path: persist auth mode, configure + test + inline feedback (FR-06).
    func saveRepo(_ id: String) {
        guard let svc = service, let idx = indexOf(id) else { return }
        let section = rootCards[idx].repo
        let url = section.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = section.authMode
        let user = section.authUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = section.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { [weak self] in
            guard let self else { return }
            await MainActor.run { self.setMessage(id, NSLocalizedString("正在保存…", comment: "settings status")) }
            do {
                if url.isEmpty {
                    try await svc.sync.clearRemote(repoPath: id)
                    await MainActor.run {
                        self.setMessage(id, NSLocalizedString("已清除远程仓库（仅本地模式）", comment: "settings status"))
                        self.fillRepoDetails(id: id)   // refresh the remote-derived limit
                    }
                    return
                }
                // Persist the picker selection and put the token in place BEFORE the
                // remote is wired: configureRemote may start an auto-push right away,
                // and that push needs the credential. (Before the fix the selected
                // mode was never written, so PAT silently stayed on auto.)
                await svc.repoManager.setAuthMode(path: id, mode: mode)

                var credentialNote = ""
                var needsToken = false
                switch mode {
                case .pat:
                    let backend = await CredentialStore.prepare(runner: svc.repoManager.runner, repoPath: id)
                    if token.isEmpty {
                        let existing = await CredentialStore.fill(runner: svc.repoManager.runner, url: url)
                        needsToken = existing?.password.isEmpty != false
                    } else {
                        let account = user.isEmpty ? "personal-access-token" : user
                        try await CredentialStore.store(runner: svc.repoManager.runner, url: url,
                                                        username: account, password: token)
                        await MainActor.run { [weak self] in
                            guard let self, let idx = self.indexOf(id) else { return }
                            // Do not keep the secret in memory once it is safe on disk.
                            self.rootCards[idx].repo.authToken = ""
                            self.rootCards[idx].repo.authUser = account
                            self.rootCards[idx].repo.authTokenSaved = true
                        }
                        if backend.isPrivateFile {
                            credentialNote = NSLocalizedString("（本机没有钥匙串助手，令牌保存在仅本人可读的本机文件）", comment: "settings status")
                        }
                    }
                case .ssh:
                    break
                case .auto:
                    if url.contains("github.com") && url.hasPrefix("https://") {
                        _ = try? await GitRunner.ghAuthSetupGit()
                    }
                }

                // The remote address is always saved, even when the token is missing.
                // v4.2: syncing is not optional — saving a remote makes this folder
                // an automatically synced one, so auto-push is always on.
                let change = try await svc.sync.configureRemote(repoPath: id, url: url, autoPush: true)
                if needsToken {
                    await MainActor.run {
                        self.setMessage(id, NSLocalizedString("已保存地址，但「用户名 + 访问令牌」还需要填写访问令牌（令牌只写进本机凭证库，不写进 git 配置）",
                                                             comment: "settings status"), error: true)
                    }
                    return
                }
                await MainActor.run { self.setMessage(id, NSLocalizedString("已保存，正在测试连接…", comment: "settings status")) }
                await MainActor.run { self.fillRepoDetails(id: id) }   // remote limit may have changed
                let conn = await svc.sync.testConnectivity(repoPath: id)
                self.editedPaths.remove(id)
                let status: String
                if change.changed && !change.fetchSucceeded {
                    status = String(format: NSLocalizedString("⚠️ 已保存新远程地址，但暂时读不到这个远程（检查地址或认证）：%@",
                                                             comment: "settings status"), conn.detail) + credentialNote
                } else if change.needsDecision {
                    // v4.2: a remote that already has commits is merged into the
                    // folder automatically (local files kept, same-name files kept
                    // twice) and pushed; nothing is left for the user to choose.
                    status = String(format: NSLocalizedString("✓ 已保存并连通；远程已有 %d 个提交，已自动合并进这个文件夹（本地文件都保留），随后自动推送",
                                                             comment: "settings status"), change.remoteCommitCount) + credentialNote
                } else if change.changed && change.isReplacement {
                    status = NSLocalizedString("✓ 已切换到新的远程仓库，本地版本会自动同步上去",
                                               comment: "settings status") + credentialNote
                } else if conn.ok {
                    status = NSLocalizedString("✓ 已保存并连通，之后自动同步", comment: "settings status") + credentialNote
                } else {
                    status = String(format: NSLocalizedString("⚠️ 已保存但连接失败：%@", comment: "settings status"),
                                    conn.detail) + credentialNote
                }
                await MainActor.run { self.setMessage(id, status, error: !conn.ok && !change.changed) }
            } catch {
                await MainActor.run {
                    self.setMessage(id, String(format: NSLocalizedString("⚠️ 保存失败：%@", comment: "settings status"),
                                               error.localizedDescription), error: true)
                }
            }
        }
    }

    func testConnection(_ id: String) {
        guard let svc = service else { return }
        Task { [weak self] in
            let result = await svc.sync.testConnectivity(repoPath: id)
            await MainActor.run {
                self?.connectionAlert = ConnectionAlert(ok: result.ok, detail: result.detail)
            }
        }
    }

    /// v4.0.5: read-only repository integrity check (git fsck --full).
    func checkIntegrity(_ id: String) {
        guard let svc = service else { return }
        setMessage(id, NSLocalizedString("正在检查仓库完整性…", comment: "settings status"))
        Task { [weak self] in
            do {
                let report = try await svc.history.fsck(repoPath: id)
                await MainActor.run {
                    self?.setMessage(id, report.summary, error: !report.ok)
                    if !report.ok {
                        let detail = report.issues.prefix(6).joined(separator: "\n")
                        Task { await self?.alert(NSLocalizedString("仓库检查发现问题", comment: "settings alert"),
                                                 detail) }
                    }
                }
            } catch {
                await MainActor.run {
                    self?.setMessage(id, String(format: NSLocalizedString("⚠️ 检查失败：%@", comment: "settings status"),
                                                error.localizedDescription), error: true)
                }
            }
        }
    }

    /// v4.2.5: re-point a managed folder after it was moved/renamed (or an
    /// external disk mounted elsewhere) without losing history or config.
    func relocateRoot(_ id: String) {
        guard let svc = service else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("重新定位到这里", comment: "settings dialog")
        panel.message = NSLocalizedString("选择这个受保护文件夹现在所在的位置（原来的 Git 历史会一起保留）",
                                          comment: "settings dialog")
        guard panel.runModal() == .OK, let picked = panel.url?.path else { return }
        let newPath = (picked as NSString).resolvingSymlinksInPath
        Task { [weak self] in
            do {
                try await svc.relocateRoot(from: id, to: newPath)
                await MainActor.run {
                    self?.reload()
                    self?.setMessage(newPath, NSLocalizedString("✓ 已重新定位，历史与远程绑定都保留",
                                                               comment: "settings status"))
                }
            } catch {
                await MainActor.run {
                    self?.setMessage(id, String(format: NSLocalizedString("⚠️ 重新定位失败：%@", comment: "settings status"),
                                                error.localizedDescription), error: true)
                }
            }
        }
    }

    /// v4.2.1: several remotes exist — pick which one the automatic sync uses.
    func setUpstreamRemote(_ id: String, remote: String) {
        guard let svc = service else { return }
        setMessage(id, String(format: NSLocalizedString("正在把同步远程设为 %@…", comment: "settings status"), remote))
        Task { [weak self] in
            do {
                try await svc.repoManager.setUpstreamRemote(path: id, remote: remote)
                await MainActor.run {
                    self?.setMessage(id, String(format: NSLocalizedString("✓ 已把同步远程设为 %@，之后的自动同步都走它",
                                                                         comment: "settings status"), remote))
                    self?.fillRepoDetails(id: id)
                }
            } catch {
                await MainActor.run {
                    self?.setMessage(id, String(format: NSLocalizedString("⚠️ 设置远程失败：%@", comment: "settings status"),
                                                error.localizedDescription), error: true)
                }
            }
        }
    }

    /// v4.1.8: a crash or force-quit can leave a half-applied rebase/merge that
    /// blocks auto-commits and pulls. Offer a one-click cleanup.
    func repairInterruptedOperation(_ id: String) {
        guard let svc = service else { return }
        Task { [weak self] in
            guard let self else { return }
            let state = await svc.repoManager.interruptedOperation(path: id)
            if state.isEmpty {
                await MainActor.run {
                    self.setMessage(id, NSLocalizedString("没有发现未完成的合并或变基", comment: "settings status"))
                }
                return
            }
            let confirm = NSAlert()
            confirm.messageText = NSLocalizedString("清理未完成的合并/变基？", comment: "settings alert")
            confirm.informativeText = NSLocalizedString("上次的合并、变基或 Git 操作没有正常结束（可能是崩溃或强退）。清理会丢弃那一步的中间状态（包括过期的 .git/index.lock），已提交的历史和文件不会丢失。",
                                                        comment: "settings alert")
            confirm.addButton(withTitle: NSLocalizedString("清理", comment: "settings alert"))
            confirm.addButton(withTitle: NSLocalizedString("取消", comment: "settings alert"))
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            do {
                if let cleaned = try await svc.repoManager.repairInterruptedOperation(path: id) {
                    await MainActor.run {
                        self.setMessage(id, String(format: NSLocalizedString("✓ 已清理未完成的%@，可以继续拉取/推送",
                                                                             comment: "settings status"), cleaned))
                        self.fillRepoDetails(id: id)
                    }
                }
            } catch {
                await MainActor.run {
                    self.setMessage(id, String(format: NSLocalizedString("⚠️ 清理失败：%@", comment: "settings status"),
                                               error.localizedDescription), error: true)
                }
            }
        }
    }

    func openGitignoreEditor(_ id: String) {
        guard let repos = service?.repoManager else { return }
        let name = (id as NSString).lastPathComponent
        gitignoreEditor = GitignoreEditorState(repoPath: id, repoName: name, draft: repos.gitignore(path: id))
    }

    func saveGitignore(_ state: GitignoreEditorState) {
        service?.repoManager.saveGitignore(path: state.repoPath, content: state.draft)
        gitignoreEditor = nil
    }

    func createRepoAndBind(target: String, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        setMessage(target, String(format: NSLocalizedString("正在创建仓库 %@…", comment: "settings status"), clean))
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await GhRepoCreator().createPrivate(name: clean)
                await MainActor.run {
                    if let idx = self.indexOf(target) {
                        self.rootCards[idx].repo.urlText = url
                    }
                    self.saveRepo(target)
                }
            } catch {
                await MainActor.run {
                    self.setMessage(target, String(format: NSLocalizedString("⚠️ 创建失败: %@", comment: "settings status"),
                                                   error.localizedDescription), error: true)
                }
            }
        }
    }

    // MARK: - Alerts (no host window dependency: SwiftUI alert modifiers)

    func alert(_ title: String, _ body: String) async {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }
}

// MARK: - View (custom cards)

/// Fold state for the root cards in Settings (v3.4.2).
///
/// Pure value type so the fold logic is unit-testable; the view keeps one in
/// `@State` and mirrors it to UserDefaults so a folded card stays folded.
struct RootCollapseState: Equatable {
    private(set) var collapsed: Set<String> = []

    static let defaultsKey = "fv.collapsedRoots"

    init(collapsed: Set<String> = []) {
        self.collapsed = collapsed
    }

    func isCollapsed(_ id: String) -> Bool { collapsed.contains(id) }

    mutating func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    mutating func collapseAll(_ ids: [String]) { collapsed.formUnion(ids) }
    mutating func expandAll() { collapsed.removeAll() }
    var isEmpty: Bool { collapsed.isEmpty }

    static func load(from defaults: UserDefaults = .standard) -> RootCollapseState {
        RootCollapseState(collapsed: Set(defaults.stringArray(forKey: defaultsKey) ?? []))
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(Array(collapsed), forKey: Self.defaultsKey)
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = SettingsModel()
    @State private var removeTarget: RootCard?
    /// Folded root cards (v3.4.2); persisted so the layout survives reopening.
    @State private var collapse = RootCollapseState.load()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                generalCard
                supportCard
                ForEach(model.rootCards) { card in
                    rootCard(card)
                }
                if model.rootCards.isEmpty {
                    emptyRootsCard
                }
                addRootButton
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fvCanvas()
        .task { model.bind(app) }
        .fileImporter(isPresented: $model.showFileImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.addRoot(at: url)
            }
        }
        .alert(item: $model.connectionAlert) { alert in
            Alert(title: Text(alert.ok ? "连接成功" : "连接失败"),
                  message: Text(alert.detail),
                  dismissButton: .default(Text("好")))
        }
        .sheet(item: $model.gitignoreEditor) { editor in
            GitignoreSheet(state: editor) { draft in
                model.saveGitignore(GitignoreEditorState(repoPath: editor.repoPath,
                                                         repoName: editor.repoName, draft: draft))
            }
        }
        .alert("在 GitHub 创建私有仓库并绑定", isPresented: Binding(
            get: { model.createRepoTarget != nil },
            set: { if !$0 { model.createRepoTarget = nil } })) {
            TextField("my-notes", text: $model.createRepoName)
            Button("创建并绑定") {
                if let target = model.createRepoTarget {
                    model.createRepoAndBind(target: target, name: model.createRepoName)
                }
                model.createRepoName = ""
            }
            Button("取消", role: .cancel) { model.createRepoName = "" }
        } message: {
            Text("输入仓库名（将创建为当前 gh 账号下的私有仓库）：")
        }
        .confirmationDialog("移除文件夹？", isPresented: Binding(
            get: { removeTarget != nil },
            set: { if !$0 { removeTarget = nil } }), titleVisibility: .visible) {
            Button("移除 \(removeTarget?.name ?? "")（仓库保留在磁盘）", role: .destructive) {
                if let target = removeTarget {
                    model.removeRoot(target)
                }
                removeTarget = nil
            }
            Button("取消", role: .cancel) { removeTarget = nil }
        } message: {
            Text("FileVault 只是不再守卫这个文件夹，已经生成的 .git 历史不会被删除。")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            FVIconBadge(symbol: "slider.horizontal.3", size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("设置")
                    .font(FVTheme.titleFont)
                    .tracking(-0.4)
                Text("所有改动即时生效，保存在本地配置文件中")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: General

    private var generalCard: some View {
        VStack(spacing: 0) {
            FVSectionHeader(title: "通用",
                            subtitle: "影响所有受保护的文件夹",
                            trailing: app.version.isEmpty ? nil : "v\(app.version)")
            FVHairline(leading: 0)
            if LaunchAtLogin.available {
                settingRow(title: "登录时启动",
                           detail: "开机后直接在菜单栏待命") {
                    Toggle("", isOn: Binding(
                        get: { model.loginIntent },
                        set: { model.toggleLoginIntent($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                FVHairline(leading: 16)
            }
            settingRow(title: "推送失败通知",
                       detail: "认证失效或网络异常时提醒一次") {
                Toggle("", isOn: Binding(
                    get: { model.notificationsEnabled },
                    set: { model.notificationsEnabled = $0; model.commitGeneral() }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            FVHairline(leading: 16)
            settingRow(title: "自动检查更新",
                       detail: "启动 20 秒后检查一次，此后每小时一次") {
                Toggle("", isOn: Binding(
                    get: { model.autoCheckUpdates },
                    set: { model.setAutoCheckUpdates($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            FVHairline(leading: 16)
            settingRow(title: "自动提交延迟",
                       detail: "停止编辑多久后落一版") {
                Picker("", selection: Binding(
                    get: { model.debounceSeconds },
                    set: { model.debounceSeconds = $0; model.commitGeneral() })) {
                    ForEach([2, 5, 10, 30], id: \.self) { s in
                        Text(String(format: NSLocalizedString("%d 秒", comment: "delay option"), s)).tag(s)
                    }
                }
                .labelsHidden()
                .frame(width: 92)
            }
            FVHairline(leading: 16)
            settingRow(title: "语言",
                       detail: "默认跟随系统；切换后会自动重启应用") {
                Picker("", selection: Binding(
                    get: { model.language },
                    set: { model.setLanguage($0) })) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            FVHairline(leading: 16)
            settingRow(title: "配置文件",
                       detail: "高级选项都在这里，改完重启生效") {
                Button("打开") { model.openConfigFile() }
                    .controlSize(.small)
            }
        }
        .fvCard()
    }

    private func settingRow<Control: View>(title: LocalizedStringKey,
                                           detail: LocalizedStringKey,
                                           @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    // MARK: Support (v3.2.1: free app — diagnostics only)

    private var supportCard: some View {
        VStack(spacing: 0) {
            FVSectionHeader(title: "关于与支持",
                            subtitle: "FileVault 永久免费 · 无账号、无订阅、无遥测",
                            trailing: app.version.isEmpty ? nil : "v\(app.version)")
            FVHairline(leading: 0)
            settingRow(title: "导出诊断包",
                       detail: "脱敏报告（不含文件内容/远程地址/账号），便于反馈问题") {
                Button("导出诊断包…") { model.exportDiagnostics() }
                    .controlSize(.small)
            }
            FVHairline(leading: 16)
            settingRow(title: "隐私与许可",
                       detail: "无云端中转；数据与版本库完全属于你") {
                HStack(spacing: 10) {
                    Button("隐私政策") {
                        if let url = URL(string: AppBrand.privacyURL) { NSWorkspace.shared.open(url) }
                    }
                    Button("开源协议") {
                        if let url = URL(string: AppBrand.websiteURL + "/blob/main/LICENSE") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .controlSize(.small)
            }
            if let message = model.supportMessage {
                FVHairline(leading: 16)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(model.supportMessageIsError ? Color.red : Color.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .fvCard()
    }

    // MARK: Root cards

    private func rootCard(_ card: RootCard) -> some View {
        let isCollapsed = collapse.isCollapsed(card.id)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Header doubles as the fold toggle (v3.4.2).
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        collapse.toggle(card.id)
                        collapse.save()
                    }
                } label: {
                    HStack(spacing: 12) {
                        FVIconBadge(symbol: "folder.fill", tint: card.paused ? .gray : .orange, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 7) {
                                Text(card.name)
                                    .font(.system(size: 15, weight: .semibold))
                                if card.paused {
                                    FVStatusPill(text: "已暂停", tint: .orange, symbol: "pause.fill")
                                }
                            }
                            Text(card.path)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: card.repo.statusGlyph)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(card.repo.statusColor)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "展开文件夹" : "折叠文件夹")
                Menu {
                    Button("在 Finder 中打开") { app.openPath(card.path) }
                    Button(card.paused ? "恢复自动提交" : "暂停自动提交") {
                        model.pauseRoot(card, to: !card.paused)
                    }
                    Divider()
                    Button("移除文件夹…", role: .destructive) { removeTarget = card }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .help("文件夹操作")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            if !isCollapsed {
                FVHairline(leading: 0)
                repoBlock(card.repo)
            }
        }
        .fvCard()
    }

    /// One repo: identity + status, remote field, then a calm row of controls.
    private func repoBlock(_ repo: RepoSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 7) {
                Image(systemName: repo.statusGlyph)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(repo.statusColor)
                Spacer(minLength: 8)
                Text(repo.health)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                TextField("远程仓库地址（留空 = 仅本地）", text: model.urlBinding(repo.id))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .onSubmit { model.saveRepo(repo.id) }
                Button("保存") { model.saveRepo(repo.id) }
                    .controlSize(.small)
                Button("测试") { model.testConnection(repo.id) }
                    .controlSize(.small)
            }

            HStack(spacing: 12) {
                Picker("", selection: model.authModeBinding(repo.id)) {
                    Text("自动（gh 凭证助手）").tag(RepoManager.AuthMode.auto)
                    Text("用户名 + 访问令牌").tag(RepoManager.AuthMode.pat)
                    Text("SSH 密钥").tag(RepoManager.AuthMode.ssh)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 168)
                Text(repo.remoteLimit)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Menu("更多") {
                    if repo.remoteNames.count > 1 {
                        Menu("同步使用的远程") {
                            ForEach(repo.remoteNames, id: \.self) { name in
                                Button(name) { model.setUpstreamRemote(repo.id, remote: name) }
                            }
                        }
                        Divider()
                    }
                    Button("编辑忽略规则…") { model.openGitignoreEditor(repo.id) }
                    Button("重新定位（文件夹被移动/改名）…") { model.relocateRoot(repo.id) }
                    Button("在 GitHub 建仓并绑定…") { model.createRepoTarget = repo.id }
                    Divider()
                    Button("检查仓库完整性…") { model.checkIntegrity(repo.id) }
                    Button("修复未完成的合并/变基…") { model.repairInterruptedOperation(repo.id) }
                }
                .controlSize(.small)
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // Auth mode details (FR-06): PAT needs two inputs; SSH gets a hint.
            RepoAuthFields(mode: repo.authMode,
                           user: model.authUserBinding(repo.id),
                           token: model.authTokenBinding(repo.id),
                           tokenSaved: repo.authTokenSaved,
                           save: { model.saveRepo(repo.id) })

            if let msg = model.message(repo.id) {
                HStack(spacing: 5) {
                    Image(systemName: msg.1 == Color(nsColor: .systemRed)
                          ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 9))
                    Text(msg.0)
                        .font(.system(size: 10))
                        .lineLimit(2)
                }
                .foregroundStyle(msg.1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyRootsCard: some View {
        VStack(spacing: 0) {
            FVEmptyState(symbol: "folder.badge.plus",
                         title: "还没有受保护的文件夹",
                         message: "选一个文件夹，它里面的所有文件都会自动拥有版本历史。",
                         actionTitle: "选择文件夹…",
                         action: { model.showFileImporter = true })
        }
        .fvCard()
    }

    private var addRootButton: some View {
        Button {
            model.showFileImporter = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                Text("添加文件夹…")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: FVTheme.radius, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.3),
                              style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        )
    }
}

/// Gitignore editor sheet (FR-14).
struct GitignoreSheet: View {
    let state: GitignoreEditorState
    let onSave: (String) -> Void
    @State private var draft: String
    @Environment(\.dismiss) private var dismiss

    init(state: GitignoreEditorState, onSave: @escaping (String) -> Void) {
        self.state = state
        self.onSave = onSave
        _draft = State(initialValue: state.draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                FVIconBadge(symbol: "eye.slash.fill", tint: .gray, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("忽略规则")
                        .font(.system(size: 15, weight: .semibold))
                    Text(state.repoName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(FVTheme.cardStroke, lineWidth: 1)
                )
                .frame(minHeight: 240)
            HStack {
                Text("保存后改动会被自动提交")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 420)
        .background(FVTheme.canvas)
    }
}

/// Auth-mode detail row for one remote (FR-06).
///
/// Split out of repoBlock so it can be snapshotted offscreen in tests: PAT mode
/// must show real inputs — before v4.0.2 the picker had no fields to type into.
struct RepoAuthFields: View {
    let mode: RepoManager.AuthMode
    @Binding var user: String
    @Binding var token: String
    let tokenSaved: Bool
    let save: () -> Void

    var body: some View {
        switch mode {
        case .pat:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("用户名（可留空）", text: $user)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11))
                        .frame(maxWidth: 200)
                    SecureField("访问令牌", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11))
                        .frame(maxWidth: 280)
                        .onSubmit { save() }
                    if tokenSaved {
                        Text("已保存到本机凭证库")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("点「保存」写入本机凭证库（优先钥匙串，不会写进 git 配置）；GitHub 细粒度令牌请给 Contents: Read and write。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        case .ssh:
            Text("使用 ~/.ssh 里的密钥；需要先把公钥添加到托管平台。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        case .auto:
            EmptyView()
        }
    }
}
