import SwiftUI
import FileVaultCore

/// One changed file row (Table requires Identifiable rows).
struct ChangedFile: Identifiable {
    let id: String
    let status: String
    let path: String
}

/// History content model (FR-09/10): commit browsing, per-file restore,
/// whole-folder rollback. Ported from HistoryWindowController with the
/// v2.6.5 auto-refresh + selection-preservation behavior intact.
@MainActor
final class HistoryModel: ObservableObject {
    @Published var roots: [String] = []
    @Published var folders: [SubRepo] = []
    @Published var selectedRoot: String?
    @Published var selectedRepo: String?
    @Published var commits: [CommitInfo] = []
    @Published var selectedCommitHash: String?
    @Published var files: [ChangedFile] = []
    @Published var statusText = "选择一个提交，查看并恢复它包含的文件"

    private var app: AppState?
    private var listenerToken: UUID?
    private var loadGeneration = 0
    private var filesGeneration = 0
    private var currentCommit: CommitInfo?
    private var pendingStateReload: Task<Void, Never>?

    func bind(_ app: AppState) {
        guard self.app == nil else { return }
        self.app = app
        reloadRepos()
        listenerToken = app.service?.addStateListener { [weak self] in
            Task { @MainActor in self?.handleExternalStateChange() }
        }
    }

    func unbind() {
        if let token = listenerToken { app?.service?.removeStateListener(token) }
        listenerToken = nil
        pendingStateReload?.cancel()
    }

    /// While visible, background auto-commits refresh the lists too; rapid
    /// state flips coalesce through one debounced task (v2.6.5).
    private func handleExternalStateChange() {
        pendingStateReload?.cancel()
        pendingStateReload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.reloadCommits(preserveSelection: true)
        }
    }

    func reloadRepos() {
        guard let svc = app?.service else { return }
        roots = svc.rootsSnapshot()
        selectedRoot = roots.first
        populateRepos()
    }

    private func populateRepos() {
        guard let svc = app?.service, let root = selectedRoot else {
            folders = []
            files = []
            commits = []
            selectedCommitHash = nil
            statusText = "尚未添加任何根目录——先在设置中添加根目录"
            return
        }
        folders = svc.repoManager.firstLevelFolders(root: root)
        selectedRepo = folders.first?.path
        loadGeneration += 1
        if folders.isEmpty {
            commits = []
            files = []
            selectedCommitHash = nil
            statusText = "该根目录暂无子文件夹"
        } else {
            reloadCommits()
        }
    }

    func rootChanged(_ newRoot: String) {
        selectedRoot = newRoot
        populateRepos()
    }

    func repoChanged(_ newRepo: String) {
        selectedRepo = newRepo
        selectedCommitHash = nil
        reloadCommits()
    }

    /// Reload commits. `preserveSelection` keeps the selected commit across
    /// background refreshes; operation reloads select the new HEAD. The file
    /// list refreshes EXPLICITLY (selecting the same row fires no callback —
    /// the v2.6.5 stale-file-list bug).
    func reloadCommits(preserveSelection: Bool = false) {
        guard let svc = app?.service, let repo = selectedRepo else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let preservedHash = preserveSelection ? selectedCommitHash : nil
        statusText = "正在加载提交历史…"
        Task { [weak self] in
            guard let self else { return }
            let raw = (try? await svc.history.commits(repoPath: repo, limit: 100)) ?? []
            // Legacy commits may carry git's octal-escaped paths; decode once here
            // so the list, detail header and restore status all read clean.
            let list = raw.map { c in
                CommitInfo(hash: c.hash, shortHash: c.shortHash,
                           subject: c.subject.fvDecodingGitEscapes, date: c.date)
            }
            guard generation == self.loadGeneration else { return }
            if list.isEmpty {
                self.commits = []
                self.files = []
                self.selectedCommitHash = nil
                self.statusText = "该文件夹还没有提交历史"
                return
            }
            self.commits = list
            var target = 0
            if let preservedHash, let idx = list.firstIndex(where: { $0.hash == preservedHash }) {
                target = idx
            }
            self.selectedCommitHash = list[target].hash
            self.loadChangedFiles()
        }
    }

    /// Changed files of the selected commit (with inline restore buttons).
    func loadChangedFiles() {
        guard let svc = app?.service, let repo = selectedRepo,
              let hash = selectedCommitHash,
              let commit = commits.first(where: { $0.hash == hash }) else {
            statusText = "选择一个提交以查看其包含的文件"
            return
        }
        currentCommit = commit
        filesGeneration += 1
        let generation = filesGeneration
        Task { [weak self] in
            guard let self else { return }
            let lines = (try? await svc.history.changedFiles(repoPath: repo, hash: commit.hash)) ?? []
            guard generation == self.filesGeneration else { return }
            self.files = lines.map { line -> ChangedFile in
                let parts = line.split(separator: "\t", maxSplits: 1)
                let path = parts.count > 1 ? String(parts[1]) : line
                return ChangedFile(id: path, status: parts.count > 1 ? String(parts[0]) : "?", path: path)
            }
            self.statusText = self.files.isEmpty
                ? "「" + commit.subject + "」没有文件变更"
                : "「" + commit.subject + "」包含 " + String(self.files.count) + " 个文件"
        }
    }

    func selectCommit(_ hash: String?) {
        guard let hash else { return }
        guard selectedCommitHash != hash else { return }
        selectedCommitHash = hash
        loadChangedFiles()
    }

    /// FR-10: restore one file to the selected commit; auto-commits the change.
    func restoreFile(_ file: String) {
        guard let svc = app?.service, let repo = selectedRepo, let commit = currentCommit else { return }
        Task { [weak self] in
            guard let self else { return }
            statusText = "正在恢复 \(file)…"
            do {
                _ = try await svc.history.restoreFile(repoPath: repo, file: file, to: commit.hash)
                statusText = "✓ 已恢复 \(file) 到 \(commit.shortHash)"
                reloadCommits()
            } catch {
                statusText = "⚠️ 恢复失败: \(error.localizedDescription)"
            }
        }
    }

    /// FR-10: hard rollback of the whole repo to the selected commit.
    func rollback() {
        guard let svc = app?.service, let repo = selectedRepo, let commit = currentCommit else { return }
        Task { [weak self] in
            guard let self else { return }
            statusText = "正在回滚…"
            do {
                try await svc.history.resetRepo(repoPath: repo, to: commit.hash)
                statusText = "✓ 已回滚到 \(commit.shortHash)"
                reloadCommits()
            } catch {
                statusText = "⚠️ 回滚失败: \(error.localizedDescription)"
            }
        }
    }
}

/// History window: repo sidebar, commit list, and a detail pane with per-file restore.
struct HistoryView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = HistoryModel()
    @State private var confirmRollback = false

    private var selectedCommit: CommitInfo? {
        guard let hash = model.selectedCommitHash else { return nil }
        return model.commits.first { $0.hash == hash }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 190, idealWidth: 210, maxWidth: 270)
            commitPane
                .frame(minWidth: 280, idealWidth: 330, maxWidth: 460)
            detailPane
                .frame(minWidth: 320, maxWidth: .infinity)
        }
        .frame(minWidth: 880, minHeight: 560)
        .fvCanvas()
        .task { model.bind(app) }
        .onDisappear { model.unbind() }
        .confirmationDialog("回滚确认", isPresented: $confirmRollback, titleVisibility: .visible) {
            Button("回滚整个文件夹到该版本", role: .destructive) { model.rollback() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("文件夹会回到这个版本，之后的提交从当前分支移除。未提交的改动会先自动保存，回滚前的状态也会备份到隐藏 ref（refs/filevault/backup，可用 git 找回），不会永久丢失。")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("根目录")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Picker("", selection: Binding(
                    get: { model.selectedRoot ?? "" },
                    set: { model.rootChanged($0) })) {
                    ForEach(model.roots, id: \.self) { root in
                        Text((root as NSString).lastPathComponent).tag(root)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 8)

            FVHairline(leading: 12)

            if model.folders.isEmpty {
                FVEmptyState(symbol: "folder",
                             title: "没有子文件夹",
                             message: "在根目录下新建文件夹后，这里会列出对应的版本库。")
            } else {
                List(selection: Binding(
                    get: { model.selectedRepo },
                    set: { if let value = $0 { model.repoChanged(value) } })) {
                    Section {
                        ForEach(model.folders) { folder in
                            HStack(spacing: 7) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange.opacity(0.85))
                                Text(folder.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                            }
                            .tag(folder.path)
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text("仓库")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
        .background(Color.primary.opacity(0.015))
    }

    // MARK: Commits

    private var commitPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("提交记录")
                    .font(FVTheme.sectionFont)
                Spacer()
                Text(model.commits.isEmpty ? "—" : "\(model.commits.count) 条")
                    .font(FVTheme.metaFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            FVHairline(leading: 0)

            if model.commits.isEmpty {
                FVEmptyState(symbol: "clock.arrow.circlepath",
                             title: "还没有提交历史",
                             message: "这个文件夹被守卫后，每次改动都会在这里留下一条记录。")
                Spacer()
            } else {
                List(selection: Binding(
                    get: { model.selectedCommitHash },
                    set: { model.selectCommit($0) })) {
                    ForEach(model.commits) { commit in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(commit.subject)
                                .font(.system(size: 12))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: 5) {
                                Text(commit.shortHash)
                                    .font(.system(size: 10, design: .monospaced))
                                Text("·")
                                    .font(.system(size: 10))
                                Text(FVTime.relative(commit.date))
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                        .tag(commit.hash)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
    }

    // MARK: Detail

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let commit = selectedCommit {
                commitHeader(commit)
                FVHairline(leading: 0)
                filesList
                Spacer(minLength: 0)
                detailFooter
            } else {
                FVEmptyState(symbol: "sidebar.left",
                             title: "选择一个提交",
                             message: "右侧会列出这个版本包含的文件，可以只恢复其中一个。")
                    .padding(.top, 40)
                Spacer(minLength: 0)
                detailFooter
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func commitHeader(_ commit: CommitInfo) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(commit.subject)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Text(commit.shortHash)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                Text(FVTime.absoluteWithSeconds(commit.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if !model.files.isEmpty {
                    Text("· \(model.files.count) 个文件")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var filesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("此版本包含的文件")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if model.files.isEmpty {
                FVEmptyState(symbol: "doc",
                             title: "没有文件变更",
                             message: "这个提交只包含空目录或元数据变化。")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.files.enumerated()), id: \.element.id) { index, file in
                            fileRow(file)
                            if index < model.files.count - 1 {
                                FVHairline(leading: 18)
                            }
                        }
                    }
                }
            }
        }
    }

    private func fileRow(_ file: ChangedFile) -> some View {
        HStack(spacing: 10) {
            Text(file.status)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(changeTint(file.status))
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(changeTint(file.status).opacity(0.12))
                )
            Text(file.path)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("恢复") { model.restoreFile(file.path) }
                .controlSize(.small)
                .help("把这个文件恢复到选中提交时的内容")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private func changeTint(_ status: String) -> Color {
        switch status {
        case "A": return .green
        case "D": return .red
        case "R": return .blue
        default: return .orange
        }
    }

    private var detailFooter: some View {
        VStack(spacing: 0) {
            FVHairline(leading: 0)
            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(model.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button("回滚整个文件夹", role: .destructive) { confirmRollback = true }
                    .controlSize(.small)
                    .disabled(selectedCommit == nil)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    private var statusSymbol: String {
        if model.statusText.hasPrefix("✓") { return "checkmark.circle.fill" }
        if model.statusText.hasPrefix("⚠️") { return "exclamationmark.triangle.fill" }
        return "info.circle"
    }
}
