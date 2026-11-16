import Foundation

/// Per-repo sync state machine: noRemote -> synced -> pendingPush -> pushing -> synced/failed
/// (FR-06/07, FR-16 retry with backoff; local commits always succeed first).
public actor SyncManager {
    public let repoManager: RepoManager
    public let backoffSchedule: [TimeInterval]
    public let maxAttempts: Int
    /// Called on each failed push attempt with (repoPath, reason).
    public nonisolated let onPushFailure = EventCallbackBox()
    /// Called on every sync-status transition (repoPath, newStatus rawValue).
    public nonisolated let onStatusChange = EventCallbackBox()

    private var states: [String: RepoSyncState] = [:]

    public struct RepoSyncState {
        public var status: SyncStatus
        public var task: Task<Void, Never>?
        public var attempt: Int
        public var needsPushAgain: Bool
    }

    public init(repoManager: RepoManager, backoffSchedule: [TimeInterval] = [1, 2, 4, 8, 16, 32, 64, 128, 256, 300], maxAttempts: Int = 6) {
        self.repoManager = repoManager
        self.backoffSchedule = backoffSchedule
        self.maxAttempts = maxAttempts
    }

    // MARK: - Status

    /// Current sync status for UI (defaults to noRemote for unknown repos).
    public func status(for repoPath: String) -> SyncStatus {
        states[repoPath]?.status ?? .noRemote
    }

    /// Refresh status based on remote presence and local/remote divergence.
    public func refreshStatus(repoPath: String) async {
        let url = await repoManager.remoteURL(path: repoPath)
        guard url != nil else {
            setState(repoPath, .noRemote)
            return
        }
        let pending = await hasUnpushedCommits(repoPath: repoPath)
        setState(repoPath, pending ? .pendingPush : .synced)
    }

    // MARK: - Remote configuration (FR-06)

    /// Configure remote + auto-push for a repo.
    ///
    /// v4.2: binding a remote is one automatic action. A remote that already
    /// carries work (a new bind or a replaced remote) is merged into the folder
    /// losslessly — remote-only files come in, local files stay, same-name
    /// differences keep both copies — and the result is pushed afterwards.
    /// There is no "decide what to do" step any more.
    @discardableResult
    public func configureRemote(repoPath: String, url: String,
                                autoPush: Bool) async throws -> RepoManager.RemoteChange {
        // A push loop for the OLD remote must not continue into the new URL.
        states[repoPath]?.task?.cancel()
        states[repoPath]?.task = nil
        let change = try await repoManager.setRemote(path: repoPath, url: url)
        await repoManager.setAutoPush(path: repoPath, enabled: autoPush)
        let stillPending = await repoManager.remoteSwitchPending(path: repoPath)
        if change.needsDecision || stillPending {
            // Best effort: the push below reports the real git error when the
            // merge cannot finish, and mergeSync never discards local files.
            _ = try? await repoManager.mergeSync(path: repoPath)
            await repoManager.clearRemoteSwitchPending(path: repoPath)
        }
        if autoPush {
            setState(repoPath, .pendingPush)
            await enqueuePush(repoPath: repoPath)
        } else {
            await refreshStatus(repoPath: repoPath)
        }
        return change
    }

    /// Remove remote config.
    public func clearRemote(repoPath: String) async throws {
        try await repoManager.clearRemote(path: repoPath)
        setState(repoPath, .noRemote)
    }

    /// Enable/disable auto-push at runtime.
    public func setAutoPush(repoPath: String, enabled: Bool) async {
        await repoManager.setAutoPush(path: repoPath, enabled: enabled)
        if enabled {
            await enqueuePush(repoPath: repoPath)
        } else {
            await refreshStatus(repoPath: repoPath)
        }
    }

    public func autoPushEnabled(repoPath: String) async -> Bool {
        await repoManager.autoPushEnabled(path: repoPath)
    }

    // MARK: - Push queue (FR-07/16)

    /// Called after each successful commit (and manual flush).
    public func enqueuePush(repoPath: String) async {
        let hasRemote = await repoManager.remoteURL(path: repoPath) != nil
        guard hasRemote else {
            setState(repoPath, .noRemote)
            return
        }
        // A replaced remote left undecided (an older version, or a crash between
        // binding and merging) is finished here automatically (v4.2): merge the
        // remote files in losslessly, then let the push loop continue.
        if await repoManager.remoteSwitchPending(path: repoPath) {
            _ = try? await repoManager.mergeSync(path: repoPath)
            await repoManager.clearRemoteSwitchPending(path: repoPath)
        }
        let enabled = await repoManager.autoPushEnabled(path: repoPath)
        guard enabled else {
            setState(repoPath, .pendingPush)
            return
        }
        if var st = states[repoPath] {
            if st.task != nil {
                st.needsPushAgain = true
                states[repoPath] = st
                return
            }
        }
        let task = Task.detached { await self.pushLoop(repoPath: repoPath) }
        states[repoPath]?.task = task
    }

    /// Serial per-repo push loop with exponential backoff retries.
    private func pushLoop(repoPath: String) async {
        if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
            print("[FV_DEBUG] pushLoop enter \(repoPath)")
        }
        defer { states[repoPath]?.task = nil }
        var attempt = 0
        while true {
            // A cancelled loop (pushNow superseded it) must not race the
            // manual push with a concurrent `git push` of its own.
            if Task.isCancelled { return }
            let url = await repoManager.remoteURL(path: repoPath)
            guard url != nil else {
                setState(repoPath, .noRemote)
                return
            }
            setState(repoPath, .pushing)
            do {
                // Another machine may have pushed first: reconcile (fast-forward
                // / auto-rebase) and retry once instead of failing forever
                // (v4.1.5).
                try await pushWithReconcile(repoPath: repoPath)
                setState(repoPath, .synced)
                attempt = 0
                if states[repoPath]?.needsPushAgain == true {
                    states[repoPath]?.needsPushAgain = false
                    continue
                }
                return
            } catch {
                attempt += 1
                // Branch protection / hooks / size limits cannot be fixed by
                // retrying: report once with guidance and stop (v4.1.7).
                if let rejection = Self.deterministicPushRejection(error) {
                    onPushFailure(repoPath, rejection)
                    setState(repoPath, .failed)
                    return
                }
                onPushFailure(repoPath, Self.pushFailureMessage(error))
                setState(repoPath, .failed)
                // A merge conflict / unrelated history needs a human decision;
                // retrying on a timer cannot fix it.
                if let pull = error as? PullError, Self.isDeterministic(pull) {
                    return
                }
                if attempt >= maxAttempts {
                    return
                }
                let delay = backoffSchedule[min(attempt - 1, backoffSchedule.count - 1)]
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
                continue
            }
        }
    }

    /// Push once; throws on failure.
    func pushOnce(repoPath: String) async throws {
        let r = try await repoManager.runner.run(["push", "-u", "origin", "HEAD"], cwd: repoPath,
                                                 timeout: RepoManager.networkTimeout)
        guard r.succeeded else {
            throw GitCommandError(command: "push", exitCode: r.exitCode, stderr: r.stderr)
        }
    }

    /// Whether local branch is ahead of upstream (unpushed commits exist).
    private func hasUnpushedCommits(repoPath: String) async -> Bool {
        guard let r = try? await repoManager.runner.run(["rev-list", "--count", "@{upstream}..HEAD"], cwd: repoPath) else { return true }
        guard r.succeeded else { return true }
        return (Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1) > 0
    }

    /// Manual immediate push (cancels pending retry loop; returns success).
    @discardableResult
    public func pushNow(repoPath: String) async -> Bool {
        states[repoPath]?.task?.cancel()
        states[repoPath]?.task = nil
        setState(repoPath, .pushing)
        do {
            try await pushWithReconcile(repoPath: repoPath)
            await repoManager.clearRemoteSwitchPending(path: repoPath)
            setState(repoPath, .synced)
            return true
        } catch {
            let message = Self.deterministicPushRejection(error) ?? Self.pushFailureMessage(error)
            onPushFailure(repoPath, message)
            setState(repoPath, .failed)
            return false
        }
    }

    /// Push once; when the rejection means "the remote moved on", reconcile with
    /// the same rules as pull (fast-forward / auto-rebase; conflicts abort and
    /// restore the repo) and retry once. Never force-pushes.
    func pushWithReconcile(repoPath: String) async throws {
        do {
            try await pushOnce(repoPath: repoPath)
        } catch {
            guard Self.isRejectedPush(error) else { throw error }
            // Never start a rebase while another operation owns the repository.
            guard !(await repoManager.operationInProgress(path: repoPath)) else { throw error }
            _ = try await repoManager.pull(path: repoPath)
            try await pushOnce(repoPath: repoPath)
        }
    }

    /// Whether a failed push was rejected because the remote has commits the
    /// local branch does not have (reconciling can fix this).
    static func isRejectedPush(_ error: Error) -> Bool {
        guard let e = error as? GitCommandError else { return false }
        let text = e.stderr.lowercased()
        return text.contains("non-fast-forward")
            || text.contains("fetch first")
            || text.contains("failed to push some refs")
            || text.contains("updates were rejected")
            || text.contains("tip of your current branch is behind")
    }

    /// Failures only a human can resolve (conflict / unrelated histories / …):
    /// the retry loop stops instead of hammering the remote.
    static func isDeterministic(_ error: PullError) -> Bool {
        switch error {
        case .mergeConflict, .unrelatedHistories, .remoteBranchMissing, .ambiguousRemote,
             .notARepository, .detachedHead, .unsafeRepository:
            return true
        case .noRemote, .busy, .repositoryLocked, .authenticationFailed, .networkFailed,
             .remoteUnavailable, .localChanges, .failed:
            return false
        }
    }

    /// Remote-side refusals that retrying cannot fix: branch protection,
    /// repository rules, hooks and file-size limits (v4.1.7).
    static func deterministicPushRejection(_ error: Error) -> String? {
        guard let e = error as? GitCommandError else { return nil }
        let text = e.stderr.lowercased()
        if text.contains("protected branch") || text.contains("gh006") || text.contains("gh013")
            || text.contains("branch protection") || text.contains("pre-receive hook declined")
            || text.contains("remote rejected") || text.contains("refusing to allow") {
            return NSLocalizedString("远程仓库拒绝了这次推送（分支保护或仓库规则）。请在托管平台调整分支保护/权限后再试。",
                                     comment: "push rejected")
        }
        if text.contains("file is too large") || text.contains("exceeds github's file size limit")
            || (text.contains("push was rejected") && (text.contains("mb") || text.contains("limit"))) {
            var message = NSLocalizedString("远程仓库因为文件过大拒绝了这次推送。请检查大文件排除规则，或把大文件移出受保护文件夹后再试。",
                                            comment: "push rejected")
            let files = Self.oversizedFiles(in: e.stderr)
            if !files.isEmpty {
                let shown = files.prefix(3).joined(separator: NSLocalizedString("、", comment: "list joiner"))
                let more = files.count > 3
                    ? String(format: NSLocalizedString(" 等 %d 个文件", comment: "list more"), files.count)
                    : ""
                message += String(format: NSLocalizedString("（超限文件：%@%@）", comment: "push rejected files"),
                                  shown, more)
            }
            return message
        }
        return nil
    }

    /// File names mentioned by a "file is too large" push rejection.
    static func oversizedFiles(in stderr: String) -> [String] {
        var names: [String] = []
        for raw in stderr.split(separator: "\n") {
            let line = String(raw)
            guard let fileRange = line.range(of: "File "),
                  let isRange = line.range(of: " is ", range: fileRange.upperBound..<line.endIndex) else { continue }
            let name = String(line[fileRange.upperBound..<isRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Notify text for a failed push (reuses pull wording where available).
    static func pushFailureMessage(_ error: Error) -> String {
        if let e = error as? GitCommandError, e.exitCode == -9 {
            return NSLocalizedString("推送超时（网络较慢或仓库较大），稍后会自动重试", comment: "push timeout")
        }
        if let pull = error as? PullError {
            let description = pull.errorDescription ?? String(describing: pull)
            if let suggestion = pull.recoverySuggestion, !suggestion.isEmpty {
                return description + "（" + suggestion + "）"
            }
            return description
        }
        let reason = (error as? GitCommandError)?.errorDescription ?? String(describing: error)
        if AuthClassifier.isAuthRelated(reason) {
            return AuthClassifier.guidance() + "（" + reason + "）"
        }
        return reason
    }

    private func setState(_ path: String, _ s: SyncStatus) {
        if var st = states[path] {
            st.status = s
            states[path] = st
        } else {
            states[path] = RepoSyncState(status: s, task: nil, attempt: 0, needsPushAgain: false)
        }
        onStatusChange(path, s.rawValue)
    }
}
