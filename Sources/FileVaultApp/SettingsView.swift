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
    @Published var thresholdText: String = "200"
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
        thresholdText = String(general.largeFileThresholdMB)
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

    /// Async fill: url/toggle/health/status/auth (v1.2.x async refill port).
    private func fillRepoDetails(id: String) {
        guard let svc = service else { return }
        Task { [weak self] in
            let url = await svc.repoManager.remoteURL(path: id)
            let auto = await svc.sync.autoPushEnabled(repoPath: id)
            let healthInfo = await svc.repoManager.health(path: id)
            let st = await svc.sync.status(for: id)
            let mode = await svc.repoManager.authMode(path: id)
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
            if let mb = Int(thresholdText.trimmingCharacters(in: .whitespaces)), mb > 0 {
                g.largeFileThresholdMB = mb
            }
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
                    await MainActor.run { self.setMessage(id, "已清除远程仓库（仅本地模式）") }
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

// MARK: - View

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = SettingsModel()
    @State private var removeTarget: RootCard?
    @State private var showCreateRepoAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                generalCard
                ForEach($model.rootCards) { $card in
                    rootCard($card)
                }
                HStack {
                    Button("＋ 添加根目录…") { model.showFileImporter = true }
                        .controlSize(.large)
                    Spacer()
                }
            }
            .padding(13)
        }
        .frame(minWidth: 660, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { model.bind(app) }
        .fileImporter(isPresented: $model.showFileImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.addRoot(at: url)
            }
        }
        .alert(item: $model.connectionAlert) { alert in
            Alert(title: Text(alert.ok ? "✅ 连接成功" : "⚠️ 连接失败"),
                  message: Text(alert.detail),
                  dismissButton: .default(Text("好")))
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
        .sheet(item: $model.gitignoreEditor) { editor in
            GitignoreSheet(state: editor) { draft in
                model.saveGitignore(GitignoreEditorState(repoPath: editor.repoPath,
                                                         repoName: editor.repoName, draft: draft))
            }
        }
    }

    // MARK: General card

    private var generalCard: some View {
        cardView {
            Text("通用设置").font(.system(size: 14, weight: .semibold))
            Divider()
            HStack(spacing: 16) {
                if LaunchAtLogin.available {
                    Toggle("登录时启动", isOn: Binding(
                        get: { model.loginIntent },
                        set: { model.toggleLoginIntent($0) }))
                }
                Toggle("推送失败通知", isOn: Binding(
                    get: { model.notificationsEnabled },
                    set: { model.notificationsEnabled = $0; model.commitGeneral() }))
                Toggle("自动检查更新", isOn: Binding(
                    get: { model.autoCheckUpdates },
                    set: { model.autoCheckUpdates = $0; model.commitGeneral() }))
            }
            HStack(spacing: 8) {
                Text("自动提交延迟").font(.system(size: 12))
                Picker("", selection: Binding(
                    get: { model.debounceSeconds },
                    set: { model.debounceSeconds = $0; model.commitGeneral() })) {
                    ForEach([2, 5, 10, 30], id: \.self) { s in Text("\(s) 秒").tag(s) }
                }
                .frame(width: 100)
                Text("（文件变动后等待静默的秒数）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("大文件阈值").font(.system(size: 12))
                TextField("200", text: Binding(
                    get: { model.thresholdText },
                    set: { model.thresholdText = $0; model.commitGeneral() }))
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                Text("MB（超过此大小的文件自动排除出版本管理）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("打开配置文件") { model.openConfigFile() }
        }
    }

    // MARK: Root card

    private func rootCard(_ card: Binding<RootCard>) -> some View {
        cardView {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.wrappedValue.name).font(.system(size: 14, weight: .semibold))
                    Text(card.wrappedValue.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Toggle("暂停", isOn: Binding(
                    get: { card.wrappedValue.paused },
                    set: { model.pauseRoot(card.wrappedValue, to: $0) }))
                    .toggleStyle(.checkbox)
                Button {
                    app.openPath(card.wrappedValue.path)
                } label: {
                    Label("打开", systemImage: "arrow.up.forward.app")
                }
                Button("移除", role: .destructive) { removeTarget = card.wrappedValue }
            }
            Divider()
            ForEach(card.wrappedValue.repos) { section in
                repoSection(section)
                if card.wrappedValue.repos.last?.id != section.id { Divider() }
            }
            if card.wrappedValue.repos.isEmpty {
                Text("此根目录暂无子文件夹")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("移除根目录？", isPresented: Binding(
            get: { removeTarget?.id == card.wrappedValue.id },
            set: { if !$0 { removeTarget = nil } }), titleVisibility: .visible) {
            Button("移除 \(card.wrappedValue.name)（仓库保留在磁盘）", role: .destructive) {
                model.removeRoot(card.wrappedValue)
                removeTarget = nil
            }
            Button("取消", role: .cancel) { removeTarget = nil }
        }
    }

    @ViewBuilder
    private func repoSection(_ section: RepoSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: section.statusGlyph)
                    .foregroundStyle(section.statusColor)
                    .font(.system(size: 12, weight: .medium))
                Text(section.name).font(.system(size: 13, weight: .medium))
                Text(section.health)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                TextField("远程仓库地址（留空 = 仅本地，回车保存）",
                          text: model.urlBinding(section.id))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 360)
                    .onSubmit { model.saveRepo(section.id) }
                Toggle("自动推送", isOn: model.autoPushBinding(section.id))
                    .toggleStyle(.checkbox)
            }
            HStack(spacing: 6) {
                Text("身份验证").font(.system(size: 12))
                Picker("", selection: model.authModeBinding(section.id)) {
                    Text("自动（gh 凭证助手）").tag(RepoManager.AuthMode.auto)
                    Text("用户名 + 访问令牌").tag(RepoManager.AuthMode.pat)
                    Text("SSH 密钥").tag(RepoManager.AuthMode.ssh)
                }
                .frame(width: 200)
            }
            HStack(spacing: 6) {
                Button("保存") { model.saveRepo(section.id) }
                Button("立即推送") { model.pushNow(section.id) }
                Button("测试连接") { model.testConnection(section.id) }
                Button("忽略规则") { model.openGitignoreEditor(section.id) }
                Button("拉取") { model.pull(section.id) }
                Button("建仓") { model.createRepoTarget = section.id }
                    .help("在 GitHub 创建私有仓库并绑定")
            }
            .controlSize(.small)
            if let msg = model.message(section.id) {
                Text(msg.0)
                    .font(.system(size: 10.5))
                    .foregroundStyle(msg.1)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func cardView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
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
        VStack(alignment: .leading, spacing: 8) {
            Text("忽略规则 — \(state.repoName)")
                .font(.system(size: 14, weight: .semibold))
            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .border(Color(nsColor: .separatorColor))
            Button("保存（改动会被自动提交）") {
                onSave(draft)
                dismiss()
            }
        }
        .padding(12)
        .frame(width: 520, height: 380)
    }
}
