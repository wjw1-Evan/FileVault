import Foundation

/// Orchestrates the debounced auto-commit of ONE managed root repo (FR-04/05/12/13).
///
/// v4.0: the debounce key is the root path itself; every change under the root
/// (root-level files, nested folders, anything not ignored) is committed together.
public final class CommitEngine: @unchecked Sendable {
    public let repoManager: RepoManager
    public let debouncer: Debouncer
    public let pause: PauseController
    /// Called after a successful auto-commit with (repoPath, hash, message).
    public var onCommit: (@Sendable (String, String, String) -> Void)?
    /// Called when the auto-commit pipeline fails with (repoPath, errorDescription).
    public var onCommitFailure: (@Sendable (String, String) -> Void)?
    /// Called once when files were auto-excluded for exceeding the remote's
    /// single-file limit (repoPath, excluded relative paths) (v4.2.6).
    public var onLargeFilesExcluded: (@Sendable (String, [String]) -> Void)?
    /// Effective large-file ceiling for a repo (FR-12, v3.1.3).
    ///
    /// There is no local threshold anymore: the value comes from the remote
    /// (github.com → 100 MiB, other remotes → no known limit, i.e. `0`). The
    /// remote is the only place that can actually refuse a push, so its value
    /// is authoritative and the pipeline never invents one.
    public func effectiveThreshold(for repoPath: String) async -> UInt64 {
        let remote = await repoManager.remoteURL(path: repoPath)
        return GitHubLimits.effectiveThreshold(remoteURL: remote)
    }

    private let inFlight = NSLock()
    private var busyKeys: Set<String> = []
    private var recheckKeys: Set<String> = []

    /// Delay before retrying a failed auto-commit (seconds). A transient cause
    /// (locked index, disk full, permissions) often clears without any new file
    /// event, so the pipeline retries a few times on its own (v4.2.2).
    var retryDelay: TimeInterval = 60
    /// Consecutive automatic-commit failures per repo (reset on success or on
    /// fresh file activity), so notifications stay quiet while retrying.
    private var failureCounts: [String: Int] = [:]
    private let failureLock = NSLock()

    private let pendingLock = NSLock()
    /// Changed paths (relative to the root) reported by the watcher since the
    /// last commit run — used to materialise brand-new empty folders.
    private var pendingPaths: [String: Set<String>] = [:]
    /// When watching of a root started: only folders created after this are new.
    private var watchStartedAt: [String: Date] = [:]

    public init(repoManager: RepoManager, debouncer: Debouncer, pause: PauseController) {
        self.repoManager = repoManager
        self.debouncer = debouncer
        self.pause = pause
    }

    /// Called by WatcherEngine via the service: debounce-touch the root repo (FR-04).
    public func handleActivity(root: String) {
        handleActivity(root: root, paths: [])
    }

    /// Same, with the paths that actually changed (relative to the root).
    public func handleActivity(root: String, paths: [String]) {
        if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
            print("[FV_DEBUG] t=\(Int(Date().timeIntervalSince1970) % 1000) activity root=\(root) paths=\(paths.count)")
        }
        if !paths.isEmpty {
            pendingPathsUnion(root, paths)
            // Fresh edits start a new failure streak (so a persistent error is
            // reported once per burst instead of on every retry).
            clearFailureCount(root)
        }
        debouncer.touch(root)
    }

    /// Mark the moment a root started being watched (new-folder detection).
    public func registerRoot(_ root: String) {
        pendingLock.lock()
        watchStartedAt[root] = Date()
        pendingLock.unlock()
    }

    /// Forget a root that is no longer watched.
    public func unregisterRoot(_ root: String) {
        pendingLock.lock()
        watchStartedAt.removeValue(forKey: root)
        pendingPaths.removeValue(forKey: root)
        pendingLock.unlock()
        // The scheduled auto-commit retry gates on failureCounts, so a
        // leftover count made FileVault commit a folder the user had just
        // removed or relocated (both paths pass through here) up to a minute
        // after the removal (v4.2.31).
        clearFailureCount(root)
    }

    // MARK: - Synchronous lock sections (v4.2.31)
    //
    // The critical sections below never await, but calling NSLock directly
    // from an async context is an error under the Swift 6 language mode;
    // plain synchronous helpers keep the async callers warning-free. Same
    // shape as AuthMonitor/RepoHealth in this round.

    private func clearFailureCount(_ root: String) {
        failureLock.lock(); failureCounts.removeValue(forKey: root); failureLock.unlock()
    }

    private func currentFailureCount(_ root: String) -> Int {
        failureLock.lock(); defer { failureLock.unlock() }
        return failureCounts[root] ?? 0
    }

    private func pendingPathsUnion(_ root: String, _ paths: [String]) {
        pendingLock.lock()
        pendingPaths[root, default: []].formUnion(paths)
        pendingLock.unlock()
    }

    /// Enter the per-repo busy gate. Returns false (with a re-check mark
    /// recorded) when a pipeline already owns the repo.
    private func beginBusy(_ key: String) -> Bool {
        inFlight.lock()
        if busyKeys.contains(key) {
            recheckKeys.insert(key)
            inFlight.unlock()
            return false
        }
        busyKeys.insert(key)
        inFlight.unlock()
        return true
    }

    /// Leave the busy gate; returns whether a re-check was requested while the
    /// pipeline ran (the caller re-arms the debouncer then).
    private func endBusy(_ key: String) -> Bool {
        inFlight.lock()
        busyKeys.remove(key)
        let again = recheckKeys.remove(key) != nil
        inFlight.unlock()
        return again
    }

    /// Take (and clear) the changed paths reported for a root.
    private func takePendingPaths(_ root: String) -> [String] {
        pendingLock.lock(); defer { pendingLock.unlock() }
        let paths = pendingPaths.removeValue(forKey: root) ?? []
        return Array(paths)
    }

    private func watchStart(for root: String) -> Date {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return watchStartedAt[root] ?? .distantPast
    }

    /// Debounce fired: run the commit pipeline for the repo at key (FR-04).
    public func commit(forKey key: String) {
        guard beginBusy(key) else { return }
        Task.detached { [weak self] in
            guard let self else { return }
            await self.runCommitPipeline(repoPath: key)
            if self.endBusy(key) {
                self.commit(forKey: key)
            }
        }
    }

    /// Run the commit pipeline through the per-repo busy gate.
    ///
    /// Callers that are not the debouncer (safety sweep, pause-resume, manual
    /// flush) used to call `runCommitPipeline` directly and could therefore run a
    /// second add/commit concurrently with the debounced one: index.lock errors
    /// and fake "commit failed" notifications (v4.2.26).
    public func commitSerialized(repoPath: String) async {
        guard beginBusy(repoPath) else { return }
        await runCommitPipeline(repoPath: repoPath)
        if endBusy(repoPath) { commit(forKey: repoPath) }
    }

    /// The commit pipeline: pause check -> status -> large file exclude -> add -> commit.
    public func runCommitPipeline(repoPath: String) async {
        if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
            print("[FV_DEBUG] t=\(Int(Date().timeIntervalSince1970) % 1000) pipeline enter \(repoPath)")
        }
        // v4.0: the repo IS the root, so the pause scope is the repo path itself.
        // While paused the pending paths stay queued for the resume commit.
        guard !pause.isPaused(root: repoPath) else { return }
        // A pull's auto-rebase owns the repository for a moment (v4.1.2):
        // committing mid-rebase would stage conflict markers or move a detached
        // HEAD. The pull itself commits pending edits first, so nothing is lost.
        guard !(await repoManager.operationInProgress(path: repoPath)) else { return }
        // A restore/rollback/pull owns the working tree for a moment: never
        // interleave add/commit with it (v4.2.26). The sweep/debounce will try
        // again shortly.
        guard repoManager.tryAcquireLocalOp(repoPath) else { return }
        defer { repoManager.releaseLocalOp(repoPath) }
        // Git cannot track empty directories: a folder created while we watch
        // would otherwise never appear in history. Give brand-new empty folders
        // a hidden marker file so their creation becomes a real version.
        let pending = takePendingPaths(repoPath)
        let markerFolders = pending.isEmpty
            ? []
            : await repoManager.materializeEmptyDirectoryMarkers(path: repoPath,
                                                                 candidates: pending,
                                                                 since: watchStart(for: repoPath))
        // "status failed" is NOT "no changes": a broken/locked repo would look
        // clean forever and never be reported (v4.2.26).
        let entries: [StatusEntry]
        do {
            entries = try await repoManager.status(path: repoPath)
        } catch {
            handlePipelineFailure(repoPath: repoPath, error: error)
            return
        }
        if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
            print("[FV_DEBUG] status entries=\(entries.count)")
        }
        guard !entries.isEmpty else { return }
        // Reuse the single status pass for large-file checks and the commit
        // (was 3 git-status invocations per commit, now 1). Excluded files are
        // filtered out so the commit message reflects what is actually committed.
        let threshold = await effectiveThreshold(for: repoPath)
        let excluded = await repoManager.excludeLargeFiles(path: repoPath, threshold: threshold, entries: entries)
        if !excluded.isEmpty {
            // Never let a file quietly fall out of version control: tell the user
            // it was excluded because the remote refuses files that large.
            onLargeFilesExcluded?(repoPath, excluded)
        }
        let excludedSet = Set(excluded)
        let committable = entries.filter { !excludedSet.contains($0.path) }
        do {
            guard !committable.isEmpty else { return }
            // Marker files are an implementation detail: hide them from the
            // commit subject. A folder-only commit gets a readable message.
            let markerPaths = Set(markerFolders.map { $0 + "/" + RepoManager.emptyFolderMarker })
            let visibleEntries = committable.filter { !markerPaths.contains($0.path) }
            let folderOnly = visibleEntries.isEmpty && !markerFolders.isEmpty
            let message = folderOnly
                ? "auto: 新建文件夹 " + markerFolders.map { RepoManager.subjectLabel($0) }.joined(separator: "、")
                : nil
            let subjectEntries = visibleEntries.isEmpty ? committable : visibleEntries
            let hash = try await repoManager.commitAll(path: repoPath, message: message,
                                                       knownEntries: subjectEntries)
            clearFailureCount(repoPath)
            if !hash.isEmpty {
                onCommit?(repoPath, hash, Self.describe(entries: entries, excluded: excluded))
            }
        } catch {
            handlePipelineFailure(repoPath: repoPath, error: error)
        }
    }

    /// Report/retry a failed pipeline run.
    ///
    /// Notification policy: the first failure is reported, the retries stay
    /// quiet, and the "gave up" note is emitted exactly ONCE (count 4). The old
    /// branch notified on every run past 3, and the 120 s sweep produced a
    /// notification every two minutes forever (v4.2.26).
    private func handlePipelineFailure(repoPath: String, error: Error) {
        if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
            print("[FV_DEBUG] commit error: \(error)")
        }
        failureLock.lock()
        let count = (failureCounts[repoPath] ?? 0) + 1
        failureCounts[repoPath] = count
        failureLock.unlock()
        let reason = Self.failureDescription(error)
        if count == 1 {
            onCommitFailure?(repoPath, reason)
        } else if count == 4 {
            onCommitFailure?(repoPath, reason + NSLocalizedString("（已自动重试 3 次仍未成功，下次文件改动时会再试）",
                                                                  comment: "commit failure retries exhausted"))
        }
        // Stop the automatic retry chain once we have reported giving up; the
        // safety sweep / next file event still retries.
        guard count < 4 else { return }
        scheduleRetry(repoPath: repoPath)
    }

    /// Retry a failed auto-commit after a delay: the cause (locked index, disk
    /// space, permissions) often clears without any new file event (v4.2.2).
    private func scheduleRetry(repoPath: String) {
        let delay = retryDelay
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.05) * 1_000_000_000))
            guard let self else { return }
            guard self.currentFailureCount(repoPath) > 0 else { return }
            self.commit(forKey: repoPath)
        }
    }

    /// Readable one-liner for a failed auto-commit, naming the common causes so
    /// the notification is actionable (v4.2.2).
    static func failureDescription(_ error: Error) -> String {
        let detail = ((error as? GitCommandError)?.stderr ?? "").lowercased()
        if detail.contains("no space left") {
            return NSLocalizedString("磁盘空间不足，无法写入这次自动版本", comment: "commit failure")
        }
        if detail.contains("permission denied") || detail.contains("operation not permitted") {
            return NSLocalizedString("没有写入权限，无法提交这次改动（检查文件夹权限）", comment: "commit failure")
        }
        if detail.contains("index.lock") || detail.contains("another git process") {
            return NSLocalizedString("仓库正被另一个 Git 操作占用（锁文件），稍后会自动重试", comment: "commit failure")
        }
        if detail.contains("dubious ownership") || detail.contains("safe.directory") {
            return NSLocalizedString("Git 拒绝访问这个文件夹（所有者与本机账户不一致）", comment: "commit failure")
        }
        return (error as? GitCommandError)?.errorDescription ?? String(describing: error)
    }

    /// Full check: commit the root repo if it is dirty (used on resume / manual flush).
    public func commitAllDirty(root: String) async {
        await commitSerialized(repoPath: root)
    }

    /// Human-readable one-line description for logging/UI.
    static func describe(entries: [StatusEntry], excluded: [String]) -> String {
        var text = "\(entries.count) changes"
        if !excluded.isEmpty {
            text += ", \(excluded.count) large file(s) excluded"
        }
        return text
    }
}
