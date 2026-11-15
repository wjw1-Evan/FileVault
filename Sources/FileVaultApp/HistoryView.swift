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
            let list = (try? await svc.history.commits(repoPath: repo, limit: 100)) ?? []
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

/// History window: repo pickers + commit list + per-file inline restore.
struct HistoryView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = HistoryModel()
    @State private var confirmRollback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { model.selectedRoot ?? "" },
                    set: { model.rootChanged($0) })) {
                    ForEach(model.roots, id: \.self) { root in
                        Label((root as NSString).lastPathComponent, systemImage: "folder")
                            .tag(root)
                    }
                }
                .frame(width: 200)
                Picker("", selection: Binding(
                    get: { model.selectedRepo ?? "" },
                    set: { model.repoChanged($0) })) {
                    ForEach(model.folders) { f in
                        Label(f.name, systemImage: "folder").tag(f.path)
                    }
                }
                .frame(width: 190)
                Spacer()
            }
            .padding([.top, .leading, .trailing], 12)

            commitTable
                .padding(.horizontal, 12)
            Text("此提交包含的文件（点「恢复」回到该时点）")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
            filesTable
                .padding(.horizontal, 12)
            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            Button("回滚整个文件夹到此版本", role: .destructive) { confirmRollback = true }
                .padding([.leading, .bottom], 12)
        }
        .padding(.bottom, 12)
        .frame(minWidth: 660, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { model.bind(app) }
        .onDisappear { model.unbind() }
        .confirmationDialog("回滚确认", isPresented: $confirmRollback, titleVisibility: .visible) {
            Button("回滚整个文件夹（丢弃之后的提交）", role: .destructive) { model.rollback() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会丢弃之后的提交，形成一次回滚记录。")
        }
    }

    private var commitTable: some View {
        Table(model.commits, selection: Binding(
            get: { model.selectedCommitHash ?? "" },
            set: { model.selectCommit($0) })) {
            TableColumn("版本") { c in Text(c.shortHash).monospacedDigit() }.width(80)
            TableColumn("提交信息") { c in Text(c.subject).lineLimit(1) }
            TableColumn("时间") { c in
                Text(c.date.formatted(.dateTime.month().day().hour().minute().second()))
                    .monospacedDigit()
            }.width(130)
        }
        .frame(height: 220)
    }

    private var filesTable: some View {
        Table(model.files) {
            TableColumn("变更") { f in Text(f.status).monospacedDigit() }.width(52)
            TableColumn("文件") { f in Text(f.path).lineLimit(1) }
            TableColumn("操作") { f in
                Button("恢复") { model.restoreFile(f.path) }
                    .controlSize(.small)
            }.width(90)
        }
        .frame(height: 140)
    }
}
