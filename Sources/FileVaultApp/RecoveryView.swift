import AppKit
import SwiftUI
import FileVaultCore

/// Which group of recoverable files the left column lists.
enum RecoveryScope: String, CaseIterable, Identifiable {
    /// Files that are no longer in the folder.
    case deleted
    /// Files that changed recently (the natural "I broke something" entry
    /// point — auto-commit means unsaved edits are rare but still included).
    case recent
    /// Every path history knows about.
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deleted: return NSLocalizedString("已删除", comment: "recovery scope")
        case .recent: return NSLocalizedString("最近修改", comment: "recovery scope")
        case .all: return NSLocalizedString("全部", comment: "recovery scope")
        }
    }

    var symbol: String {
        switch self {
        case .deleted: return "trash"
        case .recent: return "pencil"
        case .all: return "doc.on.doc"
        }
    }
}

/// What the right pane shows for the selected version.
enum VersionDetailMode: Equatable {
    case content
    case changes
}

/// Recovery window content model (v4.1).
///
/// The window is FILE-first, not commit-first: it answers "which files can I
/// get back, and to which version?" — the two cases a user actually calls
/// 「恢复」: a deleted file, or a file that was changed and should go back.
@MainActor
final class RecoveryModel: ObservableObject {
    @Published var roots: [String] = []
    @Published var selectedRoot: String?
    @Published var scope: RecoveryScope = .deleted
    @Published var searchText = ""
    @Published var snapshot: RecoverySnapshot?
    @Published var loading = false
    @Published var errorText: String?
    @Published var selectedPath: String?
    @Published var versions: [FileVersion] = []
    @Published var selectedVersionHash: String?
    @Published var preview: FilePreviewState = .none
    @Published var workingDiff: FileDiff?
    /// "与当前对比" must distinguish "no differences" from "could not read":
    /// a nil `workingDiff` alone used to mean both (v4.2.26).
    @Published var workingDiffLoading = false
    @Published var workingDiffError: String?
    @Published var detailMode: VersionDetailMode = .content
    @Published var busy = false
    /// Path the last successful restore brought back (nil once its reveal
    /// CTA is used or the folder switches). The footer reveals THIS file
    /// while the ✓ line is up — the list selection moves on after a
    /// restore, so the plain reveal button would show a different file
    /// (closure audit v4.2.32).
    @Published var restoredPathForReveal: String?
    @Published var statusText = NSLocalizedString("选择一个文件，查看它的历史版本",
                                                  comment: "recovery status")

    /// Neutral footer text, reused when a folder switch invalidates the
    /// previous folder's ✓ / ⚠️ result (v4.2.26).
    static var idleStatusText: String {
        NSLocalizedString("选择一个文件，查看它的历史版本", comment: "recovery status")
    }

    init() {
        #if DEBUG
        // Diagnostic hook for --render-recovery screenshots: force the initial
        // scope / detail mode without simulating clicks.
        if let raw = ProcessInfo.processInfo.environment["FV_RECOVERY_SCOPE"],
           let forced = RecoveryScope(rawValue: raw) {
            scope = forced
        }
        if ProcessInfo.processInfo.environment["FV_RECOVERY_MODE"] == "diff" {
            detailMode = .changes
        }
        #endif
    }

    private var app: AppState?
    private var listenerToken: UUID?
    private var loadGeneration = 0
    private var versionsGeneration = 0
    private var previewGeneration = 0
    private var diffGeneration = 0
    private var pendingReload: Task<Void, Never>?
    /// Only the visible tab polls or reacts to state events (v4.2.26); the
    /// window keeps this in sync with `app.recordsTab`.
    private(set) var isActive = true
    /// The first scan picks a useful starting scope: deleted files if any,
    /// otherwise recently changed ones (an empty first screen reads as "broken").
    private var didAutoPickScope = false
    /// Once the user picks a scope themselves, stop auto-switching.
    private var scopeChosenByUser = false

    // MARK: - Derived state

    var selectedFile: RecoverableFile? {
        guard let path = selectedPath else { return nil }
        return snapshot?.files.first { $0.path == path }
    }

    var selectedVersion: FileVersion? {
        guard let hash = selectedVersionHash else { return nil }
        return versions.first { $0.hash == hash }
    }

    /// Newest version that still contains the file: the default restore target.
    var recommendedVersion: FileVersion? {
        versions.first { $0.exists }
    }

    var canRestore: Bool {
        !busy && selectedVersion?.exists == true
    }

    /// Trimmed search text; empty means "no filter".
    var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var visibleFiles: [RecoverableFile] {
        let all = snapshot?.files ?? []
        let query = searchQuery
        return all.filter { file in
            let inScope: Bool
            switch scope {
            case .deleted:
                inScope = file.state == .deleted
            case .recent:
                // Anything that changed inside the scan window — including a
                // deletion, so a just-deleted file is visible without hunting
                // for the right tab. Unsaved edits always count.
                inScope = file.lastChanged != nil || file.state == .modified
            case .all:
                inScope = true
            }
            guard inScope else { return false }
            guard !query.isEmpty else { return true }
            return file.path.localizedCaseInsensitiveContains(query)
        }
    }

    var deletedCount: Int { snapshot?.deletedCount ?? 0 }
    var modifiedCount: Int { snapshot?.modifiedCount ?? 0 }
    var allCount: Int { snapshot?.files.count ?? 0 }

    /// Files changed within the scanned history window (plus unsaved edits).
    var recentCount: Int {
        (snapshot?.files ?? []).filter {
            $0.lastChanged != nil || $0.state == .modified
        }.count
    }

    var hasRoots: Bool { !roots.isEmpty }

    /// Confirmation text for the restore dialog.
    var restorePrompt: String {
        guard let path = selectedPath, let version = selectedVersion, version.exists else {
            return ""
        }
        if selectedFile?.state == .deleted {
            return String(format: NSLocalizedString("将把「%@」恢复到文件夹中，内容取自 %@ 版本。",
                                                   comment: "recovery confirm"), path, version.shortHash)
        }
        return String(format: NSLocalizedString("将用 %@ 版本的内容覆盖「%@」。",
                                               comment: "recovery confirm"), version.shortHash, path)
    }

    // MARK: - Lifecycle

    func bind(_ app: AppState) {
        self.app = app
        if roots.isEmpty { reloadRoots() }
        // The folder changes while the window is open (auto-commit, external
        // edits): refresh quietly instead of making the user hit reload.
        guard listenerToken == nil, let svc = app.service else { return }
        listenerToken = svc.addStateListener { [weak self] in
            Task { @MainActor in
                // A hidden tab keeps its loaded data but does no pointless
                // rescans; the host view refreshes it when it becomes visible.
                guard let self, self.isActive else { return }
                self.scheduleReload()
            }
        }
    }

    func unbind() {
        if let token = listenerToken { app?.service?.removeStateListener(token) }
        listenerToken = nil
        pendingReload?.cancel()
    }

    /// The host view keeps this in sync with the visible records tab (v4.2.26).
    func setActive(_ active: Bool) {
        isActive = active
    }

    /// One catch-up refresh when the tab becomes visible again: hidden tabs do
    /// no scanning, so changes made meanwhile are picked up here.
    func refreshOnActivation() {
        guard snapshot != nil, !loading else { return }
        periodicRefresh()
    }

    private func scheduleReload() {
        guard isActive else { return }
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, self.isActive else { return }
            // A restore/rollback owns the folder right now: the pre-restore
            // snapshot must not refresh the list mid-operation (same guard the
            // 15 s poll already has) (v4.2.28).
            guard self.busy == false, self.loading == false else { return }
            self.reload(preserveSelection: true)
        }
    }

    /// Fallback poll: catches commits made outside the app (terminal, another
    /// tool) and roots that finished attaching after the window opened.
    func periodicRefresh() {
        guard isActive else { return }
        guard let app, let svc = app.service else { return }
        // The window can open before the service finished starting; pick up the
        // listener and roots on the next tick instead of staying empty.
        if listenerToken == nil { bind(app) }
        let latest = svc.rootsSnapshot()
        if latest != roots {
            roots = latest
            if selectedRoot == nil || !latest.contains(selectedRoot!) {
                selectedRoot = latest.first
                restoredPathForReveal = nil
                statusText = Self.idleStatusText
            }
            reload(preserveSelection: false)
            return
        }
        guard !loading, busy == false else { return }
        reload(preserveSelection: true)
    }

    func reloadRoots() {
        guard let svc = app?.service else { return }
        roots = svc.rootsSnapshot()
        if selectedRoot == nil || !roots.contains(selectedRoot!) {
            selectedRoot = roots.first
            restoredPathForReveal = nil
            statusText = Self.idleStatusText
        }
        reload(preserveSelection: false)
    }

    func rootChanged(_ newRoot: String) {
        guard newRoot != selectedRoot else { return }
        selectedRoot = newRoot
        // A folder switch invalidates the pending success CTA: its relative
        // path belongs to the PREVIOUS folder (closure audit v4.2.32).
        restoredPathForReveal = nil
        // Switching folders must not keep the previous folder's ✓ / ⚠️ result;
        // results stay only while the same folder is selected (v4.2.26).
        statusText = Self.idleStatusText
        clearSelection()
        reload(preserveSelection: false)
    }

    func setScope(_ newScope: RecoveryScope) {
        guard newScope != scope else { return }
        scopeChosenByUser = true
        scope = newScope
        selectFirstVisible()
    }

    // MARK: - Folder scan

    func reload(preserveSelection: Bool = true) {
        guard let svc = app?.service, let root = selectedRoot else {
            snapshot = nil
            clearSelection()
            statusText = roots.isEmpty
                ? NSLocalizedString("尚未添加任何文件夹——先在设置中添加文件夹", comment: "recovery status")
                : NSLocalizedString("选择一个文件夹，查看其中可以恢复的文件", comment: "recovery status")
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        let keep = preserveSelection ? selectedPath : nil
        loading = true
        errorText = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let scan = try await svc.recovery.snapshot(repoPath: root)
                guard generation == self.loadGeneration else { return }
                let previousSelection = self.selectedFile
                self.snapshot = scan
                self.loading = false
                if !self.didAutoPickScope {
                    self.didAutoPickScope = true
                    let recentExists = scan.files.contains {
                        $0.lastChanged != nil || $0.state == .modified
                    }
                    if !self.scopeChosenByUser, self.scope == .deleted,
                       scan.deletedCount == 0, recentExists {
                        self.scope = .recent
                    }
                }
                if let keep, let updated = scan.files.first(where: { $0.path == keep }) {
                    // A background refresh must not blank the preview or yank the
                    // version the user is looking at: only reload the detail when
                    // the file's STATE changed (deleted / modified / back), which
                    // is what makes the old version list misleading.
                    // v4.2.28: ALSO only when the user is still on that file —
                    // a click made while the scan was in flight (versions still
                    // empty) used to be yanked back to the stale selection.
                    if self.selectedPath == keep,
                       previousSelection?.state != updated.state || self.versions.isEmpty {
                        self.selectFile(keep, force: true)
                    }
                } else {
                    self.selectFirstVisible()
                }
            } catch {
                guard generation == self.loadGeneration else { return }
                self.loading = false
                self.snapshot = .empty
                self.errorText = error.localizedDescription
                self.clearSelection()
            }
        }
    }

    private func selectFirstVisible() {
        if let first = visibleFiles.first {
            selectFile(first.path)
        } else {
            clearSelection()
        }
    }

    private func clearSelection() {
        versionsGeneration += 1
        previewGeneration += 1
        diffGeneration += 1
        // NOTE: a pending restoredPathForReveal is NOT dropped here — the
        // post-restore reload itself lands in clearSelection (empty scope
        // list) and would erase the success CTA it just set. Only FOLDER
        // switches invalidate it (closure audit v4.2.32).
        selectedPath = nil
        versions = []
        selectedVersionHash = nil
        preview = .none
        workingDiff = nil
        workingDiffLoading = false
        workingDiffError = nil
    }

    // MARK: - One file's versions

    /// Load the version timeline of one file and preview its newest version.
    func selectFile(_ path: String?, force: Bool = false) {
        guard force || selectedPath != path else { return }
        selectedPath = path
        versionsGeneration += 1
        previewGeneration += 1
        diffGeneration += 1
        let generation = versionsGeneration
        versions = []
        selectedVersionHash = nil
        preview = .none
        workingDiff = nil
        workingDiffLoading = false
        workingDiffError = nil
        guard let path, let svc = app?.service, let root = selectedRoot else { return }
        // Operation feedback (✓ / ⚠️) stays until the next action; otherwise the
        // footer follows the selection.
        if !statusText.hasPrefix("✓") && !statusText.hasPrefix("⚠️") {
            statusText = String(format: NSLocalizedString("已选择 %@", comment: "recovery status"), path)
        }
        preview = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await svc.recovery.versions(repoPath: root, file: path)
                guard generation == self.versionsGeneration else { return }
                self.versions = list
                if let target = list.first(where: { $0.exists }) {
                    self.selectVersion(target.hash)
                } else {
                    self.preview = .failed(NSLocalizedString("这个文件没有可恢复的版本",
                                                            comment: "recovery status"))
                }
            } catch {
                guard generation == self.versionsGeneration else { return }
                self.versions = []
                self.preview = .failed(error.localizedDescription)
            }
        }
    }

    /// Select one version: load its content preview and its diff against the
    /// current folder (both are needed by the 内容 / 对比 switch).
    func selectVersion(_ hash: String, force: Bool = false) {
        guard force || selectedVersionHash != hash else { return }
        selectedVersionHash = hash
        previewGeneration += 1
        let generation = previewGeneration
        diffGeneration += 1
        let diffGenerationAtStart = diffGeneration
        workingDiff = nil
        workingDiffLoading = true
        workingDiffError = nil
        guard let path = selectedPath, let root = selectedRoot,
              let svc = app?.service,
              let version = versions.first(where: { $0.hash == hash }) else {
            workingDiffLoading = false
            preview = .none
            return
        }
        guard version.exists else {
            workingDiffLoading = false
            preview = .deleted
            return
        }
        let kind = HistoryPreviewKind.classify(path: path)
        preview = .loading
        Task { [weak self] in
            guard let self else { return }
            // A failed read must not look like "the files are identical": keep
            // the reason so the UI can offer a retry (v4.2.26).
            var loadedDiff: FileDiff?
            var diffError: String?
            do {
                loadedDiff = try await svc.recovery.workingDiff(repoPath: root, file: path, version: hash)
            } catch {
                diffError = error.localizedDescription
            }
            let size = (try? await svc.history.fileSize(repoPath: root, hash: hash, file: path)) ?? 0
            if diffGenerationAtStart == self.diffGeneration {
                self.workingDiff = loadedDiff
                self.workingDiffError = diffError
                self.workingDiffLoading = false
            }
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
                    let data = try await svc.history.fileData(repoPath: root, hash: hash, file: path)
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
                    let text = try await svc.history.fileContent(repoPath: root, hash: hash, file: path)
                    guard generation == self.previewGeneration else { return }
                    self.preview = .text(text)
                } catch {
                    guard generation == self.previewGeneration else { return }
                    self.preview = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Retry the "compare with current" diff after a read failure (v4.2.26).
    func retryWorkingDiff() {
        guard let hash = selectedVersionHash,
              let path = selectedPath, let root = selectedRoot,
              let svc = app?.service,
              let version = versions.first(where: { $0.hash == hash }),
              version.exists else { return }
        diffGeneration += 1
        let diffGenerationAtStart = diffGeneration
        workingDiff = nil
        workingDiffLoading = true
        workingDiffError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let diff = try await svc.recovery.workingDiff(repoPath: root,
                                                              file: path, version: hash)
                guard diffGenerationAtStart == self.diffGeneration else { return }
                self.workingDiff = diff
                self.workingDiffLoading = false
            } catch {
                guard diffGenerationAtStart == self.diffGeneration else { return }
                self.workingDiffError = error.localizedDescription
                self.workingDiffLoading = false
            }
        }
    }

    // MARK: - Actions

    /// Restore the selected file to the selected version.
    func restore() {
        guard !busy else { return }
        // Startup window (a login-restored records window can exist before
        // AppState built the service): answer, don't vanish (v4.2.32).
        guard let svc = app?.service else {
            statusText = NSLocalizedString("应用正在启动，请稍后重试。", comment: "recovery status")
            return
        }
        guard let root = selectedRoot,
              let path = selectedPath, let version = selectedVersion,
              version.exists else { return }
        busy = true
        statusText = String(format: NSLocalizedString("正在恢复 %@…", comment: "recovery status"), path)
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await svc.recovery.restore(repoPath: root, file: path, to: version.hash)
                switch result {
                case .unchanged:
                    self.statusText = String(format: NSLocalizedString("✓ %@ 已经是这个版本，无需恢复",
                                                                      comment: "recovery status"), path)
                case .restored(_, let recreated):
                    self.statusText = recreated
                        ? String(format: NSLocalizedString("✓ 已找回 %@（版本 %@）",
                                                          comment: "recovery status"), path, version.shortHash)
                        : String(format: NSLocalizedString("✓ 已把 %@ 还原到 %@",
                                                          comment: "recovery status"), path, version.shortHash)
                    // The restore commit bypasses the commit pipeline: notify
                    // listeners so the history tab refreshes immediately (v4.2.26).
                    svc.notifyStateChanged()
                }
                // Keep the restored path for the footer's success CTA (see
                // restoredPathForReveal; closure audit v4.2.32).
                self.restoredPathForReveal = path
                self.busy = false
                // The restored file usually leaves the current scope: move the
                // selection to the next one instead of showing a file that is
                // no longer in the list.
                self.reload(preserveSelection: false)
            } catch {
                self.busy = false
                self.statusText = String(format: NSLocalizedString("⚠️ 恢复失败：%@",
                                                                  comment: "recovery status"),
                                         error.localizedDescription)
                // The failed restore may still have mutated the repo (the
                // pre-restore backup commit happens BEFORE some refusals, and
                // a failed final commit leaves the checkout applied): notify
                // listeners and rescan instead of waiting for the next poll
                // (v4.2.28).
                svc.notifyStateChanged()
                self.reload(preserveSelection: false)
            }
        }
    }

    /// Open that historical version in the default application (read-only).
    func openVersion() {
        guard let svc = app?.service, let root = selectedRoot,
              let path = selectedPath, let version = selectedVersion, version.exists else { return }
        Task { [weak self] in
            guard let self else { return }
            self.statusText = String(format: NSLocalizedString("正在打开 %@…", comment: "recovery status"), path)
            do {
                let destination = HistoryModel.historicalTempURL(commit: version.shortHash, file: path)
                try await svc.history.exportFile(repoPath: root, hash: version.hash,
                                                 file: path, to: destination)
                NSWorkspace.shared.open(destination)
                self.statusText = String(format: NSLocalizedString("✓ 已打开 %@（%@ 版本）",
                                                                  comment: "recovery status"),
                                         path, version.shortHash)
            } catch {
                self.statusText = String(format: NSLocalizedString("⚠️ 打开失败：%@",
                                                                  comment: "recovery status"),
                                         error.localizedDescription)
            }
        }
    }

    /// Show the file in Finder (its folder when the file itself is gone).
    func revealInFinder() {
        guard let root = selectedRoot, let path = selectedPath else { return }
        let fm = FileManager.default
        let full = (root as NSString).appendingPathComponent(path)
        if fm.fileExists(atPath: full) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)])
            return
        }
        var parent = (full as NSString).deletingLastPathComponent
        while parent != "/" && parent != root && !fm.fileExists(atPath: parent) {
            parent = (parent as NSString).deletingLastPathComponent
        }
        let target = fm.fileExists(atPath: parent) ? parent : root
        NSWorkspace.shared.open(URL(fileURLWithPath: target))
    }

    /// Success CTA for the footer: reveal the file the last restore brought
    /// back (falls back to the folder when the file is gone again)
    /// (closure audit v4.2.32).
    func revealRestoredFile() {
        guard let root = selectedRoot, let path = restoredPathForReveal else { return }
        restoredPathForReveal = nil
        let fm = FileManager.default
        let full = (root as NSString).appendingPathComponent(path)
        if fm.fileExists(atPath: full) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: root))
        }
    }
}

/// File recovery window (v4.1). 恢复 means exactly two things here:
/// 找回被删除的文件, or 把被修改的文件还原到以前的版本.
struct RecoveryView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = RecoveryModel()
    /// Set by RecordsWindow: hands the current folder to the history tab when
    /// the user follows the truncated-scan pointer ("去历史时间线按提交查找").
    var handoff: RecordsHandoff? = nil
    @State private var confirmRestore = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            FVHairline(leading: 0)
            if model.roots.isEmpty {
                noRoots
            } else {
                HSplitView {
                    fileColumn
                        .frame(minWidth: 300, idealWidth: 344, maxWidth: 430)
                    detailPane
                        .frame(minWidth: 520, maxWidth: .infinity)
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 620)
        .fvCanvas()
        .onChange(of: app.roots.count) { _, _ in
            // Hidden tabs keep their loaded data; the next activation catches up.
            guard app.recordsTab == .recover else { return }
            model.reloadRoots()
        }
        .task(id: app.recordsTab) {
            // Only the visible tab polls (v4.2.26): switching tabs cancels this
            // task, so the hidden recovery page does no 15 s scans.
            guard app.recordsTab == .recover else {
                model.setActive(false)
                return
            }
            model.setActive(true)
            model.bind(app)
            model.refreshOnActivation()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, app.recordsTab == .recover else { return }
                model.periodicRefresh()
            }
        }
        .onDisappear { model.unbind() }
        .confirmationDialog("恢复确认", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("恢复此版本") { model.restore() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(model.restorePrompt + "\n\n"
                 + NSLocalizedString("恢复前会先自动保存当前改动；恢复本身也会记成一个新版本，之后仍然可以再找回来。",
                                     comment: "recovery confirm"))
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            if model.roots.isEmpty {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("文件恢复")
                    .font(.system(size: 15, weight: .semibold))
            } else {
                folderMenu
            }
            Spacer(minLength: 12)
            if !model.roots.isEmpty {
                HStack(spacing: 10) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(recoverySummary)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text("从历史版本找回被删除的文件，或把文件还原到以前的样子")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        model.reload(preserveSelection: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("重新扫描文件夹中的文件")
                    .disabled(model.loading)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var recoverySummary: String {
        // Same口径 as the 最近修改 tab: a lone "没有需要恢复的文件" next to a
        // "最近修改 20" tab read as a contradiction to anxious users (v4.2.27
        // design round).
        return String(format: NSLocalizedString("已删除 %d · 未保存 %d", comment: "recovery caption"),
                      model.deletedCount, model.modifiedCount)
    }

    private var folderMenu: some View {
        HStack(spacing: 9) {
            FVIconBadge(symbol: "arrow.uturn.backward.circle.fill", tint: .teal, size: 26)
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
                    Button("打开历史时间线") { app.open("history") }
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
                .help("切换要恢复文件的文件夹")
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

    private var folderName: String {
        model.selectedRoot.map { ($0 as NSString).lastPathComponent } ?? ""
    }

    private var noRoots: some View {
        FVEmptyState(symbol: "folder.badge.plus",
                     title: "还没有受保护的文件夹",
                     message: "在设置里添加一个文件夹，它里面每次改动都会留下版本；删掉或改坏的文件都能在这里找回。",
                     actionTitle: "打开设置",
                     action: { openWindow(id: "settings") })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File column

    private var fileColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("需要恢复的文件")
                    .font(FVTheme.sectionFont)
                Spacer()
                if model.loading {
                    ProgressView().controlSize(.small)
                }
                // Per-scope counts already sit in the tabs right below.
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            scopePicker
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            FVHairline(leading: 0)

            list

            if model.snapshot?.truncated == true {
                // Actionable pointer (v4.2.30 audit round): a plain-text mention
                // of another tab is a dead end. The button switches to the
                // timeline AND hands over the folder the user is looking at;
                // HistoryView consumes the handoff once on activation.
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("更早的记录没有扫描到")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Button("去历史时间线按提交查找") {
                        if let root = model.selectedRoot {
                            handoff?.requestedHistoryRoot = root
                        }
                        app.open("history")
                    }
                    .font(.system(size: 9.5))
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .help("切换到历史时间线标签，保留当前文件夹，按提交继续查找")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.012))
    }

    private var scopePicker: some View {
        Picker("", selection: Binding(
            get: { model.scope },
            set: { model.setScope($0) }
        )) {
            Text(scopeLabel(.deleted, count: model.deletedCount)).tag(RecoveryScope.deleted)
            Text(scopeLabel(.recent, count: model.recentCount)).tag(RecoveryScope.recent)
            Text(scopeLabel(.all, count: model.allCount)).tag(RecoveryScope.all)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .help("在已删除、最近修改和全部文件之间切换")
    }

    /// "已删除 3" — the scope name stays localised, the number is appended so
    /// no format-string key is needed for a bare counter.
    private func scopeLabel(_ scope: RecoveryScope, count: Int) -> String {
        scope.title + " " + String(count)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("搜索文件名或路径", text: $model.searchText)
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

    @ViewBuilder
    private var list: some View {
        if model.loading && model.snapshot == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在扫描文件夹…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            Spacer(minLength: 0)
        } else if let error = model.errorText {
            VStack(alignment: .leading, spacing: 4) {
                Text("无法扫描这个文件夹")
                    .font(.system(size: 11, weight: .medium))
                Text(error)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                // Same way out as the toolbar refresh instead of a dead-end
                // error (v4.2.30 audit round).
                Button("重试") {
                    model.reload(preserveSelection: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Spacer(minLength: 0)
        } else if model.visibleFiles.isEmpty {
            // An empty search result is not the same as "nothing to recover":
            // keep the scope story only when the box is actually empty (v4.2.26).
            if model.searchQuery.isEmpty {
                emptyListState
            } else {
                searchEmptyState
            }
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.visibleFiles) { file in
                        RecoveryFileRow(file: file,
                                        selected: file.path == model.selectedPath) {
                            model.selectFile(file.path)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var emptyListState: some View {
        switch model.scope {
        case .deleted:
            FVEmptyState(symbol: "checkmark.circle",
                         title: "没有被删除的文件",
                         message: "文件夹里的文件都在。万一误删了，被删的文件会出现在这里，直接就能找回。被 .gitignore 忽略的文件不会留下版本，删除后无法在这里找回。")
                .padding(.top, 12)
        case .recent:
            FVEmptyState(symbol: "pencil",
                         title: "最近没有改过的文件",
                         message: "最近改过的文件会出现在这里，选中后可以还原到更早的版本。找更早的记录请用「全部」。")
                .padding(.top, 12)
        case .all:
            FVEmptyState(symbol: "doc.on.doc",
                         title: "还没有版本记录",
                         message: "这个文件夹被保护后，每次改动都会留下一个版本，可以在这里找回或还原。被 .gitignore 忽略的文件（如 .env）不会留下版本，也不会出现在这个列表里。")
                .padding(.top, 12)
        }
    }

    /// "No search results" state: distinct from the scope empty states above so
    /// a filtered list never reads as "there is nothing to recover" (v4.2.26).
    private var searchEmptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(String(format: NSLocalizedString("没有匹配「%@」的文件", comment: "recovery search empty"),
                        model.searchQuery))
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("清除搜索") { model.searchText = "" }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 16)
    }

    // MARK: - Detail pane

    private var detailPane: some View {
        VStack(spacing: 0) {
            if let file = model.selectedFile {
                detailHeader(file)
                FVHairline(leading: 0)
                versionsSection
                FVHairline(leading: 0)
                previewSection
                FVHairline(leading: 0)
                footer
            } else {
                FVEmptyState(symbol: "sidebar.left",
                             title: "选择一个文件",
                             message: "左边列出了被删除或被修改的文件。选中一个，就能看到它每个版本的日期、内容和恢复按钮。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                FVHairline(leading: 0)
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func detailHeader(_ file: RecoverableFile) -> some View {
        HStack(alignment: .top, spacing: 11) {
            FVIconBadge(symbol: file.state == .deleted ? "trash" : (file.state == .modified ? "pencil" : "doc.text"),
                        tint: stateTint(file.state), size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(file.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    statePill(file.state)
                }
                Text(file.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(stateExplanation(file))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                model.revealInFinder()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func stateTint(_ state: RecoveryState) -> Color {
        switch state {
        case .deleted: return .red
        case .modified: return .orange
        case .available: return .teal
        }
    }

    private func stateText(_ state: RecoveryState) -> String {
        switch state {
        case .deleted: return NSLocalizedString("已删除", comment: "recovery state")
        case .modified: return NSLocalizedString("已修改", comment: "recovery state")
        case .available: return NSLocalizedString("在文件夹里", comment: "recovery state")
        }
    }

    private func statePill(_ state: RecoveryState) -> some View {
        Text(stateText(state))
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(stateTint(state))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(stateTint(state).opacity(0.13)))
    }

    private func stateExplanation(_ file: RecoverableFile) -> String {
        switch file.state {
        case .deleted:
            return NSLocalizedString("这个文件已经不在文件夹里了。选一个它还在的版本，就能把它找回来。",
                                     comment: "recovery hint")
        case .modified:
            return NSLocalizedString("当前内容和最新保存的版本不同。选一个更早的版本可以还原。",
                                     comment: "recovery hint")
        case .available:
            return NSLocalizedString("当前内容和最新保存的版本一致，也可以还原到更早的版本。",
                                     comment: "recovery hint")
        }
    }

    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("版本")
                    .font(FVTheme.sectionFont)
                Text(versionCountText)
                    .font(FVTheme.metaFont)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                Text("选一个版本，然后点右下角「恢复到此版本」")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if model.versions.isEmpty {
                Text("这个文件还没有版本记录")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.versions) { version in
                            RecoveryVersionRow(version: version,
                                               selected: version.hash == model.selectedVersionHash,
                                               isRecommended: version.hash == model.recommendedVersion?.hash) {
                                model.selectVersion(version.hash)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
                .frame(height: versionsHeight)
            }
        }
    }

    private var versionCountText: String {
        guard !model.versions.isEmpty else { return "" }
        // The scan is bounded at 100 versions: say so when the list is exactly
        // full, instead of implying everything is shown (v4.2.28).
        if model.versions.count >= 100 {
            return String(format: NSLocalizedString("%d 个版本（更早的版本未显示，可在历史时间线里翻找）",
                                                    comment: "recovery caption"),
                          model.versions.count)
        }
        return String(format: NSLocalizedString("%d 个版本", comment: "recovery caption"),
                      model.versions.count)
    }

    private var versionsHeight: CGFloat {
        min(max(CGFloat(model.versions.count) * 34 + 8, 68), 244)
    }

    private var previewSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("这个版本")
                    .font(FVTheme.sectionFont)
                Picker("", selection: $model.detailMode) {
                    Text("内容").tag(VersionDetailMode.content)
                    Text("与当前对比").tag(VersionDetailMode.changes)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 132)
                Spacer(minLength: 8)
                if let diff = model.workingDiff, model.detailMode == .changes, !diff.isBinary {
                    Text(String(format: NSLocalizedString("+%d −%d", comment: "recovery diff stat"),
                                diff.added, diff.removed))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if model.selectedVersion?.exists == true {
                    Button {
                        model.openVersion()
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
                    .help("打开这个版本的副本，不会改动当前文件")
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Group {
                if model.detailMode == .changes {
                    diffBody
                } else {
                    previewBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var diffBody: some View {
        if let version = model.selectedVersion, !version.exists {
            noteBlock(symbol: "trash", title: "这个版本删除了该文件", detail: "选择更早的版本可以看到内容。")
        } else if model.workingDiffLoading {
            loadingBlock
        } else if let diffError = model.workingDiffError {
            // A failed read is NOT "no differences": say so and let the user
            // retry instead of implying the file is already up to date (v4.2.26).
            diffErrorBlock(diffError)
        } else if let diff = model.workingDiff {
            RecoveryDiffView(diff: diff)
        } else if model.preview == .loading {
            loadingBlock
        } else {
            placeholder("选择一个版本，查看它与当前文件的差异")
        }
    }

    /// "Could not compare" block with a retry button (v4.2.26).
    private func diffErrorBlock(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text(String(format: NSLocalizedString("无法比较：%@", comment: "recovery diff"),
                        message))
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button("重试") { model.retryWorkingDiff() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private var previewBody: some View {
        switch model.preview {
        case .none:
            placeholder("选择一个版本，查看它当时的内容")
        case .loading:
            loadingBlock
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
                noteBlock(symbol: "photo", title: "无法预览这张图片", detail: "可以用默认应用打开查看")
            }
        case .binary(let size):
            noteBlock(symbol: "doc.richtext", title: "无法在应用内预览",
                      detail: LocalizedStringKey(String(format: NSLocalizedString("%@ · 可以用默认应用打开查看内容",
                                                                                  comment: "recovery preview"),
                                                         Self.sizeText(size))))
        case .tooLarge(let size):
            noteBlock(symbol: "doc.badge.ellipsis", title: "文件较大，未在此预览",
                      detail: LocalizedStringKey(String(format: NSLocalizedString("%@ · 可以用默认应用打开查看",
                                                                                  comment: "recovery preview"),
                                                         Self.sizeText(size))))
        case .deleted:
            noteBlock(symbol: "trash", title: "这个版本里没有这个文件",
                      detail: "它是在这个版本里被删除的。选择更早的版本可以找回内容。")
        case .failed(let message):
            noteBlock(symbol: "exclamationmark.triangle", title: "读取失败",
                      detail: LocalizedStringKey(message))
        case .submodule:
            noteBlock(symbol: "shippingbox", title: "这是子模块", detail: "子模块只记录提交号，不能在这里恢复。")
        case .diff(let fileDiff):
            RecoveryDiffView(diff: fileDiff)
        case .blame:
            noteBlock(symbol: "person.text.rectangle", title: "逐行归属",
                      detail: "逐行归属视图在「历史时间线」里查看。")
        case .lfsPointer:
            noteBlock(symbol: "externaldrive.badge.icloud", title: "这个文件由 Git LFS 管理",
                      detail: "实际内容存在远程存储，这里只记录了它的位置；要取回真实内容，可在终端运行 git lfs pull。")
        }
    }

    private var loadingBlock: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在读取…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noteBlock(symbol: String, title: LocalizedStringKey,
                           detail: LocalizedStringKey) -> some View {
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

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            // The product's core value moment deserves more than a dim
            // 11pt line: success gets the accent color and weight (v4.2.32).
            let restored = model.statusText.hasPrefix("✓")
            Image(systemName: statusSymbol)
                .font(.system(size: 10))
                .foregroundStyle(restored ? Color.green : Color.secondary)
                .padding(.top, 1)
            // Failure text carries the remedy ("请先把它改名或移走…"); it must
            // wrap instead of being cut to one line (v4.2.26).
            Text(model.statusText)
                .font(.system(size: 11, weight: restored ? .medium : .regular))
                .foregroundStyle(restored ? Color.green : Color.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .help(model.statusText)
            Spacer(minLength: 8)
            if model.restoredPathForReveal != nil {
                // Right after a restore the list selection moves on; the
                // plain reveal button would show a DIFFERENT file. Point the
                // user at the one that just came back (closure audit v4.2.32).
                Button {
                    model.revealRestoredFile()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9))
                        Text("查看刚恢复的文件")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(.green)
                .help("在 Finder 中查看刚恢复的文件")
            } else {
                Button {
                    model.revealInFinder()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                        Text("在 Finder 中显示")
                            .font(.system(size: 11))
                    }
                }
                .controlSize(.small)
                .disabled(model.selectedPath == nil)
                .help("在 Finder 中显示这个文件")
            }
            Button {
                confirmRestore = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9))
                    Text("恢复到此版本…")
                        .font(.system(size: 11))
                }
            }
            .controlSize(.small)
            .disabled(!model.canRestore)
            .help("把这个文件恢复到选中的版本")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var statusSymbol: String {
        if model.statusText.hasPrefix("✓") { return "checkmark.circle.fill" }
        if model.statusText.hasPrefix("⚠️") { return "exclamationmark.triangle.fill" }
        return "info.circle"
    }

    private static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func imageInfo(_ data: Data, _ image: NSImage) -> String {
        let bytes = sizeText(data.count)
        if let rep = NSBitmapImageRep(data: data) {
            return "\(rep.pixelsWide) × \(rep.pixelsHigh) · \(bytes)"
        }
        return bytes
    }
}

// MARK: - File row

/// One recoverable file: state, name, folder and what happened to it.
private struct RecoveryFileRow: View {
    let file: RecoverableFile
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var tint: Color {
        switch file.state {
        case .deleted: return .red
        case .modified: return .orange
        case .available: return .teal
        }
    }

    private var symbol: String {
        switch file.state {
        case .deleted: return "trash"
        case .modified: return "pencil"
        case .available: return "doc.text"
        }
    }

    private var detail: String {
        switch file.state {
        case .deleted:
            // Only a COMMITTED deletion has a meaningful deletion time; an
            // uncommitted one just happened and is not in history yet.
            if let date = file.lastChanged, file.deletedIn != nil {
                return String(format: NSLocalizedString("删除于 %@", comment: "recovery row"),
                              FVTime.relative(date))
            }
            return NSLocalizedString("已从文件夹删除", comment: "recovery row")
        case .modified:
            return NSLocalizedString("有未保存的改动", comment: "recovery row")
        case .available:
            if let date = file.lastChanged {
                return String(format: NSLocalizedString("最后修改于 %@", comment: "recovery row"),
                              FVTime.relative(date))
            }
            return NSLocalizedString("内容未变", comment: "recovery row")
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.system(size: 11.5, weight: file.state == .available ? .regular : .medium))
                        .foregroundStyle(file.state == .available ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        if !file.directory.isEmpty {
                            Text(file.directory)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(detail)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if file.state == .deleted {
                    Text("可找回")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(tint.opacity(0.12)))
                } else if file.state == .modified {
                    Text("可还原")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(tint.opacity(0.12)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.10)
                          : (hovering ? Color.primary.opacity(0.04) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Version row

/// One version of the selected file. The deletion commit is shown but cannot
/// be restored; the newest restorable version carries a 「可恢复」 hint.
private struct RecoveryVersionRow: View {
    let version: FileVersion
    let selected: Bool
    let isRecommended: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    private var tint: Color {
        switch version.statusCharacter {
        case "A": return .green
        case "M": return .orange
        case "D": return .red
        case "R": return .blue
        default: return .secondary
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Text(version.statusCharacter)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(tint.opacity(0.13)))
                Text(FVTime.absolute(version.date))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                    .lineLimit(1)
                Text(version.subject)
                    .font(.system(size: 11))
                    .foregroundStyle(version.exists ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if isRecommended {
                    Text("最新内容")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
                if version.isDeletion {
                    Text("已删除")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.red.opacity(0.12)))
                }
                Text(version.shortHash)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.10)
                          : (hovering ? Color.primary.opacity(0.04) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Diff

/// Read-only unified diff with the usual +/- colouring.
private struct RecoveryDiffView: View {
    let diff: FileDiff

    private var lines: [String] {
        // Hide git's file header ("diff --git", "index", "---", "+++"): a
        // non-technical reader only needs the hunks and their +/- lines.
        // v4.2.28: strip header lines ONLY before the first @@ hunk. The old
        // whole-text filter also swallowed CONTENT lines — a deleted line
        // whose text starts with "-- " renders as "--- …" and vanished from
        // the comparison.
        let headers = ["diff --git ", "index ", "--- ", "+++ ",
                       "deleted file mode ", "new file mode ", "old mode ", "new mode ",
                       "similarity index ", "rename from ", "rename to ",
                       "copy from ", "copy to "]
        var pastFirstHunk = false
        var all: [String] = []
        for line in diff.text.components(separatedBy: "\n") {
            if line.hasPrefix("@@") { pastFirstHunk = true }
            if !pastFirstHunk, headers.contains(where: { line.hasPrefix($0) }) { continue }
            all.append(line)
        }
        return all.count > 3_000 ? Array(all.prefix(3_000)) : all
    }

    var body: some View {
        if diff.isBinary {
            VStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("二进制文件无法按文本对比")
                    .font(.system(size: 12, weight: .medium))
                Text("可以切换到「内容」预览，或用默认应用打开这个版本")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
        } else if diff.text.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "equal.circle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("当前文件已经是这个版本")
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
        } else {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(color(for: line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
    }

    private func color(for line: String) -> Color {
        // Header lines never reach the renderer (stripped before the first
        // hunk), so a "+"/"-" prefix here is always CONTENT: a deleted line
        // whose text starts with "-- " must be red, not gray (v4.2.28).
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        if line.hasPrefix("@@") { return .accentColor }
        return .primary
    }
}
