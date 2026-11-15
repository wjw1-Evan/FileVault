import AppKit
import SwiftUI
import FileVaultCore

/// One changed file row (Table requires Identifiable rows).
struct ChangedFile: Identifiable, Equatable {
    let id: String
    let status: String
    let path: String

    /// Display name without directories.
    var name: String { (path as NSString).lastPathComponent }
    /// Parent directories, empty for files at the root of the folder.
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }
    /// Git name-status characters: A / M / D / R100 / C… / T.
    var statusCharacter: String { status.isEmpty ? "?" : String(status.prefix(1)) }
    var isDeleted: Bool { statusCharacter == "D" }
}

/// What the detail pane shows for the selected file (v4.0.1 history redesign).
enum FilePreviewState: Equatable {
    case none
    case loading
    case text(String)
    case image(Data)      // raw image bytes, rendered inline
    case binary(Int)      // byte size
    case tooLarge(Int)    // byte size
    case deleted
    case failed(String)
    case submodule
}

/// Which list the detail pane shows (v4.0.4): the files this commit touched,
/// or the complete snapshot ("full file tree") at that commit.
enum FileListMode: Equatable {
    case changed
    case all
}

/// Cheap extension-based classification: inline as text or hand to the default app.
enum HistoryPreviewKind: Equatable {
    case text
    case image
    case binary

    static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "log", "csv", "tsv", "json", "yaml", "yml", "xml",
        "html", "htm", "css", "js", "ts", "jsx", "tsx", "swift", "m", "mm", "h", "c", "cpp",
        "py", "rb", "go", "rs", "java", "kt", "sh", "zsh", "bash", "toml", "ini", "cfg", "conf",
        "tex", "bib", "sql", "diff", "patch", "plist",
    ]

    /// Formats NSImage can decode; previewed inline in the history pane.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jfif", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff",
        "ico", "icns",
    ]

    /// Text blobs larger than this are not inlined.
    static let textPreviewLimit = 250 * 1024
    /// Images larger than this are not decoded inline (memory guard).
    static let imagePreviewLimit = 20 * 1024 * 1024

    static func classify(path: String) -> HistoryPreviewKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext.isEmpty { return .text }
        if textExtensions.contains(ext) { return .text }
        if imageExtensions.contains(ext) { return .image }
        return .binary
    }
}

/// Day grouping for the history timeline (pure, unit-testable).
enum HistoryTimeline {
    struct DaySection: Identifiable, Equatable {
        let id: String
        let title: String
        let commits: [CommitInfo]
    }

    static func sections(for commits: [CommitInfo],
                         now: Date = Date(),
                         calendar: Calendar = .current,
                         locale: Locale = .current) -> [DaySection] {
        guard !commits.isEmpty else { return [] }
        var order: [Date] = []
        var buckets: [Date: [CommitInfo]] = [:]
        for commit in commits {
            let day = calendar.startOfDay(for: commit.date)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(commit)
        }
        let dayID = DateFormatter()
        dayID.locale = Locale(identifier: "en_US_POSIX")
        dayID.timeZone = calendar.timeZone
        dayID.dateFormat = "yyyy-MM-dd"
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        return order.map { day in
            let title: String
            if calendar.isDate(day, inSameDayAs: now) {
                title = NSLocalizedString("今天", comment: "history day section")
            } else if calendar.isDate(day, inSameDayAs: yesterday) {
                title = NSLocalizedString("昨天", comment: "history day section")
            } else {
                title = day.formatted(.dateTime.locale(locale).month().day().weekday(.wide))
            }
            return DaySection(id: dayID.string(from: day), title: title, commits: buckets[day] ?? [])
        }
    }
}

/// History content model (FR-09/10): commit browsing, per-file restore,
/// whole-folder rollback. Ported from HistoryWindowController with the
/// v2.6.5 auto-refresh + selection-preservation behavior intact.
@MainActor
final class HistoryModel: ObservableObject {
    @Published var roots: [String] = []
    @Published var selectedRoot: String?
    /// v4.0: the selected root IS the repo — kept as a separate optional so the
    /// async loaders read naturally.
    @Published var selectedRepo: String?
    @Published var commits: [CommitInfo] = []
    @Published var selectedCommitHash: String?
    @Published var files: [ChangedFile] = []
    /// "[changed | all]" selector in the detail pane.
    @Published var fileListMode: FileListMode = .changed
    /// Complete snapshot of the selected commit, as a folder/file tree.
    @Published var treeNodes: [HistoryTreeNode] = []
    @Published var treeFileCount = 0
    @Published var treeTruncated = false
    @Published var treeLoading = false
    @Published var treeError: String?
    /// Folders currently expanded in the tree view.
    @Published var expandedDirs: Set<String> = []
    /// Submodule paths in the snapshot (recorded commit only, no content).
    @Published var submodulePaths: Set<String> = []
    /// path -> A/M/D status character of the selected commit (tree badges).
    @Published var changedStatus: [String: String] = [:]
    @Published var statusText = NSLocalizedString("选择一个提交，查看并恢复它包含的文件", comment: "history status")
    /// Local filter over the loaded commit subjects / short hashes.
    @Published var searchText = ""
    /// Selected file inside the detail pane (drives the preview).
    @Published var selectedFile: String?
    @Published var preview: FilePreviewState = .none

    private var app: AppState?
    private var listenerToken: UUID?
    private var loadGeneration = 0
    private var filesGeneration = 0
    private var previewGeneration = 0
    private var treeGeneration = 0
    /// Commit whose snapshot is currently loaded (tree cache key).
    private var treeCommitHash: String?
    private var currentCommit: CommitInfo?
    private var pendingStateReload: Task<Void, Never>?

    /// Commits after the local search filter (newest first).
    var filteredCommits: [CommitInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return commits }
        return commits.filter {
            $0.subject.localizedCaseInsensitiveContains(query)
                || $0.shortHash.localizedCaseInsensitiveContains(query)
        }
    }

    func bind(_ app: AppState) {
        self.app = app
        if roots.isEmpty { reloadRepos() }
        // The window may be hidden and shown again: onDisappear removed the
        // listener, so re-register it here (otherwise refresh would silently
        // stop after the first close).
        guard listenerToken == nil, let svc = app.service else { return }
        listenerToken = svc.addStateListener { [weak self] in
            Task { @MainActor in self?.handleExternalStateChange() }
        }
    }

    func unbind() {
        if let token = listenerToken { app?.service?.removeStateListener(token) }
        listenerToken = nil
        pendingStateReload?.cancel()
    }

    /// While visible, background auto-commits and folder add/remove refresh the
    /// lists too; rapid state flips coalesce through one debounced task (v2.6.5).
    private func handleExternalStateChange() {
        pendingStateReload?.cancel()
        pendingStateReload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshAfterExternalChange()
        }
    }

    private func refreshAfterExternalChange() {
        guard let svc = app?.service else { return }
        let latest = svc.rootsSnapshot()
        if latest != roots {
            let previous = selectedRoot
            roots = latest
            if latest.isEmpty {
                selectedRoot = nil
                populateRepos()
                return
            }
            if previous == nil || !latest.contains(previous!) {
                selectedRoot = latest.first
                populateRepos()
                return
            }
            // The selected folder survived; fall through to a commit reload.
        }
        // Cheap HEAD check first: sync-status flips and duplicate notifications
        // must not reload (or flicker) the history while the user is reading it.
        guard let repo = selectedRepo else { return }
        Task { [weak self] in
            let head = try? await svc.repoManager.resolveHead(path: repo)
            await MainActor.run {
                guard let self, self.selectedRepo == repo else { return }
                if let head, self.commits.first?.hash == head { return }
                self.reloadCommits(preserveSelection: true)
            }
        }
    }

    /// Fallback poll for changes that produce no app event (e.g. a commit made
    /// from a terminal). Cheap no-op when HEAD did not move.
    func periodicRefresh() {
        refreshAfterExternalChange()
    }

    func reloadRepos() {
        guard let svc = app?.service else { return }
        roots = svc.rootsSnapshot()
        selectedRoot = roots.first
        populateRepos()
    }

    private func populateRepos() {
        guard app?.service != nil, let root = selectedRoot else {
            loadGeneration += 1
            selectedRepo = nil
            files = []
            commits = []
            selectedCommitHash = nil
            selectedFile = nil
            preview = .none
            changedStatus = [:]
            resetTreeState()
            statusText = NSLocalizedString("尚未添加任何文件夹——先在设置中添加文件夹", comment: "history status")
            return
        }
        // v4.0: the root folder is the repository; no sub-repo picker.
        selectedRepo = root
        loadGeneration += 1
        reloadCommits()
    }

    func rootChanged(_ newRoot: String) {
        guard newRoot != selectedRoot else { return }
        selectedRoot = newRoot
        selectedCommitHash = nil
        populateRepos()
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
        // Background refreshes must not flash a loading status over the footer.
        if !preserveSelection {
            statusText = NSLocalizedString("正在加载提交历史…", comment: "history status")
        }
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
                self.selectedFile = nil
                self.preview = .none
                self.statusText = NSLocalizedString("该文件夹还没有提交历史", comment: "history status")
                return
            }
            self.commits = list
            // New commits do not change the content of the commit the user is
            // reading: keep the selection, its file list and the preview intact.
            if preserveSelection, let preservedHash,
               list.contains(where: { $0.hash == preservedHash }),
               self.selectedCommitHash == preservedHash, !self.files.isEmpty {
                return
            }
            var target = 0
            if let preservedHash, let idx = list.firstIndex(where: { $0.hash == preservedHash }) {
                target = idx
            }
            self.selectedCommitHash = list[target].hash
            self.loadChangedFiles(preserveFile: preserveSelection)
        }
    }

    /// Changed files of the selected commit (with inline restore buttons).
    ///
    /// - Parameter preserveFile: keep the currently previewed file across a
    ///   background refresh when it still exists in the new commit.
    func loadChangedFiles(preserveFile: Bool = false) {
        let previousFile = preserveFile ? selectedFile : nil
        selectedFile = nil
        preview = .none
        previewGeneration += 1
        guard let svc = app?.service, let repo = selectedRepo,
              let hash = selectedCommitHash,
              let commit = commits.first(where: { $0.hash == hash }) else {
            files = []
            changedStatus = [:]
            resetTreeState()
            statusText = NSLocalizedString("选择一个提交以查看其包含的文件", comment: "history status")
            return
        }
        currentCommit = commit
        changedStatus = [:]
        resetTreeState()
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
            self.changedStatus = Dictionary(uniqueKeysWithValues: self.files.map { ($0.path, $0.statusCharacter) })
            // Keep the file the user was reading when possible; otherwise
            // auto-preview the first changed file so the pane is never empty.
            if let previousFile, self.files.contains(where: { $0.path == previousFile }) {
                self.selectFile(previousFile)
            } else if let first = self.files.first {
                self.selectFile(first.path)
            }
            self.statusText = self.files.isEmpty
                ? String(format: NSLocalizedString("「%@」没有文件变更", comment: "history status"), commit.subject)
                : String(format: NSLocalizedString("「%@」包含 %d 个文件", comment: "history status"),
                         commit.subject, self.files.count)
            // The tree is lazy: only load it when that pane is actually visible.
            if self.fileListMode == .all { self.loadFileTree() }
        }
    }

    func selectCommit(_ hash: String?) {
        guard let hash else { return }
        guard selectedCommitHash != hash else { return }
        selectedCommitHash = hash
        loadChangedFiles()
    }

    // MARK: - Full file tree (v4.0.4)

    /// Switch between the commit's changed files and its complete snapshot.
    /// The snapshot is loaded lazily and cached per commit.
    func setFileListMode(_ mode: FileListMode) {
        guard mode != fileListMode else { return }
        fileListMode = mode
        if mode == .all { loadFileTree() }
        refreshStatusForMode()
    }

    /// Load the complete snapshot of the selected commit.
    ///
    /// `git ls-tree` returns every file at that commit, not just the ones the
    /// commit touched, so unchanged files become browsable and restorable too.
    func loadFileTree(force: Bool = false) {
        guard let svc = app?.service, let repo = selectedRepo,
              let hash = selectedCommitHash,
              let commit = commits.first(where: { $0.hash == hash }) else {
            resetTreeState()
            return
        }
        if !force, treeCommitHash == commit.hash, !treeNodes.isEmpty { return }
        treeGeneration += 1
        let generation = treeGeneration
        treeCommitHash = commit.hash
        treeNodes = []
        treeFileCount = 0
        treeTruncated = false
        treeError = nil
        treeLoading = true
        submodulePaths = []
        expandedDirs = []
        refreshStatusForMode()
        Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await svc.history.filesAtCommit(repoPath: repo, hash: commit.hash)
                guard generation == self.treeGeneration else { return }
                let nodes = HistoryTree.build(entries: list.entries)
                self.treeNodes = nodes
                self.treeFileCount = list.count
                self.treeTruncated = list.truncated
                self.submodulePaths = Set(list.entries.filter { $0.kind == .submodule }.map(\.path))
                self.treeLoading = false
                // Folders start fully expanded one level deep so the tree is
                // immediately browsable; a selected file is revealed to its root.
                var expanded = Set(nodes.filter(\.isDirectory).map(\.path))
                if let file = self.selectedFile {
                    expanded.formUnion(HistoryTree.ancestorDirectories(of: file))
                }
                self.expandedDirs = expanded
                self.refreshStatusForMode()
            } catch {
                guard generation == self.treeGeneration else { return }
                self.treeLoading = false
                self.treeError = error.localizedDescription
                self.refreshStatusForMode()
            }
        }
    }

    /// Footer text follows the visible list: changed-file counts vs snapshot.
    private func refreshStatusForMode() {
        guard let commit = currentCommit else { return }
        // Never overwrite an operation result (restore/open/rollback feedback).
        if statusText.hasPrefix("✓") || statusText.hasPrefix("⚠️") { return }
        switch fileListMode {
        case .changed:
            statusText = files.isEmpty
                ? String(format: NSLocalizedString("「%@」没有文件变更", comment: "history status"), commit.subject)
                : String(format: NSLocalizedString("「%@」包含 %d 个文件", comment: "history status"),
                         commit.subject, files.count)
        case .all:
            if treeLoading {
                statusText = NSLocalizedString("正在读取该版本的文件…", comment: "history status")
            } else if let treeError {
                statusText = String(format: NSLocalizedString("⚠️ 无法列出文件：%@", comment: "history status"),
                                    treeError)
            } else {
                statusText = String(format: NSLocalizedString("「%@」共有 %d 个文件", comment: "history status"),
                                    commit.subject, treeFileCount)
            }
        }
    }

    func toggleDirectory(_ path: String) {
        if expandedDirs.contains(path) {
            expandedDirs.remove(path)
        } else {
            expandedDirs.insert(path)
        }
    }

    var areAllFoldersExpanded: Bool {
        guard !treeNodes.isEmpty else { return false }
        return expandedDirs == HistoryTree.allDirectoryPaths(treeNodes)
    }

    func setAllFoldersExpanded(_ expanded: Bool) {
        expandedDirs = expanded ? HistoryTree.allDirectoryPaths(treeNodes) : []
    }

    private func resetTreeState() {
        treeGeneration += 1
        treeNodes = []
        treeFileCount = 0
        treeTruncated = false
        treeLoading = false
        treeError = nil
        treeCommitHash = nil
        expandedDirs = []
        submodulePaths = []
    }

    // MARK: - File preview (v4.0.1 history redesign)

    /// Select a file in the detail pane and load its preview at the commit.
    func selectFile(_ path: String?) {
        guard selectedFile != path else { return }
        selectedFile = path
        previewGeneration += 1
        let generation = previewGeneration
        // Reveal the file inside the tree view (also when switching modes).
        if let path, !path.isEmpty {
            expandedDirs.formUnion(HistoryTree.ancestorDirectories(of: path))
        }
        guard let path, let svc = app?.service, let repo = selectedRepo, let commit = currentCommit else {
            preview = .none
            return
        }
        if isDeleted(path) {
            preview = .deleted
            return
        }
        if submodulePaths.contains(path) {
            preview = .submodule
            return
        }
        let kind = HistoryPreviewKind.classify(path: path)
        preview = .loading
        Task { [weak self] in
            guard let self else { return }
            let size = (try? await svc.history.fileSize(repoPath: repo, hash: commit.hash, file: path)) ?? 0
            guard generation == self.previewGeneration else { return }
            switch kind {
            case .binary:
                self.preview = .binary(size)
            case .image:
                guard size <= HistoryPreviewKind.imagePreviewLimit else {
                    self.preview = .tooLarge(size)
                    return
                }
                do {
                    let data = try await svc.history.fileData(repoPath: repo, hash: commit.hash, file: path)
                    guard generation == self.previewGeneration else { return }
                    self.preview = NSImage(data: data) != nil ? .image(data) : .binary(size)
                } catch {
                    guard generation == self.previewGeneration else { return }
                    self.preview = .failed(error.localizedDescription)
                }
            case .text:
                guard size <= HistoryPreviewKind.textPreviewLimit else {
                    self.preview = .tooLarge(size)
                    return
                }
                do {
                    let text = try await svc.history.fileContent(repoPath: repo, hash: commit.hash, file: path)
                    guard generation == self.previewGeneration else { return }
                    self.preview = .text(text)
                } catch {
                    guard generation == self.previewGeneration else { return }
                    self.preview = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Whether the file was deleted in the selected commit (no blob to show).
    func isDeleted(_ path: String) -> Bool {
        files.first { $0.path == path }?.isDeleted ?? false
    }

    func copyHash(_ hash: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hash, forType: .string)
        statusText = NSLocalizedString("已复制完整哈希", comment: "history status")
    }


    // MARK: Open a historical version (v3.4.3)

    /// Open the file as it existed in the selected commit, using the default app.
    /// The blob is exported to a temp file that keeps the original name and
    /// extension, so images/PDFs/text all open in the right application.
    func openFile(_ file: String) {
        guard let svc = app?.service, let repo = selectedRepo, let commit = currentCommit else { return }
        Task { @MainActor in
            statusText = String(format: NSLocalizedString("正在打开 %@…", comment: "history status"), file)
            do {
                let destination = Self.historicalTempURL(commit: commit.shortHash, file: file)
                try await svc.history.exportFile(repoPath: repo, hash: commit.hash, file: file, to: destination)
                NSWorkspace.shared.open(destination)
                statusText = String(format: NSLocalizedString("✓ 已打开 %@（%@ 版本）", comment: "history status"),
                                    file, commit.shortHash)
            } catch {
                statusText = String(format: NSLocalizedString("⚠️ 打开失败: %@", comment: "history status"),
                                    error.localizedDescription)
            }
        }
    }

    /// Temp location for an exported historical version (keeps sub-paths).
    static func historicalTempURL(commit: String, file: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FileVault-History", isDirectory: true)
            .appendingPathComponent(commit, isDirectory: true)
            .appendingPathComponent(file)
    }

    /// FR-10: restore one file to the selected commit; auto-commits the change.
    func restoreFile(_ file: String) {
        guard let svc = app?.service, let repo = selectedRepo, let commit = currentCommit else { return }
        Task { [weak self] in
            guard let self else { return }
            statusText = String(format: NSLocalizedString("正在恢复 %@…", comment: "history status"), file)
            do {
                _ = try await svc.history.restoreFile(repoPath: repo, file: file, to: commit.hash)
                statusText = String(format: NSLocalizedString("✓ 已恢复 %@ 到 %@", comment: "history status"),
                                    file, commit.shortHash)
                reloadCommits()
            } catch {
                statusText = String(format: NSLocalizedString("⚠️ 恢复失败: %@", comment: "history status"),
                                    error.localizedDescription)
            }
        }
    }

    /// FR-10: hard rollback of the whole repo to the selected commit.
    func rollback() {
        guard let svc = app?.service, let repo = selectedRepo, let commit = currentCommit else { return }
        Task { [weak self] in
            guard let self else { return }
            statusText = NSLocalizedString("正在回滚…", comment: "history status")
            do {
                try await svc.history.resetRepo(repoPath: repo, to: commit.hash)
                statusText = String(format: NSLocalizedString("✓ 已回滚到 %@", comment: "history status"),
                                    commit.shortHash)
                reloadCommits()
            } catch {
                statusText = String(format: NSLocalizedString("⚠️ 回滚失败: %@", comment: "history status"),
                                    error.localizedDescription)
            }
        }
    }
}

/// History window (v4.0.1 redesign): a day-grouped timeline on the left and a
/// detail pane on the right.
///
/// The old three-column layout spent a whole column on a folder picker that —
/// after the v4.0 single-repo change — had nothing else to show. The picker now
/// lives in the toolbar, the timeline groups commits by day and is searchable,
/// and the detail pane previews the selected file version in place.
struct HistoryView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = HistoryModel()
    @State private var confirmRollback = false

    private var selectedCommit: CommitInfo? {
        guard let hash = model.selectedCommitHash else { return nil }
        return model.commits.first { $0.hash == hash }
    }

    private var folderName: String {
        model.selectedRoot.map { ($0 as NSString).lastPathComponent } ?? ""
    }

    private var sections: [HistoryTimeline.DaySection] {
        HistoryTimeline.sections(for: model.filteredCommits)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            FVHairline(leading: 0)
            if model.roots.isEmpty {
                noRoots
            } else {
                HSplitView {
                    timeline
                        .frame(minWidth: 300, idealWidth: 344, maxWidth: 440)
                    detailPane
                        .frame(minWidth: 470, maxWidth: .infinity)
                }
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .fvCanvas()
        .task {
            model.bind(app)
            // Fallback poll: catches commits made outside FileVault (terminal,
            // a fetch/pull, another tool) which fire no app event. The HEAD
            // comparison makes it a no-op when nothing changed.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { break }
                model.periodicRefresh()
            }
        }
        .onDisappear { model.unbind() }
        .confirmationDialog("回滚确认", isPresented: $confirmRollback, titleVisibility: .visible) {
            Button("回滚到该版本", role: .destructive) { model.rollback() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("文件夹中受版本管理的内容会回到这个版本，其后的提交从当前分支移除。被忽略的文件、大文件和嵌套仓库保持原样；已绑定的远程仓库不会跟着回退（之后「拉取远程更新」可能把版本带回来）。未提交的改动会先自动保存，回滚前的状态备份到隐藏 ref（refs/filevault/backup，可用 git 找回），不会永久丢失。")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            if model.roots.isEmpty {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("历史版本")
                    .font(.system(size: 15, weight: .semibold))
            } else {
                folderMenu
            }
            Spacer(minLength: 12)
            if !model.roots.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: NSLocalizedString("%d 个提交", comment: "history caption"), model.commits.count))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let latest = model.commits.first {
                        Text(FVTime.absolute(latest.date))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var folderMenu: some View {
        // The badge lives OUTSIDE the Menu: a Menu label is rendered with
        // template styling, which would flatten the coloured folder badge.
        HStack(spacing: 9) {
            FVIconBadge(symbol: "folder.fill", tint: .orange, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Menu {
                    ForEach(model.roots, id: \.self) { root in
                        Button {
                            model.rootChanged(root)
                        } label: {
                            if root == model.selectedRoot {
                                Label((root as NSString).lastPathComponent, systemImage: "checkmark")
                            } else {
                                Text((root as NSString).lastPathComponent)
                            }
                        }
                    }
                    Divider()
                    if let root = model.selectedRoot {
                        Button("在 Finder 中打开") { app.openPath(root) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(folderName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("切换受保护的文件夹")
                if let path = model.selectedRoot {
                    Text(path)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var noRoots: some View {
        FVEmptyState(symbol: "folder.badge.plus",
                     title: "还没有受保护的文件夹",
                     message: "在设置里添加一个文件夹，它里面每次改动都会在这里留下一条记录。",
                     actionTitle: "打开设置",
                     action: { openWindow(id: "settings") })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Timeline (left)

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("时间线")
                    .font(FVTheme.sectionFont)
                Spacer()
                Text("\(model.commits.count)")
                    .font(FVTheme.metaFont)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            FVHairline(leading: 0)

            if model.commits.isEmpty {
                FVEmptyState(symbol: "clock.arrow.circlepath",
                             title: "还没有提交历史",
                             message: "这个文件夹被保护后，每次改动都会自动留下一条记录。")
                    .padding(.top, 24)
                Spacer(minLength: 0)
            } else if sections.isEmpty {
                FVEmptyState(symbol: "magnifyingglass",
                             title: "没有匹配的提交",
                             message: "换个关键词试试，或者清空搜索框。")
                    .padding(.top, 24)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            Text(section.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 14)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(section.commits) { commit in
                                CommitRow(commit: commit,
                                          isSelected: commit.hash == model.selectedCommitHash) {
                                    model.selectCommit(commit.hash)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.012))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("搜索提交内容或哈希", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: - Detail (right)

    private var detailPane: some View {
        VStack(spacing: 0) {
            if let commit = selectedCommit {
                commitHeader(commit)
                FVHairline(leading: 0)
                filesSection
                FVHairline(leading: 0)
                previewSection
                FVHairline(leading: 0)
                footer(commit: commit)
            } else {
                FVEmptyState(symbol: "sidebar.left",
                             title: "选择一个提交",
                             message: "这里会显示它包含的文件，可以预览、打开或恢复其中一个。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                FVHairline(leading: 0)
                footer(commit: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func commitHeader(_ commit: CommitInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(commit.subject)
                .font(.system(size: 16, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button {
                    model.copyHash(commit.hash)
                } label: {
                    HStack(spacing: 4) {
                        Text(commit.shortHash)
                            .font(.system(size: 10, design: .monospaced))
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("复制完整哈希")
                Text(FVTime.absoluteWithSeconds(commit.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Picker("", selection: Binding(
                    get: { model.fileListMode },
                    set: { model.setFileListMode($0) }
                )) {
                    Text("变更").tag(FileListMode.changed)
                    Text("全部").tag(FileListMode.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 112)
                .help("切换变更文件与完整文件树")
                Text(fileCountText)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                if model.fileListMode == .all && !model.treeNodes.isEmpty {
                    Button(model.areAllFoldersExpanded ? "折叠全部" : "展开全部") {
                        model.setAllFoldersExpanded(!model.areAllFoldersExpanded)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.system(size: 10))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 5)

            if model.fileListMode == .changed {
                changedFilesList
            } else {
                fullTreeList
            }
        }
    }

    private var fileCountText: String {
        model.fileListMode == .changed ? "\(model.files.count)" : "\(model.treeFileCount)"
    }

    @ViewBuilder
    private var changedFilesList: some View {
        if model.files.isEmpty {
            Text("没有文件变更")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.files) { file in
                        ChangedFileRow(file: file,
                                       selected: file.path == model.selectedFile,
                                       onSelect: { model.selectFile(file.path) },
                                       onOpen: { model.openFile(file.path) },
                                       onRestore: { model.restoreFile(file.path) })
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            // Fit the rows instead of reserving a fixed 220pt band: with
            // two files that band left a large dead gap above the preview.
            .frame(height: filesListHeight)
        }
    }

    @ViewBuilder
    private var fullTreeList: some View {
        if model.treeLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在读取该版本的文件…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        } else if let error = model.treeError {
            VStack(alignment: .leading, spacing: 3) {
                Text("无法列出该版本的文件")
                    .font(.system(size: 11, weight: .medium))
                Text(error)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        } else if model.treeNodes.isEmpty {
            Text("这个版本里没有文件")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(treeRows, id: \.node.id) { row in
                        TreeRow(row: row,
                                status: model.changedStatus[row.node.path],
                                selected: !row.node.isDirectory && row.node.path == model.selectedFile,
                                isExpanded: model.expandedDirs.contains(row.node.path),
                                onToggle: { model.toggleDirectory(row.node.path) },
                                onSelect: { model.selectFile(row.node.path) },
                                onOpen: { model.openFile(row.node.path) },
                                onRestore: { model.restoreFile(row.node.path) })
                    }
                    if model.treeTruncated {
                        Text(String(format: NSLocalizedString("文件较多，仅显示前 %d 个", comment: "history tree"),
                                    model.treeFileCount))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .frame(height: treeListHeight)
        }
    }

    private var treeRows: [HistoryTreeRow] {
        HistoryTree.flatten(model.treeNodes, expanded: model.expandedDirs)
    }

    private var treeListHeight: CGFloat {
        min(CGFloat(treeRows.count) * 24 + 14, 300)
    }

    private var filesListHeight: CGFloat {
        let rows = model.files.reduce(CGFloat(0)) { total, file in
            total + (file.directory.isEmpty ? 30 : 42)
        }
        return min(max(rows + 10, 34), 232)
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("预览")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                if let path = model.selectedFile {
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let path = model.selectedFile, !model.isDeleted(path),
                   !model.submodulePaths.contains(path) {
                    Button {
                        model.openFile(path)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 9))
                            Text("用默认应用打开")
                                .font(.system(size: 10))
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 6)

            previewBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var previewBody: some View {
        if model.selectedFile == nil {
            placeholder("选择一个文件，查看它在这个版本里的内容")
        } else {
            switch model.preview {
            case .none:
                placeholder("选择一个文件，查看它在这个版本里的内容")
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在载入…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            case .text(let text):
                ScrollView([.horizontal, .vertical]) {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            case .image(let data):
                if let image = NSImage(data: data) {
                    VStack(spacing: 6) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(10)
                        Text(Self.imageInfo(data, image))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .padding(.bottom, 6)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                    )
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
                } else {
                    previewNote(symbol: "photo",
                                title: "无法预览这张图片",
                                detail: "可以用默认应用打开查看")
                }
            case .binary(let size):
                previewNote(symbol: "doc.richtext",
                            title: "无法在应用内预览",
                            detail: String(format: NSLocalizedString("%@ · 可以用默认应用打开查看内容", comment: "history preview"),
                                           Self.sizeText(size)))
            case .tooLarge(let size):
                previewNote(symbol: "doc.badge.ellipsis",
                            title: "文件较大，未在此预览",
                            detail: String(format: NSLocalizedString("%@ · 可以用默认应用打开查看", comment: "history preview"),
                                           Self.sizeText(size)))
            case .deleted:
                previewNote(symbol: "trash",
                            title: "该版本中此文件已被删除",
                            detail: "更早的提交里仍然保留着它的内容。")
            case .failed(let message):
                previewNote(symbol: "exclamationmark.triangle",
                            title: "预览失败",
                            detail: message)
            case .submodule:
                previewNote(symbol: "shippingbox",
                            title: "这是子模块",
                            detail: "这里只记录子模块的提交号，不能直接预览或恢复。")
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func previewNote(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
    }

    private func footer(commit: CommitInfo?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(footerText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(role: .destructive) {
                confirmRollback = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9))
                    Text("回滚到该版本…")
                        .font(.system(size: 11))
                }
            }
            .controlSize(.small)
            .disabled(commit == nil)
            .help("把这个文件夹中受版本管理的内容回滚到选中版本（其后的提交从当前分支移除）")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    /// Operation feedback wins; otherwise show what is selected instead of
    /// repeating the commit subject that the header already displays.
    private var footerText: String {
        if model.statusText.hasPrefix("✓") || model.statusText.hasPrefix("⚠️") {
            return model.statusText
        }
        if let path = model.selectedFile {
            return String(format: NSLocalizedString("已选择 %@", comment: "history footer"), path)
        }
        return model.statusText
    }

    private var statusSymbol: String {
        if model.statusText.hasPrefix("✓") { return "checkmark.circle.fill" }
        if model.statusText.hasPrefix("⚠️") { return "exclamationmark.triangle.fill" }
        return "info.circle"
    }

    private static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// "1920 × 1080 · 480 KB" for the image preview caption.
    private static func imageInfo(_ data: Data, _ image: NSImage) -> String {
        let bytes = sizeText(data.count)
        if let rep = NSBitmapImageRep(data: data) {
            return "\(rep.pixelsWide) × \(rep.pixelsHigh) · \(bytes)"
        }
        return bytes
    }
}

// MARK: - Timeline row

/// One commit row: time on the left, subject and short hash on the right.
private struct CommitRow: View {
    let commit: CommitInfo
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Text(commit.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 50, alignment: .leading)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(commit.subject)
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(commit.shortHash)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10)
                          : (hovering ? Color.primary.opacity(0.04) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
    }
}

// MARK: - Changed-file row

/// One changed file: status badge, name + directory, and hover actions.
private struct ChangedFileRow: View {
    let file: ChangedFile
    let selected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onRestore: () -> Void
    @State private var hovering = false

    private var tint: Color {
        switch file.statusCharacter {
        case "A": return .green
        case "D": return .red
        case "R": return .blue
        case "T": return .purple
        default: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Text(file.statusCharacter)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tint.opacity(0.13))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(file.isDeleted ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if (hovering || selected) && !file.isDeleted {
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("用默认应用打开这个版本")
                Button(action: onRestore) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9, weight: .semibold))
                        Text("恢复")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.accentColor.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
                .help("把这个文件恢复到选中版本")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.10)
                      : (hovering ? Color.primary.opacity(0.04) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

// MARK: - Full-tree row (v4.0.4)

/// One row of the complete file tree: folders toggle expansion; files select
/// for preview and offer open/restore, just like the changed-file rows.
private struct TreeRow: View {
    let row: HistoryTreeRow
    let status: String?
    let selected: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onRestore: () -> Void
    @State private var hovering = false

    private var node: HistoryTreeNode { row.node }

    private var statusCharacter: String? {
        status.map { String($0.prefix(1)) }
    }

    private var statusTint: Color {
        switch statusCharacter {
        case "A": return .green
        case "D": return .red
        case "R": return .blue
        case "T": return .purple
        default: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.orange.opacity(0.85))
                    .frame(width: 14)
                Text(node.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(node.fileCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else if statusCharacter != nil {
                Text(statusCharacter ?? "")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusTint)
                    .frame(width: 14)
                Text(node.name)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Image(systemName: node.kind == .submodule ? "shippingbox" : "doc.text")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                Text(node.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(node.kind == .submodule ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if !node.isDirectory, hovering || selected, node.kind != .submodule {
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("用默认应用打开这个版本")
                Button(action: onRestore) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9, weight: .semibold))
                        Text("恢复")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("把这个文件恢复到选中版本")
            }
        }
        .padding(.leading, 8 + CGFloat(row.depth) * 14)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.10)
                      : (hovering ? Color.primary.opacity(0.04) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isDirectory { onToggle() } else { onSelect() }
        }
        .onHover { hovering = $0 }
    }
}
