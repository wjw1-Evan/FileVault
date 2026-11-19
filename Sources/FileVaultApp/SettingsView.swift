import SwiftUI
import UniformTypeIdentifiers
import FileVaultCore

// MARK: - Data structures

struct RepoSection: Identifiable, Equatable {
    let id: String          // repo path
    let name: String
    var statusGlyph: String = "circle.dashed"
    var statusColor: Color = Color(nsColor: .systemGray)
    /// Word shown in the expanded block ("已同步"…); the glyph stays in the header.
    var statusLabel: String = ""
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
    /// Full text for the message row's hover (classified reason + condensed
    /// git output); empty when the message line is all there is (v4.2.30).
    var messageHelp: String = ""
    /// True when the sync status is "仅本地": an empty remote field then gets
    /// its meaning spelled out instead of just sitting there (v4.2.30).
    var localOnly: Bool = false
    /// Files auto-excluded for exceeding the remote's single-file limit — the
    /// card renders a dedicated orange row for them (v4.2.30 audit item 4).
    var excludedLargeFileCount: Int = 0
    /// False for a configured folder that is not attached right now (external
    /// disk unplugged, folder moved, another live instance): the card then
    /// shows why and only offers relocate/remove (v4.2.26 audit M8).
    var available: Bool = true
    /// Shown in SSH mode when ~/.ssh has no public key (v4.2.26 audit M8).
    var authGuidance: String = ""
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
    /// Readable classified failure (primary line); empty when ok (v4.2.30
    /// audit item 2: `detail` keeps the condensed git output as the second).
    var summary: String = ""
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
    /// v4.2.30 audit item 6: the create-repo dialog is a sheet that keeps its
    /// errors inside instead of flashing an alert and dumping the reason
    /// into the card's small status line.
    @Published var createRepoError = ""
    @Published var createRepoBusy = false
    /// gh precheck result, refreshed every time the dialog opens (v4.2.30
    /// audit item 6b).
    @Published var ghMissing = false
    /// v4.2.30 audit item 4: the excluded-large-files sheet.
    @Published var largeFilesViewer: LargeFilesState?
    /// v4.2.30 audit item 10: the FAQ sheet.
    @Published var showFAQ = false

    /// Paths the user typed into — async refill must not wipe them.
    private var editedPaths: Set<String> = []
    /// Paths whose auth mode / account fields the user changed but not saved yet;
    /// background refills must not snap them back (v4.2.26 audit M8).
    private var editedAuthModes: Set<String> = []
    /// Username field touched but not saved: background refreshes must not
    /// snap it back to the stored credential's username mid-typing (v4.2.27).
    private var editedAuthUsers: Set<String> = []
    /// Per-card fill generation (v4.2.28): a detail fill that started BEFORE a
    /// save finished must not write its pre-save url/auth values back after
    /// the save cleared the edit marks — the credential probe can suspend for
    /// seconds, and the late write made the saved address "snap back".
    private var fillGenerations: [String: Int] = [:]
    /// Folders with a save/test operation already running (reentrancy guard).
    private var busyRepos: Set<String> = []
    private var generalCommitted = false
    private var app: AppState?
    /// Service state-change subscription (v4.2.26 audits M8/M9).
    private var listenerToken: UUID?
    /// Debounced reload triggered by a state change while the page is visible.
    private var pendingReload: Task<Void, Never>?
    /// Startup readiness poll; cancelled when the window closes.
    private var startupTask: Task<Void, Never>?
    /// False between onDisappear and the next bind.
    private var bound = false

    func bind(_ app: AppState) {
        self.app = app
        bound = true
        reload()
        startListening()
        if service?.isReady == true { return }
        // A window opened during startup (login launch, or --open-ui) can appear
        // before FileVaultService exists, and even once it exists the git-backed
        // services are built asynchronously (a first launch may download git
        // first). Wait for readiness, then reload — otherwise the page stays
        // stuck on "还没有受保护的文件夹" with default preferences (v4.2.26 M8/M9).
        startupTask?.cancel()
        startupTask = Task { @MainActor [weak self] in
            while true {
                guard let self, self.bound else { return }
                if let svc = self.service, svc.isReady { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
            }
            guard let self, self.bound else { return }
            self.reload()
            self.startListening()
        }
    }

    /// Refresh when folders are added/removed or a sync/commit transition lands,
    /// while the settings window is open (v4.2.26 audit M8).
    private func startListening() {
        guard bound, listenerToken == nil, let svc = service else { return }
        listenerToken = svc.addStateListener { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
    }

    /// The window went away: stop listening and cancel pending refreshes.
    func unbind() {
        bound = false
        startupTask?.cancel()
        startupTask = nil
        pendingReload?.cancel()
        pendingReload = nil
        if let token = listenerToken { app?.service?.removeStateListener(token) }
        listenerToken = nil
    }

    /// Rapid state flips coalesce into one reload (v4.2.26 audit M8).
    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, self.bound else { return }
            self.reload()
        }
    }

    private var service: FileVaultService? { app?.service }

    // MARK: - Load / rebuild

    func reload() {
        guard let svc = service else { return }
        let config = svc.configStore.load()
        let general = config.general
        loginIntent = general.launchAtLoginRequested || LaunchAtLogin.isEnabled
        notificationsEnabled = general.notificationsEnabled
        autoCheckUpdates = general.autoCheckUpdates
        debounceSeconds = general.debounceSeconds
        language = general.language
        generalCommitted = true

        // A background state change can reload at any time: carry half-typed
        // drafts and inline results over so they are never wiped mid-edit.
        let previous = Dictionary(rootCards.map { ($0.id, $0.repo) },
                                  uniquingKeysWith: { first, _ in first })
        let ready = svc.isReady
        // configuredRoots() (not rootsSnapshot()) so a folder that failed to
        // attach still gets a card the user can relocate or remove; it used to
        // vanish from Settings entirely (v4.2.26 audits M8/M9).
        rootCards = svc.configuredRoots().map { managed in
            let path = managed.path
            let name = (path as NSString).lastPathComponent
            var repo = RepoSection(id: path, name: name)
            if let old = previous[path] {
                repo.urlText = old.urlText
                repo.authMode = old.authMode
                repo.authUser = old.authUser
                repo.authToken = old.authToken
                repo.message = old.message
                repo.messageIsError = old.messageIsError
                repo.messageHelp = old.messageHelp
                repo.localOnly = old.localOnly
                repo.excludedLargeFileCount = old.excludedLargeFileCount
            }
            if !ready {
                repo.health = NSLocalizedString("正在加载…", comment: "settings status")
            } else if !svc.isAttached(root: path) {
                repo.available = false
                repo.statusGlyph = "exclamationmark.triangle"
                repo.statusColor = Color(nsColor: .systemRed)
                repo.statusLabel = NSLocalizedString("不可用", comment: "settings status")
                repo.health = Self.unavailableReason(path: path, svc: svc)
            }
            return RootCard(id: path, name: name, path: path,
                            paused: managed.paused, repo: repo)
        }
        // Typed text for a folder that no longer exists is meaningless, and it
        // used to survive remove→re-add so the remote field stayed empty.
        let cardPaths = Set(rootCards.map(\.id))
        editedPaths.formIntersection(cardPaths)
        editedAuthModes.formIntersection(cardPaths)
        editedAuthUsers.formIntersection(cardPaths)
        for card in rootCards where card.repo.available && ready {
            fillRepoDetails(id: card.repo.id)
        }
    }

    /// Why a configured folder is not attached, in user terms (v4.2.26 M8/M9).
    static func unavailableReason(path: String, svc: FileVaultService) -> String {
        if let reason = svc.attachError(root: path), !reason.isEmpty {
            return reason.hasPrefix("⚠️") ? reason : "⚠️ " + reason
        }
        if !FileManager.default.fileExists(atPath: path) {
            return NSLocalizedString("⚠️ 文件夹当前不可用（可能被移动或外置盘未挂载）",
                                     comment: "repo health")
        }
        return NSLocalizedString("⚠️ 启动时未能挂载", comment: "repo health")
    }

    /// Async fill: url/toggle/health/status/auth.
    private func fillRepoDetails(id: String) {
        // repoManager is implicitly unwrapped until start() finishes: never ask
        // for git facts before the service is ready (v4.2.26).
        guard let svc = service, svc.isReady else { return }
        fillGenerations[id, default: 0] += 1
        let pass = fillGenerations[id] ?? 0
        Task { [weak self] in
            let url = await svc.repoManager.remoteURL(path: id)
            let healthInfo = await svc.repoManager.health(path: id)
            let foreignInstancePID = svc.repoManager.foreignInstancePID(path: id)
            let st = await svc.sync.status(for: id)
            let mode = await svc.repoManager.authMode(path: id)
            // SshKeyChecker.guidance is nil when a public key exists; it used to
            // be dead code, so SSH setups failed with a raw git error and no
            // explanation (v4.2.26 audit M8).
            let sshGuidance = svc.sshChecker.guidance
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
                // A newer fill (or a save) superseded this one: never write the
                // stale pre-save values back (v4.2.28).
                guard self.fillGenerations[id] == pass else { return }
                // Never wipe text the user is typing.
                if !self.editedPaths.contains(id) {
                    self.rootCards[idx].repo.urlText = url ?? ""
                }
                if let foreignInstancePID {
                    self.rootCards[idx].repo.health = String(
                        format: NSLocalizedString("⚠️ 另一个 FileVault 实例正在管理这个文件夹（pid %d）；退出那个实例后这里会自动接管",
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
                self.rootCards[idx].repo.statusLabel = FVStatusMeta.forSync(st).label
                self.rootCards[idx].repo.localOnly = (st == .noRemote)
                self.rootCards[idx].repo.excludedLargeFileCount = healthInfo.excludedLargeFileCount
                self.rootCards[idx].repo.authGuidance = sshGuidance ?? ""
                self.rootCards[idx].repo.remoteLimit = limitText
                self.rootCards[idx].repo.remoteNames = remoteNames
                // An unsaved auth-mode/account edit must survive a background
                // refresh instead of snapping back to the stored values.
                if !self.editedAuthModes.contains(id) {
                    self.rootCards[idx].repo.authMode = mode
                    if let stored {
                        if !self.editedAuthUsers.contains(id) {
                            self.rootCards[idx].repo.authUser = stored.username
                        }
                        self.rootCards[idx].repo.authTokenSaved = !stored.password.isEmpty
                    } else {
                        self.rootCards[idx].repo.authTokenSaved = false
                    }
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
        // While git is still installing there is no service yet; the toggle
        // used to silently drop every change (and the language picker snapped
        // back) with no feedback (v4.2.28). Persist straight to the config
        // store — updateGeneral's runtime apply is optional-chained anyway, so
        // nothing here needs a built service.
        guard let svc = service else {
            let store = ConfigStore(directory: ConfigStore.defaultDirectory)
            var cfg = store.load()
            cfg.general.notificationsEnabled = notificationsEnabled
            cfg.general.autoCheckUpdates = autoCheckUpdates
            cfg.general.debounceSeconds = debounceSeconds
            cfg.general.language = language
            // No repo card exists yet to carry an inline message; a failed
            // write is surfaced by the next successful reload reverting the
            // controls, and saveConfig-style failures are already reported by
            // the service once it starts.
            _ = store.save(cfg)
            generalCommitted = true
            return
        }
        guard generalCommitted else { return }
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
        guard let svc = service, let app else {
            // v4.2.31: settings can be open before the service exists (login
            // launch, --open-ui); the click used to be a silent no-op. The
            // support line now says why it did nothing.
            supportMessage = NSLocalizedString("Git 环境尚未就绪，请稍后重试（可在主面板查看原因）。",
                                                comment: "settings status")
            supportMessageIsError = true
            return
        }
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

    /// v4.2.30 audit item 10: support mail that already carries the app and
    /// macOS versions saves a round-trip.
    func composeSupportMail() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var osText = "macOS \(os.majorVersion).\(os.minorVersion)"
        if os.patchVersion > 0 { osText += ".\(os.patchVersion)" }
        if let url = Self.supportMailURL(appVersion: app?.version ?? "0", osText: osText) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Pure mailto builder so the contract is pinnable in tests (v4.2.31):
    /// the subject carries the app + OS versions, and a URLComponents failure
    /// falls back to a bare address instead of making the button a silent
    /// no-op.
    nonisolated static func supportMailURL(appVersion: String, osText: String) -> URL? {
        let subject = String(format: NSLocalizedString("FileVault 反馈（v%@ · %@）",
                                                        comment: "support mail subject"),
                             appVersion, osText)
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = AppBrand.supportEmail
        components.queryItems = [URLQueryItem(name: "subject", value: subject)]
        if let url = components.url { return url }
        return URL(string: "mailto:" + AppBrand.supportEmail)
    }

    /// v4.2.30 audit item 4: the card counts the excluded large files, this
    /// sheet names them with sizes.
    func openLargeFiles(_ id: String) {
        guard let svc = service, svc.isReady else { return }
        let repoName = (id as NSString).lastPathComponent
        Task { [weak self] in
            let rules = svc.repoManager.excludedLargeFiles(path: id)
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let rows = rules.map { rule in
                let absolute = (id as NSString).appendingPathComponent(rule)
                var sizeText = "—"
                if let attrs = try? FileManager.default.attributesOfItem(atPath: absolute),
                   let size = attrs[.size] as? UInt64 {
                    sizeText = formatter.string(fromByteCount: Int64(size))
                }
                return LargeFileRow(name: rule, size: sizeText)
            }
            await MainActor.run {
                self?.largeFilesViewer = LargeFilesState(repoName: repoName, rows: rows)
            }
        }
    }

    /// Changing the interface language: persist, point the bundle at the new
    /// localisation and relaunch (SwiftUI only resolves it at launch).
    func setLanguage(_ code: String) {
        // The picker used to dead-end while git was still installing (no
        // service yet): persist through the config store directly instead of
        // silently dropping the choice (v4.2.28).
        language = code
        if let svc = service {
            svc.updateGeneral { $0.language = code }
        } else {
            let store = ConfigStore(directory: ConfigStore.defaultDirectory)
            var cfg = store.load()
            cfg.general.language = code
            _ = store.save(cfg)
        }
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
            await MainActor.run {
                // Drop the "user typed here" mark so re-adding the same path
                // refills its remote field instead of showing it empty (M8/P3).
                self?.editedPaths.remove(card.id)
                self?.editedAuthModes.remove(card.id)
                self?.editedAuthUsers.remove(card.id)
                self?.reload()
            }
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
                    self.editedAuthUsers.insert(id)
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
                    self.editedAuthModes.insert(id)
                })
    }

    func message(_ id: String) -> (String, Color, String)? {
        guard let idx = indexOf(id) else { return nil }
        let s = rootCards[idx].repo
        return s.message.isEmpty ? nil : (s.message, s.messageIsError ? Color(nsColor: .systemRed) : Color(nsColor: .secondaryLabelColor), s.messageHelp)
    }

    private func setMessage(_ id: String, _ text: String, error: Bool = false, help: String = "") {
        guard let idx = indexOf(id) else { return }
        rootCards[idx].repo.message = text
        rootCards[idx].repo.messageIsError = error
        rootCards[idx].repo.messageHelp = help
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

    /// Result of one save attempt, for dialogs that wait for the bind
    /// (v4.2.30 audit item 6c): `.saved` closes the dialog, `.blocked` keeps
    /// it open and shows the message inside it.
    enum SaveOutcome {
        /// The remote state was persisted (address saved or remote cleared);
        /// the card carries the follow-up status line.
        case saved(String)
        /// Nothing was written; the message says why.
        case blocked(String)
    }

    /// Lightweight pre-save validation (v4.2.30 audit item 9; v4.2.31 moved
    /// the rule to Core and relaxed it — ssh://, http:// and scp-style
    /// addresses are real git remotes and the first cut silently rejected
    /// them). Still blocks the paste mistake it was made for: a bare host.
    nonisolated static func looksIncompleteRemote(_ raw: String) -> Bool {
        GitRemoteAddress.looksIncomplete(raw)
    }

    /// Shared save path: persist auth mode, configure + test + inline feedback (FR-06).
    func saveRepo(_ id: String, completion: (@MainActor (SaveOutcome) -> Void)? = nil) {
        guard let svc = service, let idx = indexOf(id) else {
            completion?(.blocked(NSLocalizedString("Git 环境尚未就绪，请稍后重试（可在主面板查看原因）。", comment: "settings status")))
            return
        }
        // git not ready yet: repoManager/sync are implicit unwraps until
        // start() finishes — these repo actions used to trap (v4.2.26 fixed
        // only some entries; these were missed) (v4.2.27).
        guard svc.isReady else {
            let msg = NSLocalizedString("Git 环境尚未就绪，请稍后重试（可在主面板查看原因）。", comment: "settings status")
            setMessage(id, msg)
            completion?(.blocked(msg))
            return
        }
        // v4.2.30 audit item 9: incomplete addresses never reach git config;
        // the field row shows the same hint while typing.
        if Self.looksIncompleteRemote(rootCards[idx].repo.urlText) {
            let msg = NSLocalizedString("远程地址看起来不完整（应以 https:// 或 git@ 开头）", comment: "settings status")
            setMessage(id, msg, error: true)
            completion?(.blocked(msg))
            return
        }
        // A double click / repeated Return must not run two overlapping saves:
        // two configureRemote/mergeSync/push chains race on index.lock and
        // overwrite each other's status (v4.2.26 audit M8).
        guard beginRepoOp(id) else {
            completion?(.blocked(NSLocalizedString("正在处理上一个操作，请稍候…", comment: "settings status")))
            return
        }
        let section = rootCards[idx].repo
        let url = section.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = section.authMode
        let user = section.authUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = section.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { [weak self] in
            guard let self else { return }
            defer { self.endRepoOp(id) }
            await MainActor.run { self.setMessage(id, NSLocalizedString("正在保存…", comment: "settings status")) }
            do {
                if url.isEmpty {
                    try await svc.sync.clearRemote(repoPath: id)
                    let cleared = NSLocalizedString("已清除远程仓库（仅本地模式）", comment: "settings status")
                    await MainActor.run {
                        self.setMessage(id, cleared)
                        self.fillRepoDetails(id: id)   // refresh the remote-derived limit
                        completion?(.saved(cleared))
                    }
                    self.editedPaths.remove(id)
                    self.editedAuthModes.remove(id)
                    self.editedAuthUsers.remove(id)
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
                        await GitRunner.ghAuthSetupGit()
                    }
                }

                // The remote address is always saved, even when the token is missing.
                // v4.2: syncing is not optional — saving a remote makes this folder
                // an automatically synced one, so auto-push is always on.
                let change = try await svc.sync.configureRemote(repoPath: id, url: url, autoPush: true)
                // The address is persisted now, so background refills may mirror
                // it again without wiping the user's typing (v4.2.26 M8/P3).
                self.editedPaths.remove(id)
                self.editedAuthModes.remove(id)
                self.editedAuthUsers.remove(id)
                // Invalidate fills that started before this save: their stale
                // pre-save values must not land after the marks were cleared
                // (v4.2.28). fillRepoDetails below starts a fresh pass.
                self.fillGenerations[id, default: 0] += 1
                if needsToken {
                    // The address itself persisted, so a waiting dialog closes;
                    // the card keeps prompting for the token (v4.2.30 audit 6c).
                    let tokenMsg = NSLocalizedString("已保存地址，但「用户名 + 访问令牌」还需要填写访问令牌（令牌只写进本机凭证库，不写进 git 配置）",
                                                      comment: "settings status")
                    await MainActor.run {
                        self.setMessage(id, tokenMsg, error: true)
                        completion?(.saved(tokenMsg))
                    }
                    return
                }
                await MainActor.run { self.setMessage(id, NSLocalizedString("已保存，正在测试连接…", comment: "settings status")) }
                await MainActor.run { self.fillRepoDetails(id: id) }   // remote limit may have changed
                let conn = await svc.sync.testConnectivity(repoPath: id)
                // v4.2.30 audit item 2: the failure line leads with the
                // classified reason (PullError.errorDescription); the condensed
                // git output rides along as hover detail instead of being the
                // whole message.
                let connMain = conn.failureMessage ?? conn.detail
                let connHelp = (conn.failureMessage != nil && conn.failureMessage != conn.detail) ? conn.detail : ""
                let status: String
                if change.changed && !change.fetchSucceeded {
                    status = String(format: NSLocalizedString("⚠️ 已保存新远程地址，但暂时读不到这个远程（检查地址或认证）：%@",
                                                             comment: "settings status"), connMain) + credentialNote
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
                                    connMain) + credentialNote
                }
                await MainActor.run {
                    self.setMessage(id, status, error: !conn.ok && !change.changed, help: connHelp)
                    // Every branch here persisted the address, so a waiting
                    // dialog closes; the probe result stays visible on the
                    // card (v4.2.30 audit item 6c).
                    completion?(.saved(status))
                }
            } catch {
                let failed = String(format: NSLocalizedString("⚠️ 保存失败：%@", comment: "settings status"),
                                    error.localizedDescription)
                await MainActor.run {
                    self.setMessage(id, failed, error: true)
                    completion?(.blocked(failed))
                }
            }
        }
    }

    func testConnection(_ id: String) {
        guard let svc = service else { return }
        // git not ready yet: repoManager/sync are implicit unwraps until
        // start() finishes — these repo actions used to trap (v4.2.26 fixed
        // only some entries; these were missed) (v4.2.27).
        guard svc.isReady else {
            setMessage(id, NSLocalizedString("Git 环境尚未就绪，请稍后重试（可在主面板查看原因）。", comment: "settings status"))
            return
        }
        // v4.2.31: a bare-host paste mistake is refused here too. 保存 blocks
        // it, but 测试 used to run `git ls-remote` on the fragment anyway —
        // git reads it as a LOCAL PATH, and the classified "无法访问" error
        // misled more than it explained. Synchronous: no busy lock is taken.
        if let idx = indexOf(id), Self.looksIncompleteRemote(rootCards[idx].repo.urlText) {
            let msg = NSLocalizedString("远程地址看起来不完整（应以 https:// 或 git@ 开头）", comment: "settings status")
            setMessage(id, msg, error: true)
            return
        }
        // v4.2.30 audit item 1: the button tests what is IN THE FIELD —
        // including unsaved edits — and only falls back to the stored remote
        // when the field is empty (the view greys it out when neither exists).
        let typed = indexOf(id).map { rootCards[$0].repo.urlText.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        // Same reentrancy guard as save: a second click while ls-remote is in
        // flight must not stack another git process (v4.2.26 audit M8).
        guard beginRepoOp(id) else { return }
        Task { [weak self] in
            defer { self?.endRepoOp(id) }
            let result = typed.isEmpty
                ? await svc.sync.testConnectivity(repoPath: id)
                : await svc.sync.testRemote(url: typed, repoPath: id)
            await MainActor.run {
                self?.connectionAlert = ConnectionAlert(ok: result.ok,
                                                        detail: result.detail,
                                                        summary: result.ok ? "" : (result.failureMessage ?? result.detail))
            }
        }
    }

    /// v4.0.5: read-only repository integrity check (git fsck --full).
    func checkIntegrity(_ id: String) {
        guard let svc = service else { return }
        // git not ready yet: repoManager/sync are implicit unwraps until
        // start() finishes — these repo actions used to trap (v4.2.26 fixed
        // only some entries; these were missed) (v4.2.27).
        guard svc.isReady else {
            setMessage(id, NSLocalizedString("Git 环境尚未就绪，请稍后重试（可在主面板查看原因）。", comment: "settings status"))
            return
        }
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
        // git not ready yet: repoManager/sync are implicit unwraps until
        // start() finishes — these repo actions used to trap (v4.2.26 fixed
        // only some entries; these were missed) (v4.2.27).
        guard svc.isReady else {
            setMessage(id, NSLocalizedString("Git 环境尚未就绪，请稍后重试（可在主面板查看原因）。", comment: "settings status"))
            return
        }
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
        // git not ready yet: repoManager/sync are implicit unwraps until
        // start() finishes — these repo actions used to trap (v4.2.26 fixed
        // only some entries; these were missed) (v4.2.27).
        guard svc.isReady else {
            setMessage(id, NSLocalizedString("Git 环境尚未就绪，请稍后重试（可在主面板查看原因）。", comment: "settings status"))
            return
        }
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
        guard let svc = service, svc.isReady else {
            // v4.2.31: during the git-setup window the card still renders as
            // available (health 「正在加载…」) and the 更多 menu is clickable;
            // a silent no-op read as a broken button.
            setMessage(id, NSLocalizedString("Git 环境尚未就绪，请稍后重试（可在主面板查看原因）。",
                                            comment: "settings status"))
            return
        }
        let name = (id as NSString).lastPathComponent
        do {
            let draft = try svc.repoManager.readGitignore(path: id)
            gitignoreEditor = GitignoreEditorState(repoPath: id, repoName: name, draft: draft)
        } catch {
            // Never open an empty editor when the rules could not be read:
            // saving that blank draft would overwrite the user's .gitignore
            // (e.g. a non-UTF-8 file or a permission error) — M8 data loss.
            Task { await alert(NSLocalizedString("无法读取忽略规则", comment: "settings alert"),
                               String(format: NSLocalizedString("读取 .gitignore 失败：%@。为避免覆盖已有规则，编辑器未打开。",
                                                                comment: "settings alert"),
                                      error.localizedDescription)) }
        }
    }

    /// Persist the .gitignore draft.
    ///
    /// Returns a readable failure message instead of throwing (the sheet shows
    /// it and stays open, so a failed write never looks like a save); nil means
    /// the rules were written and the editor can close (v4.2.26 audit M8).
    @discardableResult
    func saveGitignore(_ state: GitignoreEditorState) -> String? {
        guard let svc = service, svc.isReady else {
            return NSLocalizedString("Git 环境尚未就绪，请稍后重试（可在主面板查看原因）。",
                                     comment: "quick add")
        }
        do {
            try svc.repoManager.saveGitignore(path: state.repoPath, content: state.draft)
        } catch {
            return String(format: NSLocalizedString("⚠️ 保存失败：%@", comment: "settings status"),
                          error.localizedDescription)
        }
        gitignoreEditor = nil
        return nil
    }

    /// Open the create-repo dialog for one card (v4.2.30 audit item 6):
    /// resets the dialog state and prechecks gh.
    func openCreateRepo(_ id: String) {
        createRepoTarget = id
        // v4.2.31: prefill with the folder name, same as the quick-add sheet's
        // 「仓库名（默认用文件夹名）」— an invalid folder name (CJK, spaces)
        // keeps the button disabled with the naming hint explaining why.
        createRepoName = (id as NSString).lastPathComponent
        createRepoError = ""
        createRepoBusy = false
        // Precheck gh NOW: a missing CLI used to surface only after the user
        // had typed a name and clicked a doomed button (v4.2.30 audit 6b).
        ghMissing = GhRepoCreator.defaultGhPath().isEmpty
    }

    func createRepoAndBind(target: String, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, CreateRepoSheet.isValidRepoName(clean) else { return }
        guard !createRepoBusy else { return }
        // v4.2.31: a save already in flight for this folder would leave the
        // JUST-CREATED repo unbound (saveRepo blocks on the busy lock, and
        // retrying then hits gh's duplicate-name error). Refuse before gh
        // creates anything.
        if busyRepos.contains(target) {
            createRepoError = NSLocalizedString("正在处理上一个操作，请稍候…", comment: "settings status")
            return
        }
        createRepoBusy = true
        createRepoError = ""
        setMessage(target, String(format: NSLocalizedString("正在创建仓库 %@…", comment: "settings status"), clean))
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await GhRepoCreator().createPrivate(name: clean)
                await MainActor.run {
                    self.createRepoBusy = false
                    self.adoptCreatedRepoURL(url, target: target)
                    // v4.2.30 audit item 6c: the dialog stays open until the
                    // bind actually persisted; a failure shows inside it
                    // instead of flashing by and landing in the card's small
                    // status line.
                    self.saveRepo(target) { outcome in
                        switch outcome {
                        case .saved:
                            self.createRepoTarget = nil
                            self.createRepoError = ""
                        case .blocked(let message):
                            self.createRepoError = message
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.createRepoBusy = false
                    self.createRepoError = error.localizedDescription
                    self.setMessage(target, String(format: NSLocalizedString("⚠️ 创建失败: %@", comment: "settings status"),
                                                   error.localizedDescription), error: true)
                }
            }
        }
    }

    /// The URL gh just created is the user's NEW remote choice: mark it
    /// typed (the same contract as `urlBinding`) so a background refill
    /// cannot snap the field back to the previously stored remote — the
    /// refill guard only respects `editedPaths` (v4.2.31).
    func adoptCreatedRepoURL(_ url: String, target id: String) {
        if let idx = indexOf(id) {
            rootCards[idx].repo.urlText = url
            editedPaths.insert(id)
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
    /// Pause needs a confirmation: paused = edits generate NO versions while
    /// paused, which fights the product's core promise — the user must see
    /// that before the click lands (v4.2.27 design round).
    @State private var pauseTarget: RootCard?
    /// Folded root cards (v3.4.2); persisted so the layout survives reopening.
    @State private var collapse = RootCollapseState.load()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                generalCard
                // Folder cards are the main content of this page; the static
                // support card pushed them to the second screen (v4.2.27
                // design round IA fix).
                ForEach(model.rootCards) { card in
                    rootCard(card)
                }
                if model.rootCards.isEmpty {
                    emptyRootsCard
                } else {
                    addRootButton
                }
                supportCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fvCanvas()
        .task { model.bind(app) }
        .onDisappear { model.unbind() }
        .fileImporter(isPresented: $model.showFileImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.addRoot(at: url)
            }
        }
        .alert(item: $model.connectionAlert) { alert in
            // v4.2.30 audit item 2: the classified, readable reason is the
            // primary line; the condensed git output follows as the detail.
            // v4.2.31: a String ternary picks the verbatim Text initialiser,
            // which kept the title Chinese in English builds even though both
            // keys are translated. Per-branch literal Texts localize.
            Alert(title: alert.ok ? Text("连接成功") : Text("连接失败"),
                  message: Text(alert.ok || alert.summary.isEmpty || alert.summary == alert.detail
                                ? alert.detail
                                : alert.summary + "\n" + alert.detail),
                  dismissButton: .default(Text("好")))
        }
        .sheet(item: $model.gitignoreEditor) { editor in
            GitignoreSheet(state: editor) { draft in
                // Non-nil = the write failed: the sheet shows why and stays open.
                model.saveGitignore(GitignoreEditorState(repoPath: editor.repoPath,
                                                         repoName: editor.repoName, draft: draft))
            }
        }
        .sheet(isPresented: Binding(
            get: { model.createRepoTarget != nil },
            set: { if !$0 { model.createRepoTarget = nil } })) {
            // v4.2.30 audit item 6: a sheet (not a transient alert) so a failed
            // create/bind can be shown INSIDE the dialog instead of flashing
            // by and dumping the error into the card's small status line.
            CreateRepoSheet(name: $model.createRepoName,
                            errorText: $model.createRepoError,
                            busy: $model.createRepoBusy,
                            ghMissing: model.ghMissing,
                            onCreate: {
                                if let target = model.createRepoTarget {
                                    model.createRepoAndBind(target: target, name: model.createRepoName)
                                }
                            },
                            onCancel: {
                                model.createRepoTarget = nil
                                model.createRepoName = ""
                                model.createRepoError = ""
                            })
                .interactiveDismissDisabled(model.createRepoBusy)
        }
        .sheet(isPresented: $model.showFAQ) {
            FAQSheet()
        }
        .sheet(item: $model.largeFilesViewer) { viewer in
            LargeFilesSheet(state: viewer)
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
        .confirmationDialog("暂停自动提交？", isPresented: Binding(
            get: { pauseTarget != nil },
            set: { if !$0 { pauseTarget = nil } }), titleVisibility: .visible) {
            Button(String(format: NSLocalizedString("暂停「%@」", comment: "pause confirm"),
                          pauseTarget?.name ?? ""), role: .destructive) {
                if let target = pauseTarget {
                    model.pauseRoot(target, to: true)
                }
                pauseTarget = nil
            }
            Button("取消", role: .cancel) { pauseTarget = nil }
        } message: {
            Text("暂停期间的新改动不会生成版本、也不受保护；恢复暂停时会自动补交一次改动。请只用于搬运/整理文件夹等短时操作。")
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
            // v4.2.30 audit item 8: collapseAll/expandAll existed with test
            // coverage but no control ever called them (dead code).
            if !model.rootCards.isEmpty {
                HStack(spacing: 8) {
                    Button("全部折叠") {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            collapse.collapseAll(model.rootCards.map(\.id))
                            collapse.save()
                        }
                    }
                    .disabled(model.rootCards.allSatisfy { collapse.isCollapsed($0.id) })
                    Button("全部展开") {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            collapse.expandAll()
                            collapse.save()
                        }
                    }
                    .disabled(collapse.isEmpty)
                }
                .controlSize(.small)
            }
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
                        .accessibilityLabel(Text("登录时启动"))
                }
                FVHairline(leading: 16)
            }
            settingRow(title: "问题提醒通知",
                       detail: "提交/推送失败、大文件未备份等一次性提醒") {
                Toggle("", isOn: Binding(
                    get: { model.notificationsEnabled },
                    set: { model.notificationsEnabled = $0; model.commitGeneral() }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(Text("问题提醒通知"))
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
                    .accessibilityLabel(Text("自动检查更新"))
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
                .accessibilityLabel(Text("自动提交延迟"))
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
                .accessibilityLabel(Text("语言"))
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
            // Version already shown once in the 通用 card.
            FVSectionHeader(title: "关于与支持",
                            subtitle: "FileVault 永久免费 · 无账号、无订阅、无遥测")
            FVHairline(leading: 0)
            settingRow(title: "导出诊断包",
                       detail: "脱敏报告（不含文件内容/远程地址/账号），便于反馈问题") {
                Button("导出诊断包…") { model.exportDiagnostics() }
                    .controlSize(.small)
            }
            FVHairline(leading: 16)
            // v4.2.30 audit item 10: support is reachable from Settings, not
            // only from the repo README.
            settingRow(title: "反馈与支持",
                       detail: "发邮件反馈问题，主题自动附上版本号与系统版本") {
                Button("发邮件…") { model.composeSupportMail() }
                    .controlSize(.small)
            }
            FVHairline(leading: 16)
            settingRow(title: "常见问题",
                       detail: "误删找回、自动保存、大文件等 8 条解答") {
                Button("查看…") { model.showFAQ = true }
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
                // v4.2.31: the bare-literal ternary picked the verbatim
                // overload; the fold tooltip stayed Chinese in English.
                .help(isCollapsed ? LocalizedStringKey("展开文件夹") : LocalizedStringKey("折叠文件夹"))
                Menu {
                    Button("在 Finder 中打开") { app.openPath(card.path) }
                    // Pausing an unavailable folder is meaningless: there is no
                    // watcher/commit pipeline for it right now (v4.2.26 M8).
                    if card.repo.available {
                        // Pause = edits generate no versions while paused: confirm
                        // first. Resume is safe and stays one-click (v4.2.27).
                        // v4.2.31: the String ternary picked the verbatim Button
                        // initialiser (Chinese row in English builds) — the two
                        // labels are now literal branches, like MenuActionRow.
                        Button {
                            if card.paused {
                                model.pauseRoot(card, to: false)
                            } else {
                                pauseTarget = card
                            }
                        } label: {
                            if card.paused { Text("恢复自动提交") } else { Text("暂停自动提交") }
                        }
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
                repoBlock(card)
            }
        }
        .fvCard()
    }

    /// One repo: identity + status, remote field, then a calm row of controls.
    private func repoBlock(_ card: RootCard) -> some View {
        let repo = card.repo
        let typedRemote = repo.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 7) {
                // The status glyph already sits in the folder header; here the
                // same state is spelled out once (v4.2.21).
                Text(repo.statusLabel.isEmpty ? "…" : repo.statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(repo.statusColor)
                Spacer(minLength: 8)
                Text(repo.health)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(repo.available ? 1 : 2)
            }

            if repo.available {
                HStack(spacing: 8) {
                    TextField("https://github.com/用户名/仓库.git", text: model.urlBinding(repo.id))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11))
                        .onSubmit { model.saveRepo(repo.id) }
                    Button("保存") { model.saveRepo(repo.id) }
                        .controlSize(.small)
                    Button("测试") { model.testConnection(repo.id) }
                        .controlSize(.small)
                        // v4.2.30 audit item 1: nothing to probe when the
                        // field is empty AND no remote is stored.
                        .disabled(typedRemote.isEmpty && repo.remoteNames.isEmpty)
                }

                // v4.2.30 audit item 9: obvious paste mistakes (a bare host)
                // get an in-place red hint; the save guard blocks them too.
                if SettingsModel.looksIncompleteRemote(repo.urlText) {
                    Text("远程地址看起来不完整（应以 https:// 或 git@ 开头）")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .systemRed))
                } else if repo.localOnly && typedRemote.isEmpty {
                    // v4.2.30 audit item 3: an empty remote field plus a
                    // "仅本地" status needs its meaning spelled out once.
                    Text("版本只保存在本机，绑定远程后自动上云")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 12) {
                    // Authentication is "auto" for almost everyone; keep the
                    // controls folded so a folder card reads as a URL + status.
                    RepoAuthSection(repo: repo,
                                    mode: model.authModeBinding(repo.id),
                                    user: model.authUserBinding(repo.id),
                                    token: model.authTokenBinding(repo.id),
                                    save: { model.saveRepo(repo.id) })
                    Text(repo.remoteLimit)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("自动同步：本地改动立即推送，每约 5 分钟检查远端")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help("绑定远程的文件夹：本地改动防抖提交后立即推送；此外每约 5 分钟检查一次远端，有新提交就自动拉取合并。")
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
                        Button("在 GitHub 建仓并绑定…") { model.openCreateRepo(repo.id) }
                        Divider()
                        Button("检查仓库完整性…") { model.checkIntegrity(repo.id) }
                        Button("修复未完成的合并/变基…") { model.repairInterruptedOperation(repo.id) }
                    }
                    .controlSize(.small)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                // v4.2.30 audit item 4: excluded files are NOT backed up — a
                // dedicated orange row (not a suffix on the health line) makes
                // the loss visible and lists the files on click.
                if repo.excludedLargeFileCount > 0 {
                    Button {
                        model.openLargeFiles(repo.id)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                            Text(String(format: NSLocalizedString("%d 个大文件未备份", comment: "settings status"),
                                        repo.excludedLargeFileCount))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Color(nsColor: .systemOrange))
                    }
                    .buttonStyle(.plain)
                    .help("点击查看哪些文件超过了远程单文件上限")
                }
            } else {
                // Configured but not attached right now (disk unplugged, folder
                // moved, another live instance): the reason is already spelled
                // out above, so just offer a way back — removal stays in the
                // header menu (v4.2.26 audits M8/M9).
                HStack(spacing: 8) {
                    Button("重新定位（文件夹被移动/改名）…") { model.relocateRoot(repo.id) }
                        .controlSize(.small)
                    Spacer(minLength: 4)
                    Button("移除文件夹…", role: .destructive) { removeTarget = card }
                        .controlSize(.small)
                }
            }

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
                // v4.2.30 audit item 2: the two-line status truncates; hover
                // reveals the full classified reason plus the condensed git
                // output.
                .help(msg.2.isEmpty ? msg.0 : msg.0 + "\n\n" + msg.2)
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
    /// Returns a failure message when the file could not be written; the sheet
    /// then stays open. nil = saved.
    let onSave: (String) -> String?
    @State private var draft: String
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    init(state: GitignoreEditorState, onSave: @escaping (String) -> String?) {
        self.state = state
        self.onSave = onSave
        _draft = State(initialValue: state.draft)
    }

    /// Append `rule` on its own line unless it is already present (a trimmed
    /// comparison so surrounding whitespace never fools the check).
    ///
    /// Pure static so the chip behaviour is pinnable in tests (v4.2.31):
    /// a duplicate that slips through would silently promise protection
    /// the file does not actually have twice over.
    static func appendRule(_ rule: String, to draft: String) -> String {
        let existing = draft.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !existing.contains(rule) else { return draft }
        if draft.isEmpty {
            return rule
        } else if draft.hasSuffix("\n") {
            return draft + rule
        } else {
            return draft + "\n" + rule
        }
    }

    private func insertRule(_ rule: String) {
        draft = Self.appendRule(rule, to: draft)
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
            VStack(alignment: .leading, spacing: 4) {
                // v4.2.30 audit item 7: state the consequence up front —
                // "ignored" silently means "unrecoverable once deleted".
                Text("写在这里的文件不会留下版本，删除后无法找回")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                Text("每行一条，如 *.log 或 node_modules/")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
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
            // v4.2.30 audit item 7: one-tap insertions for the three patterns
            // nearly every macOS/git project wants; duplicates are skipped.
            HStack(spacing: 8) {
                ForEach([".DS_Store", "node_modules/", "*.log"], id: \.self) { rule in
                    Button {
                        insertRule(rule)
                    } label: {
                        Text(rule)
                            .font(.system(size: 10, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
                            .overlay(Capsule(style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            HStack {
                Text("保存后改动会被自动提交")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    // Keep the sheet open on failure: closing it made the user
                    // believe the rules had been saved (v4.2.26 audit M8).
                    if let failure = onSave(draft) {
                        errorText = failure
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 460)
        .background(FVTheme.canvas)
    }
}

/// Auth-mode detail row for one remote (FR-06).
///
/// Split out of repoBlock so it can be snapshotted offscreen in tests: PAT mode
/// must show real inputs — before v4.0.2 the picker had no fields to type into.
/// One folded row for authentication: nearly every folder uses "auto", so the
/// picker and PAT/SSH fields stay collapsed until someone actually needs them
/// (v4.2.19).
struct RepoAuthSection: View {
    let repo: RepoSection
    @Binding var mode: RepoManager.AuthMode
    @Binding var user: String
    @Binding var token: String
    let save: () -> Void
    @State private var expanded: Bool

    init(repo: RepoSection,
         mode: Binding<RepoManager.AuthMode>,
         user: Binding<String>,
         token: Binding<String>,
         save: @escaping () -> Void) {
        self.repo = repo
        _mode = mode
        _user = user
        _token = token
        self.save = save
        _expanded = State(initialValue: mode.wrappedValue != .auto)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $mode) {
                    Text("自动（gh 凭证助手）").tag(RepoManager.AuthMode.auto)
                    Text("用户名 + 访问令牌").tag(RepoManager.AuthMode.pat)
                    Text("SSH 密钥").tag(RepoManager.AuthMode.ssh)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 168)
                RepoAuthFields(mode: mode,
                               user: $user,
                               token: $token,
                               tokenSaved: repo.authTokenSaved,
                               guidance: repo.authGuidance,
                               save: save)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(String(format: NSLocalizedString("认证：%@", comment: "auth summary"),
                            authName(mode)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: mode) { _, newMode in
            // The persisted mode arrives asynchronously after the card is built,
            // so @State's initial value cannot know it: PAT/SSH folders used to
            // stay collapsed until clicked (v4.2.26 audit M8/P3).
            if newMode != .auto { expanded = true }
        }
    }

    private func authName(_ mode: RepoManager.AuthMode) -> String {
        switch mode {
        case .auto: return NSLocalizedString("自动", comment: "auth mode")
        case .pat: return NSLocalizedString("用户名 + 访问令牌", comment: "auth mode")
        case .ssh: return NSLocalizedString("SSH 密钥", comment: "auth mode")
        }
    }
}

struct RepoAuthFields: View {
    let mode: RepoManager.AuthMode
    @Binding var user: String
    @Binding var token: String
    let tokenSaved: Bool
    /// Non-empty when SSH mode is selected but ~/.ssh has no public key.
    var guidance: String = ""
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
            VStack(alignment: .leading, spacing: 4) {
                Text("使用 ~/.ssh 里的密钥；需要先把公钥添加到托管平台。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                // SshKeyChecker.guidance was never rendered: SSH setups without a
                // key only showed a raw "Permission denied (publickey)" from git
                // (v4.2.26 audit M8, README item 14).
                if !guidance.isEmpty {
                    Text(guidance)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }
            }
        case .auto:
            EmptyView()
        }
    }
}
