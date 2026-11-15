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
    var autoPush: Bool = false
    var authMode: RepoManager.AuthMode = .auto
    var authUser: String = ""
    var authToken: String = ""
    /// Remote-derived single-file ceiling, e.g. "100 MB（GitHub 硬限制）".
    var remoteLimit: String = "…"
    var message: String = ""
    var messageIsError: Bool = false
}

struct RootCard: Identifiable, Equatable {
    let id: String          // root path
    var name: String
    var path: String
    var paused: Bool
    var repos: [RepoSection]
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
    @Published var showFileImporter = false
    @Published var connectionAlert: ConnectionAlert?
    @Published var gitignoreEditor: GitignoreEditorState?
    @Published var createRepoTarget: String?
    @Published var createRepoName = ""

    /// Paths the user typed into — async refill must not wipe them.
    private var editedPaths: Set<String> = []
    private var generalCommitted = false
    private var app: AppState?

    func bind(_ app: AppState) {
        guard self.app == nil else { return }
        self.app = app
        reload()
        reloadLicenseState()
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
        generalCommitted = true

        rootCards = svc.rootsSnapshot().map { root in
            let cfgRoot = svc.configStore.load().roots.first { $0.path == root }
            let repos = svc.repoManager.firstLevelFolders(root: root).map { r in
                RepoSection(id: r.path, name: r.name)
            }
            return RootCard(id: root, name: (root as NSString).lastPathComponent,
                            path: root, paused: cfgRoot?.paused ?? false, repos: repos)
        }
        for card in rootCards {
            for section in card.repos {
                fillRepoDetails(id: section.id)
            }
        }
    }

    /// Async fill: url/toggle/health/status/auth.
    private func fillRepoDetails(id: String) {
        guard let svc = service else { return }
        Task { [weak self] in
            let url = await svc.repoManager.remoteURL(path: id)
            let auto = await svc.sync.autoPushEnabled(repoPath: id)
            let healthInfo = await svc.repoManager.health(path: id)
            let st = await svc.sync.status(for: id)
            let mode = await svc.repoManager.authMode(path: id)
            // The remote is the only authority on the single-file ceiling, so
            // the UI just mirrors it (v3.1.3: no local threshold setting).
            let limitText: String
            if GitHubLimits.isGitHubRemote(url) {
                limitText = "100 MB（GitHub 硬限制）"
            } else if let url, !url.isEmpty {
                limitText = "不限制（远端未提供单文件上限）"
            } else {
                limitText = "不限制（未配置远端）"
            }
            var storedUser: String?
            if let url {
                storedUser = await CredentialStore.fill(runner: svc.repoManager.runner, url: url)?.username
            }
            await MainActor.run { [weak self] in
                guard let self, let idx = self.indexOf(id) else { return }
                // Never wipe text the user is typing.
                if !self.editedPaths.contains(id) {
                    self.rootCards[idx.section].repos[idx.row].urlText = url ?? ""
                }
                self.rootCards[idx.section].repos[idx.row].autoPush = auto
                self.rootCards[idx.section].repos[idx.row].health = healthInfo.summary
                let glyph = Self.repoGlyph(st)
                self.rootCards[idx.section].repos[idx.row].statusGlyph = glyph.symbol
                self.rootCards[idx.section].repos[idx.row].statusColor = glyph.color
                self.rootCards[idx.section].repos[idx.row].authMode = mode
                self.rootCards[idx.section].repos[idx.row].remoteLimit = limitText
                if let storedUser {
                    self.rootCards[idx.section].repos[idx.row].authUser = storedUser
                }
            }
        }
    }

    struct SectionIndex { let section: Int; let row: Int }
    func indexOf(_ id: String) -> SectionIndex? {
        for (s, card) in rootCards.enumerated() {
            if let r = card.repos.firstIndex(where: { $0.id == id }) {
                return SectionIndex(section: s, row: r)
            }
        }
        return nil
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

    // MARK: - Licence & support (v3.2.0)

    @Published var licenseState: LicenseState = .trial(daysRemaining: AppBrand.trialDays)
    @Published var licenseTokenText = ""
    @Published var licenseMessage: String?
    @Published var licenseMessageIsError = false

    var licenseSummary: String { SupportBundle.describe(licenseState) }

    func reloadLicenseState() {
        guard let svc = service else { return }
        licenseState = svc.license.refresh()
    }

    func activateLicense() {
        guard let svc = service else { return }
        let token = licenseTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            licenseMessage = "请先粘贴激活码"
            licenseMessageIsError = true
            return
        }
        do {
            licenseState = try svc.license.activate(token)
            licenseTokenText = ""
            licenseMessage = "✓ 已激活：" + SupportBundle.describe(licenseState)
            licenseMessageIsError = false
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            licenseMessage = "⚠️ " + detail
            licenseMessageIsError = true
        }
    }

    func buyLicense() {
        guard let url = URL(string: AppBrand.purchaseURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Remove the local token so the user can paste a different licence.
    func deactivateLicenseForReentry() {
        guard let svc = service else { return }
        licenseState = svc.license.deactivate()
        licenseMessage = "已移除本机激活码"
        licenseMessageIsError = false
    }

    /// Build a privacy-conscious diagnostics zip users can attach to support mail.
    func exportDiagnostics() {
        guard let svc = service, let app else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FileVault-诊断-\(Self.dayStamp()).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let roots = svc.rootsSnapshot().map { ($0, svc.repoManager.firstLevelFolders(root: $0).count) }
        let report = SupportBundle.report(appVersion: app.version,
                                          license: svc.license,
                                          config: svc.configStore.load(),
                                          gitDescription: svc.detection.map { "\($0.gitPath) (\($0.version))" },
                                          roots: roots)
        do {
            _ = try SupportBundle.export(report: report,
                                         configDirectory: svc.configStore.directory,
                                         destination: dest)
            licenseMessage = "✓ 诊断包已保存到 \(dest.path)"
            licenseMessageIsError = false
        } catch {
            licenseMessage = "⚠️ " + error.localizedDescription
            licenseMessageIsError = true
        }
    }

    private static func dayStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
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
                await alert("设置登录自启失败", error.localizedDescription)
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
                await alert("添加根目录失败", error.localizedDescription)
            }
        }
    }

    // MARK: - Per-repo actions

    func urlBinding(_ id: String) -> Binding<String> {
        Binding(get: { [weak self] in self?.indexOf(id).flatMap { self?.rootCards[$0.section].repos[$0.row].urlText } ?? "" },
                set: { [weak self] text in
                    guard let self, let idx = self.indexOf(id) else { return }
                    self.rootCards[idx.section].repos[idx.row].urlText = text
                    self.editedPaths.insert(id)
                })
    }

    func autoPushBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { [weak self] in self?.indexOf(id).flatMap { self?.rootCards[$0.section].repos[$0.row].autoPush } ?? false },
                set: { [weak self] v in
                    guard let self, let idx = self.indexOf(id) else { return }
                    self.rootCards[idx.section].repos[idx.row].autoPush = v
                })
    }

    func authModeBinding(_ id: String) -> Binding<RepoManager.AuthMode> {
        Binding(get: { [weak self] in self?.indexOf(id).flatMap { self?.rootCards[$0.section].repos[$0.row].authMode } ?? .auto },
                set: { [weak self] v in
                    guard let self, let idx = self.indexOf(id) else { return }
                    self.rootCards[idx.section].repos[idx.row].authMode = v
                })
    }

    func message(_ id: String) -> (String, Color)? {
        guard let idx = indexOf(id) else { return nil }
        let s = rootCards[idx.section].repos[idx.row]
        return s.message.isEmpty ? nil : (s.message, s.messageIsError ? Color(nsColor: .systemRed) : Color(nsColor: .secondaryLabelColor))
    }

    private func setMessage(_ id: String, _ text: String, error: Bool = false) {
        guard let idx = indexOf(id) else { return }
        rootCards[idx.section].repos[idx.row].message = text
        rootCards[idx.section].repos[idx.row].messageIsError = error
    }

    /// Shared save path: configure + test + inline feedback (FR-06).
    func saveRepo(_ id: String) {
        guard let svc = service, let idx = indexOf(id) else { return }
        let section = rootCards[idx.section].repos[idx.row]
        let url = section.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let auto = section.autoPush
        Task { [weak self] in
            guard let self else { return }
            await MainActor.run { self.setMessage(id, "正在保存…") }
            do {
                if url.isEmpty {
                    try await svc.sync.clearRemote(repoPath: id)
                    await MainActor.run {
                        self.setMessage(id, "已清除远程仓库（仅本地模式）")
                        self.fillRepoDetails(id: id)   // refresh the remote-derived limit
                    }
                    return
                }
                try await svc.sync.configureRemote(repoPath: id, url: url, autoPush: auto)
                let modeRaw = await svc.repoManager.authMode(path: id)
                if modeRaw == .pat {
                    let token = await MainActor.run { [weak self] in
                        self?.indexOf(id).flatMap { self?.rootCards[$0.section].repos[$0.row].authToken }
                            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    }
                    if !token.isEmpty {
                        let user = await MainActor.run { [weak self] in
                            self?.indexOf(id).flatMap { self?.rootCards[$0.section].repos[$0.row].authUser }
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                        }
                        try await CredentialStore.store(runner: svc.repoManager.runner, url: url,
                                                        username: (user?.isEmpty == false ? user! : "personal-access-token"),
                                                        password: token)
                    }
                } else if url.contains("github.com") && url.hasPrefix("https://") {
                    _ = try? await GitRunner.ghAuthSetupGit()
                }
                await MainActor.run { self.setMessage(id, "已保存，正在测试连接…") }
                await MainActor.run { self.fillRepoDetails(id: id) }   // remote limit may have changed
                let conn = await svc.sync.testConnectivity(repoPath: id)
                self.editedPaths.remove(id)
                await MainActor.run { self.setMessage(id, conn.ok ? (auto ? "✓ 已保存并连通，提交后将自动推送" : "✓ 已保存并连通（自动推送未开启）") : "⚠️ 已保存但连接失败：\(conn.detail)", error: !conn.ok) }
            } catch {
                await MainActor.run { self.setMessage(id, "⚠️ 保存失败：\(error.localizedDescription)", error: true) }
            }
        }
    }

    func pushNow(_ id: String) {
        guard let svc = service else { return }
        Task { [weak self] in
            await svc.sync.pushNow(repoPath: id)
            await MainActor.run { self?.fillRepoDetails(id: id) }
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

    func pull(_ id: String) {
        guard let svc = service else { return }
        setMessage(id, "正在拉取…")
        Task { [weak self] in
            do {
                let out = try await svc.repoManager.pull(path: id)
                await MainActor.run { self?.setMessage(id, out.contains("Already up to date") ? "✓ 已是最新" : "✓ 已拉取远程更新（ff-only）") }
            } catch {
                await MainActor.run { self?.setMessage(id, "⚠️ 拉取失败：\(error.localizedDescription)", error: true) }
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
        setMessage(target, "正在创建仓库 \(clean)…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await GhRepoCreator().createPrivate(name: clean)
                await MainActor.run {
                    if let idx = self.indexOf(target) {
                        self.rootCards[idx.section].repos[idx.row].urlText = url
                    }
                    self.saveRepo(target)
                }
            } catch {
                await MainActor.run { self.setMessage(target, "⚠️ 创建失败: " + error.localizedDescription, error: true) }
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

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = SettingsModel()
    @State private var removeTarget: RootCard?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                generalCard
                licenseCard
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
        .confirmationDialog("移除根目录？", isPresented: Binding(
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
            Text("FileVault 只是不再守卫这个目录，已经生成的 .git 历史不会被删除。")
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
                            subtitle: "影响所有受保护目录",
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
                       detail: "启动 20 秒后检查一次，此后每天一次") {
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
                    ForEach([2, 5, 10, 30], id: \.self) { s in Text("\(s) 秒").tag(s) }
                }
                .labelsHidden()
                .frame(width: 92)
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

    private func settingRow<Control: View>(title: String,
                                           detail: String,
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

    // MARK: Licence & support (v3.2.0)

    private var licenseCard: some View {
        VStack(spacing: 0) {
            FVSectionHeader(title: "许可与支持",
                            subtitle: "试用 \(AppBrand.trialDays) 天 · 离线激活，激活信息只存本机钥匙串",
                            trailing: model.licenseState.isLicensed ? "Pro" : "试用")
            FVHairline(leading: 0)
            settingRow(title: "授权状态", detail: model.licenseSummary) {
                if model.licenseState.isLicensed {
                    FVStatusPill(text: "已激活", tint: .green, symbol: "checkmark.seal.fill")
                } else {
                    FVStatusPill(text: "未激活", tint: .orange, symbol: "key.fill")
                }
            }
            if !model.licenseState.isLicensed {
                FVHairline(leading: 16)
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        TextField("粘贴激活码（fv1.…）", text: $model.licenseTokenText)
                            .textFieldStyle(.roundedBorder)
                        Button("激活") { model.activateLicense() }
                            .buttonStyle(.borderedProminent)
                    }
                    HStack(spacing: 10) {
                        Button("购买 / 了解价格") { model.buyLicense() }
                        Button("导出诊断包…") { model.exportDiagnostics() }
                        Spacer()
                    }
                    .controlSize(.small)
                    Text("试用结束后自动提交会暂停；历史查看、文件恢复与整仓回滚始终可用。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                FVHairline(leading: 16)
                settingRow(title: "支持", detail: "导出脱敏诊断包（不含文件内容/激活码）发给支持团队") {
                    HStack(spacing: 8) {
                        Button("导出诊断包…") { model.exportDiagnostics() }
                        Button("更换授权…") { model.deactivateLicenseForReentry() }
                    }
                    .controlSize(.small)
                }
            }
            if let message = model.licenseMessage {
                FVHairline(leading: 16)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(model.licenseMessageIsError ? Color.red : Color.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .fvCard()
    }

    // MARK: Root cards

    private func rootCard(_ card: RootCard) -> some View {
        VStack(spacing: 0) {
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
                Text("\(card.repos.count) 个仓库")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Menu {
                    Button("在 Finder 中打开") { app.openPath(card.path) }
                    Button(card.paused ? "恢复自动提交" : "暂停自动提交") {
                        model.pauseRoot(card, to: !card.paused)
                    }
                    Divider()
                    Button("移除根目录…", role: .destructive) { removeTarget = card }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .help("根目录操作")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            FVHairline(leading: 0)
            if card.repos.isEmpty {
                FVEmptyState(symbol: "tray",
                             title: "这个目录里还没有子文件夹",
                             message: "在根目录下新建文件夹后，会自动成为独立版本库。")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(card.repos.enumerated()), id: \.element.id) { index, repo in
                        repoBlock(repo)
                        if index < card.repos.count - 1 {
                            FVHairline(leading: 16)
                        }
                    }
                }
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
                Text(repo.name)
                    .font(.system(size: 13, weight: .medium))
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
                Toggle("自动推送", isOn: model.autoPushBinding(repo.id))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
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
                    Button("立即推送") { model.pushNow(repo.id) }
                    Button("拉取远程更新") { model.pull(repo.id) }
                    Button("编辑忽略规则…") { model.openGitignoreEditor(repo.id) }
                    Button("在 GitHub 建仓并绑定…") { model.createRepoTarget = repo.id }
                }
                .controlSize(.small)
                .menuStyle(.borderlessButton)
                .fixedSize()
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
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyRootsCard: some View {
        VStack(spacing: 0) {
            FVEmptyState(symbol: "folder.badge.plus",
                         title: "还没有受保护的目录",
                         message: "选一个文件夹，它下面的每个子文件夹都会自动拥有独立的版本历史。",
                         actionTitle: "选择目录…",
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
                Text("添加根目录…")
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
