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
    /// Monotonic id of the push loop currently owning a repo. A loop that was
    /// superseded (cancelled by a manual push) must not clear the state of the
    /// loop that replaced it (v4.2.25).
    private var pushGenerations: [String: Int] = [:]
    /// Repos with a manual push in flight; a commit arriving meanwhile is queued
    /// through `needsPushAgain` instead of starting a second `git push`.
    private var manualPushes: Set<String> = []
    /// Repos whose current push-failure episode already produced a notification.
    private var failureStreakNotified: Set<String> = []
    private let streakLock = NSLock()

    public struct RepoSyncState {
        public var status: SyncStatus
        public var task: Task<Void, Never>?
        public var attempt: Int
        public var needsPushAgain: Bool
    }

    /// Per-attempt push budget, and the longer budget used for ONE retry when
    /// the first attempt times out (a large first push on a slow link, v4.2.7).
    public let pushTimeout: TimeInterval
    public let longPushTimeout: TimeInterval

    public init(repoManager: RepoManager, backoffSchedule: [TimeInterval] = [1, 2, 4, 8, 16, 32, 64, 128, 256, 300],
                maxAttempts: Int = 6,
                pushTimeout: TimeInterval = RepoManager.networkTimeout,
                longPushTimeout: TimeInterval = RepoManager.networkTimeout * 5) {
        self.repoManager = repoManager
        self.backoffSchedule = backoffSchedule
        self.maxAttempts = maxAttempts
        self.pushTimeout = pushTimeout
        self.longPushTimeout = longPushTimeout
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
        // The single-file ceiling only became known NOW for folders added
        // without a remote: a >100 MiB file committed before the bind would
        // poison every later push (v4.2.26 only covered the one-step path).
        // Exclude still-untracked oversized files going forward; already
        // committed oversized blobs need a history rewrite the app will not do
        // (the push rejection message explains that).
        let threshold = GitHubLimits.effectiveThreshold(remoteURL: url)
        if threshold > 0 {
            _ = await repoManager.excludeLargeFiles(path: repoPath, threshold: threshold)
        }
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

    /// Forget all runtime state for a folder that was removed or relocated.
    /// A push loop, a backoff retry or a "failed" status for a folder that no
    /// longer exists kept pushing/notifying and reappeared after re-adding the
    /// same path (v4.2.26).
    public func reset(repoPath: String) async {
        states[repoPath]?.task?.cancel()
        states[repoPath] = nil
        pushGenerations[repoPath] = nil
        manualPushes.remove(repoPath)
        clearFailureStreak(repoPath: repoPath)
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
        // A manual push owns the repo until it returns: queue this request
        // instead of racing it with a second `git push`.
        if manualPushes.contains(repoPath) {
            if states[repoPath] == nil {
                states[repoPath] = RepoSyncState(status: .pendingPush, task: nil,
                                                 attempt: 0, needsPushAgain: true)
            } else {
                states[repoPath]?.needsPushAgain = true
            }
            return
        }
        if var st = states[repoPath] {
            if st.task != nil {
                st.needsPushAgain = true
                states[repoPath] = st
                return
            }
        }
        startPushLoop(repoPath: repoPath)
    }

    /// Register and start one push loop for a repo. The state entry is created
    /// FIRST: the old code assigned the task through an optional chain that was
    /// a no-op while `states[repoPath]` was nil, so two quick commits could each
    /// start a loop and push concurrently (v4.2.25).
    private func startPushLoop(repoPath: String) {
        let generation = (pushGenerations[repoPath] ?? 0) + 1
        pushGenerations[repoPath] = generation
        if states[repoPath] == nil {
            states[repoPath] = RepoSyncState(status: .pendingPush, task: nil,
                                             attempt: 0, needsPushAgain: false)
        }
        let task = Task.detached { [weak self] in
            guard let self else { return }
            await self.pushLoop(repoPath: repoPath, generation: generation)
        }
        states[repoPath]?.task = task
    }

    /// Called when a loop ends: clear the slot only if this loop still owns it,
    /// and restart when a commit arrived while it was finishing/cancelled
    /// (a dropped request used to wait for the next file change).
    private func finishPushLoop(repoPath: String, generation: Int) {
        guard pushGenerations[repoPath] == generation else { return }
        states[repoPath]?.task = nil
        if states[repoPath]?.needsPushAgain == true {
            states[repoPath]?.needsPushAgain = false
            // Small delay before the follow-up loop: an immediate restart
            // flipped the status back to .pushing right after a failure, so
            // observers (and the menu) could never see the settled .failed
            // state, and a failing remote was hammered without pause (v4.2.26).
            Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self else { return }
                // The repo may have been removed during the 300 ms window
                // (reset() clears states/generations): reviving the loop would
                // push for an unprotected repo and leak state (v4.2.27).
                guard await self.stillOwnsPushSlot(repoPath, generation) else { return }
                await self.startPushLoop(repoPath: repoPath)
            }
        }
    }

    /// Test/diagnostic hook: whether a push loop is registered for a repo.
    func hasActivePushLoop(repoPath: String) -> Bool {
        states[repoPath]?.task != nil
    }

    /// Whether this (repo, generation) still owns the push slot: guards the
    /// delayed restart in finishPushLoop against a folder removed in the
    /// 300 ms window (v4.2.27).
    private func stillOwnsPushSlot(_ repoPath: String, _ generation: Int) -> Bool {
        pushGenerations[repoPath] == generation && states[repoPath] != nil
    }

    /// Serial per-repo push loop with exponential backoff retries.
    private func pushLoop(repoPath: String, generation: Int) async {
        if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
            print("[FV_DEBUG] pushLoop enter \(repoPath)")
        }
        defer { finishPushLoop(repoPath: repoPath, generation: generation) }
        var attempt = 0
        var waitedForOperation: TimeInterval = 0
        while true {
            // A cancelled loop (pushNow superseded it) must not race the
            // manual push with a concurrent `git push` of its own.
            if Task.isCancelled { return }
            // A pull's auto-rebase detaches HEAD for a moment; pushing then
            // failed with "not a full refname" and produced a bogus failure
            // notification during the periodic sync (v4.2.26). Wait for the
            // remote operation to finish instead.
            if await repoManager.operationInProgress(path: repoPath) {
                if waitedForOperation >= 240 {
                    setState(repoPath, .pendingPush)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                waitedForOperation += 0.5
                continue
            }
            waitedForOperation = 0
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
                clearFailureStreak(repoPath: repoPath)
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
                    // Report ONCE per failure episode: clearing the streak here
                    // made every new commit notify again, so continuous editing
                    // produced a notification every few seconds (v4.2.26). The
                    // marker is cleared by the next successful push.
                    setState(repoPath, .failed)
                    self.noteFailureStreak(repoPath: repoPath, message: rejection, finalAttempt: false)
                    return
                }
                // Publish the failed state BEFORE the notification: a listener that
                // reacts to onPushFailure must observe the settled status (v4.2.26).
                setState(repoPath, .failed)
                // Notify once per failure episode: retrying a flaky network no
                // longer spams one notification per attempt (v4.2.3).
                self.noteFailureStreak(repoPath: repoPath,
                                       message: Self.pushFailureMessage(error),
                                       finalAttempt: false)
                // A merge conflict / unrelated history needs a human decision;
                // retrying on a timer cannot fix it.
                if let pull = error as? PullError, Self.isDeterministic(pull) {
                    return
                }
                if attempt >= maxAttempts {
                    self.noteFailureStreak(
                        repoPath: repoPath,
                        message: String(format: NSLocalizedString("已自动重试 %d 次仍未成功，稍后新的改动会再试",
                                                                  comment: "push retries exhausted"), attempt),
                        finalAttempt: true)
                    return
                }
                let delay = backoffSchedule[min(attempt - 1, backoffSchedule.count - 1)]
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
                continue
            }
        }
    }

    /// One notification per failure episode: the first failure is reported, the
    /// intermediate retries stay quiet, and a final "gave up" note is always
    /// reported so a persistent outage is not silent (v4.2.3).
    private func noteFailureStreak(repoPath: String, message: String, finalAttempt: Bool) {
        streakLock.lock()
        let alreadyNotified = failureStreakNotified.contains(repoPath)
        if finalAttempt || !alreadyNotified {
            failureStreakNotified.insert(repoPath)
        }
        streakLock.unlock()
        if finalAttempt || !alreadyNotified {
            onPushFailure(repoPath, message)
        }
    }

    private func clearFailureStreak(repoPath: String) {
        streakLock.lock()
        failureStreakNotified.remove(repoPath)
        streakLock.unlock()
    }

    /// Push once; throws on failure.
    func pushOnce(repoPath: String) async throws {
        do {
            try await push(repoPath: repoPath, timeout: pushTimeout)
        } catch let error as GitCommandError where error.exitCode == -9 {
            // A large first push on a slow link can exceed the normal budget.
            // Retry ONCE with the long budget instead of failing the episode
            // (the retry loop's backoff would restart the upload from scratch).
            try await push(repoPath: repoPath, timeout: max(longPushTimeout, pushTimeout))
        }
    }

    private func push(repoPath: String, timeout: TimeInterval) async throws {
        // An unborn HEAD (adopted empty repo, or an initial commit that failed)
        // has nothing to push: `git push` fails with "src refspec HEAD does not
        // match any", which used to leave a permanent bogus .failed status plus
        // a spurious notification on every sweep (v4.2.27). Skip quietly — the
        // first real commit enqueues a push anyway.
        let unborn = try await repoManager.runner.run(["rev-parse", "--verify", "-q", "HEAD"], cwd: repoPath)
        guard unborn.succeeded else { return }
        let headRef = try await repoManager.runner.run(["symbolic-ref", "--quiet", "--short", "HEAD"],
                                                       cwd: repoPath)
        let branch = headRef.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // Push to the SAME remote/branch a pull would use; "origin" is only a
        // default, not a guarantee (adopted repos may name it differently).
        // When HEAD cannot be resolved (detached HEAD, or a git wrapper that
        // does not implement symbolic-ref), keep the previous "push HEAD"
        // behaviour instead of refusing outright.
        let targetRemote: String
        let refspec: String
        if headRef.succeeded, !branch.isEmpty {
            let target = try await repoManager.pushTarget(path: repoPath, currentBranch: branch)
            targetRemote = target.remote
            refspec = "HEAD:refs/heads/" + target.branch
        } else {
            targetRemote = "origin"
            refspec = "HEAD"
        }
        // --no-verify: pre-push hooks exist for human-initiated pushes; a
        // background sync must not be vetoed by one (auto-sync is always on by
        // design) (v4.2.27).
        let r = try await repoManager.runner.run(["push", "--no-verify", "-u", targetRemote, refspec],
                                                 cwd: repoPath,
                                                 timeout: timeout)
        guard r.succeeded else {
            throw GitCommandError(command: "push " + targetRemote, exitCode: r.exitCode, stderr: r.stderr)
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
        // Hold the repo for the duration of the manual push so a commit that
        // lands meanwhile is queued (and pushed afterwards) instead of starting
        // a concurrent push loop.
        manualPushes.insert(repoPath)
        defer {
            manualPushes.remove(repoPath)
            if states[repoPath]?.needsPushAgain == true {
                states[repoPath]?.needsPushAgain = false
                startPushLoop(repoPath: repoPath)
            }
        }
        setState(repoPath, .pushing)
        do {
            try await pushWithReconcile(repoPath: repoPath)
            await repoManager.clearRemoteSwitchPending(path: repoPath)
            setState(repoPath, .synced)
            return true
        } catch {
            let message = Self.deterministicPushRejection(error) ?? Self.pushFailureMessage(error)
            setState(repoPath, .failed)
            onPushFailure(repoPath, message)
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
            do {
                _ = try await repoManager.pull(path: repoPath)
            } catch let pullError as PullError where Self.isLosslesslyMergeable(pullError) {
                // v4.2.2: in fully automatic mode a same-file conflict or an
                // unrelated remote history must not become a dead end. Fall back
                // to the keep-local union merge (remote versions are kept as
                // "远程副本") and push the merged result — nothing is discarded.
                _ = try await repoManager.mergeSync(path: repoPath)
            }
            try await pushOnce(repoPath: repoPath)
        }
    }

    /// Pull failures the lossless keep-local merge can resolve automatically.
    static func isLosslesslyMergeable(_ error: PullError) -> Bool {
        switch error {
        case .mergeConflict, .unrelatedHistories:
            return true
        default:
            return false
        }
    }

    /// Periodic bidirectional sync (v4.2.17): bring remote-only commits down
    /// (fast-forward or auto-rebase), resolve a conflict / unrelated history
    /// with the lossless keep-local merge, then push whatever local is ahead.
    ///
    /// This is what makes "remote changed on another machine → local files
    /// update" happen without any user action. Safe to call often: an
    /// up-to-date repo only costs a fetch.
    public func syncWithRemote(repoPath: String) async {
        guard await repoManager.remoteURL(path: repoPath) != nil else { return }
        // Let an ongoing commit/rebase/push own the repo for now.
        guard !(await repoManager.operationInProgress(path: repoPath)) else { return }
        do {
            _ = try await repoManager.pull(path: repoPath)
        } catch let error as PullError where Self.isLosslesslyMergeable(error) {
            // Same-file conflict or unrelated histories: keep both sides
            // (remote versions become "远程副本") instead of stalling.
            do {
                _ = try await repoManager.mergeSync(path: repoPath)
            } catch {
                return
            }
        } catch let error as PullError {
            // An EMPTY remote (no branch yet, e.g. the first push never
            // succeeded) is not a dead end: there is nothing to pull, but the
            // local commits still have to be pushed. Returning here used to
            // leave the first push failure unrecovered forever, breaking the
            // "network recovers → auto push" promise (v4.2.26).
            if case .remoteBranchMissing = error {
                // fall through to push
            } else {
                return
            }
        } catch {
            // Auth / network: the push loop and auth monitor already report
            // these; a periodic check must stay quiet.
            return
        }
        // Push anything local is ahead with (including a merge/rebased commit).
        setState(repoPath, .pendingPush)
        await enqueuePush(repoPath: repoPath)
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
        if text.contains("you are not allowed to push") || text.contains("read-only")
            || text.contains("repository is archived") || text.contains("archived repository")
            || text.contains("protected branch") && text.contains("cannot push") {
            return NSLocalizedString("远程仓库不允许推送（只读、已归档或没有写权限）。请在托管平台取消只读/归档或授予写权限后再试。",
                                     comment: "push rejected")
        }
        if text.contains("file is too large") || text.contains("exceeds github's file size limit")
            || (text.contains("push was rejected") && (text.contains("mb") || text.contains("limit"))) {
            var message = NSLocalizedString("远程仓库因为文件过大拒绝了这次推送。新加入的超限文件会被自动排除；若历史提交里已包含超限文件，推送会被永久拒绝，需要整理提交历史（如重新开始版本历史）或更换远程后才能恢复同步。",
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
