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
    public func configureRemote(repoPath: String, url: String, autoPush: Bool) async throws {
        try await repoManager.setRemote(path: repoPath, url: url)
        await repoManager.setAutoPush(path: repoPath, enabled: autoPush)
        if autoPush {
            setState(repoPath, .pendingPush)
            await enqueuePush(repoPath: repoPath)
        } else {
            await refreshStatus(repoPath: repoPath)
        }
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
                try await pushOnce(repoPath: repoPath)
                setState(repoPath, .synced)
                attempt = 0
                if states[repoPath]?.needsPushAgain == true {
                    states[repoPath]?.needsPushAgain = false
                    continue
                }
                return
            } catch {
                attempt += 1
                let reason = (error as? GitCommandError)?.errorDescription ?? String(describing: error)
                let message = AuthClassifier.isAuthRelated(reason)
                    ? AuthClassifier.guidance() + "（" + reason + "）"
                    : reason
                onPushFailure(repoPath, message)
                setState(repoPath, .failed)
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
        let r = try await repoManager.runner.run(["push", "-u", "origin", "HEAD"], cwd: repoPath)
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
            try await pushOnce(repoPath: repoPath)
            setState(repoPath, .synced)
            return true
        } catch {
            onPushFailure(repoPath, (error as? GitCommandError)?.errorDescription ?? String(describing: error))
            setState(repoPath, .failed)
            return false
        }
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
