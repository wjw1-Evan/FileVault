import XCTest
@testable import FileVaultCore

final class SyncManagerTests: XCTestCase {
    var root: String!
    var repos: RepoManager!
    var sync: SyncManager!

    override func setUp() {
        root = TestSupport.makeTempDir("synroot")
        try? FileManager.default.createDirectory(atPath: root + "/repoA", withIntermediateDirectories: true)
        TestSupport.write("seed", to: root + "/repoA/seed.txt")
        repos = RepoManager(runner: TestSupport.newRunner())
        sync = SyncManager(repoManager: repos, backoffSchedule: [0.1], maxAttempts: 2)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root!)
    }

    private func makeBareRemote(_ name: String) -> String {
        let remote = root + "/\(name).git"
        _ = try? repos.runner.runSync(["init", "--bare", remote], cwd: root, timeout: 10)
        return remote
    }

    private func waitForStatus(_ expected: SyncStatus, repo: String, timeout: Double = 10) async {
        var waited = 0.0
        while waited < timeout {
            let st = await sync.status(for: repo)
            if st == expected { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        let final = await sync.status(for: repo)
        XCTAssertEqual(final, expected)
    }

    func testAutoPushAfterCommit() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: root + "/repoA")
        let remote = makeBareRemote("r1")
        try await sync.configureRemote(repoPath: repo, url: remote, autoPush: true)
        TestSupport.write("data", to: repo + "/f.md")
        _ = try await repos.commitAll(path: repo)
        await sync.enqueuePush(repoPath: repo)
        await waitForStatus(.synced, repo: repo)
        let r = try await repos.runner.run(["--git-dir=\(remote)", "log", "--oneline"], cwd: remote)
        XCTAssertTrue(r.succeeded)
        XCTAssertTrue(r.stdout.contains("auto:"))
    }

    func testNoRemoteStatus() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: root + "/repoA")
        let st = await sync.status(for: repo)
        XCTAssertEqual(st, .noRemote)
        await sync.enqueuePush(repoPath: repo)
        let st2 = await sync.status(for: repo)
        XCTAssertEqual(st2, .noRemote)
    }

    func testPushFailureThenManualRetry() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: root + "/repoA")
        // Remote path does not exist yet -> push fails.
        let remote = root + "/not-yet.git"
        try await sync.configureRemote(repoPath: repo, url: remote, autoPush: true)
        await waitForStatus(.failed, repo: repo)
        // Create the remote, then manual retry succeeds.
        _ = makeBareRemote("not-yet")
        let ok = await sync.pushNow(repoPath: repo)
        XCTAssertTrue(ok)
        await waitForStatus(.synced, repo: repo)
    }

    func testAutoPushDisabledStaysPending() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: root + "/repoA")
        let remote = makeBareRemote("r2")
        try await sync.configureRemote(repoPath: repo, url: remote, autoPush: false)
        // Local commits exist but never pushed -> pendingPush is correct semantics.
        await waitForStatus(.pendingPush, repo: repo)
        let ok0 = await sync.pushNow(repoPath: repo)
        XCTAssertTrue(ok0)
        await waitForStatus(.synced, repo: repo)
        TestSupport.write("more", to: repo + "/f2.md")
        _ = try await repos.commitAll(path: repo)
        await sync.enqueuePush(repoPath: repo)
        await waitForStatus(.pendingPush, repo: repo)
        let ok = await sync.pushNow(repoPath: repo)
        XCTAssertTrue(ok)
    }

    /// Another machine pushed first: a push must reconcile (fast-forward /
    /// auto-rebase) and retry instead of failing forever (v4.1.5).
    func testAutoPushReconcilesRemoteMovedFirst() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: repo)
        let remote = makeBareRemote("r3")
        try await sync.configureRemote(repoPath: repo, url: remote, autoPush: false)
        TestSupport.write("base", to: repo + "/base.md")
        _ = try await repos.commitAll(path: repo)
        let ok1 = await sync.pushNow(repoPath: repo)
        XCTAssertTrue(ok1, "initial push")

        // Machine B clones, changes a different file and pushes.
        let other = root + "/repoB"
        let clone = try await repos.runner.run(["clone", "-b", "main", remote, other], cwd: root)
        XCTAssertTrue(clone.succeeded, "clone: " + clone.stderr)
        TestSupport.write("remote work", to: other + "/remote.md")
        let addB = try await repos.runner.run(["add", "-A"], cwd: other)
        XCTAssertTrue(addB.succeeded, addB.stderr)
        let commitB = try await repos.runner.run(["-c", "user.name=Other", "-c", "user.email=o@x",
                                                  "commit", "-m", "other machine"], cwd: other)
        XCTAssertTrue(commitB.succeeded, commitB.stderr)
        let pushB = try await repos.runner.run(["push", "origin", "HEAD:main"], cwd: other)
        XCTAssertTrue(pushB.succeeded, "machine B push: " + pushB.stderr)

        // Machine A commits a different file: its push is rejected, then
        // reconciled (fetch + auto-rebase) and retried automatically.
        TestSupport.write("local work", to: repo + "/local.md")
        _ = try await repos.commitAll(path: repo)
        let ok2 = await sync.pushNow(repoPath: repo)
        XCTAssertTrue(ok2, "push after reconcile should succeed")

        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/remote.md"),
                      "remote work must be pulled in by the reconcile")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/local.md"))
        let log = try await repos.runner.run(["--git-dir=" + remote, "log", "--oneline", "main"], cwd: remote)
        XCTAssertTrue(log.stdout.contains("other machine"), log.stdout)
        XCTAssertTrue(log.stdout.contains("local.md"), "the local commit must reach the remote: " + log.stdout)
    }

    /// Conflicting edits must stop with a readable reason: the local commit is
    /// kept, the rebase is aborted and no retry loop keeps hammering.
    func testAutoPushConflictAbortsCleanlyAndNotifies() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: repo)
        let remote = makeBareRemote("r4")
        try await sync.configureRemote(repoPath: repo, url: remote, autoPush: false)
        TestSupport.write("base", to: repo + "/seed.txt")
        _ = try await repos.commitAll(path: repo)
        let ok1 = await sync.pushNow(repoPath: repo)
        XCTAssertTrue(ok1, "initial push")

        // Machine B changes the SAME file and pushes.
        let other = root + "/repoB"
        let clone = try await repos.runner.run(["clone", "-b", "main", remote, other], cwd: root)
        XCTAssertTrue(clone.succeeded, "clone: " + clone.stderr)
        TestSupport.write("remote change", to: other + "/seed.txt")
        _ = try await repos.runner.run(["add", "-A"], cwd: other)
        let commitB = try await repos.runner.run(["-c", "user.name=Other", "-c", "user.email=o@x",
                                                  "commit", "-m", "remote edit"], cwd: other)
        XCTAssertTrue(commitB.succeeded, commitB.stderr)
        let pushB = try await repos.runner.run(["push", "origin", "HEAD:main"], cwd: other)
        XCTAssertTrue(pushB.succeeded, "machine B push: " + pushB.stderr)

        var messages: [String] = []
        let lock = NSLock()
        sync.onPushFailure.handler = { _, reason in
            lock.lock(); messages.append(reason); lock.unlock()
        }
        // Local edits the same file; enabling auto-push starts the push loop,
        // whose reconcile hits the conflict.
        TestSupport.write("local change", to: repo + "/seed.txt")
        _ = try await repos.commitAll(path: repo)
        let localHead = try await repos.resolveHead(path: repo)
        await sync.setAutoPush(repoPath: repo, enabled: true)
        await waitForStatus(.failed, repo: repo)
        try? await Task.sleep(nanoseconds: 400_000_000)   // deterministic: no more retries
        let headNow = try await repos.resolveHead(path: repo)
        XCTAssertEqual(headNow, localHead, "the local commit must survive the failed reconcile")
        let content = try String(contentsOfFile: repo + "/seed.txt", encoding: .utf8)
        XCTAssertEqual(content, "local change")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/.git/rebase-merge"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/.git/rebase-apply"))
        let dirty = try await repos.status(path: repo).count
        XCTAssertEqual(dirty, 0, "the aborted rebase restores a clean tree")
        lock.lock(); let seen = messages; lock.unlock()
        XCTAssertFalse(seen.isEmpty, "the user must be told")
        XCTAssertTrue(seen.contains { $0.contains("自动合并已中止") }, seen.joined(separator: " || "))
        let finalStatus = await sync.status(for: repo)
        XCTAssertEqual(finalStatus, .failed)
    }

    // MARK: - Push classification (v4.1.5)

    func testIsRejectedPushRecognisesNonFastForwardReasons() {
        let samples = [
            "! [rejected] main -> main (non-fast-forward)",
            "! [rejected] main -> main (fetch first)",
            "error: failed to push some refs to 'origin'",
            "hint: Updates were rejected because the remote contains work that you do not have locally.",
            "hint: Updates were rejected because the tip of your current branch is behind",
        ]
        for sample in samples {
            XCTAssertTrue(SyncManager.isRejectedPush(GitCommandError(command: "push", exitCode: 1,
                                                                     stderr: sample)), sample)
        }
        XCTAssertFalse(SyncManager.isRejectedPush(
            GitCommandError(command: "push", exitCode: 128,
                            stderr: "fatal: unable to access 'https://x': Could not resolve host")))
        XCTAssertFalse(SyncManager.isRejectedPush(
            GitCommandError(command: "push", exitCode: 1,
                            stderr: "fatal: Authentication failed for 'https://x'")))
        struct Fake: Error {}
        XCTAssertFalse(SyncManager.isRejectedPush(Fake()))
    }

    func testDeterministicPullErrorsStopRetries() {
        XCTAssertTrue(SyncManager.isDeterministic(.mergeConflict(files: ["a.md"], aborted: true)))
        XCTAssertTrue(SyncManager.isDeterministic(.unrelatedHistories))
        XCTAssertTrue(SyncManager.isDeterministic(.remoteBranchMissing(remote: "origin", branch: "main")))
        XCTAssertFalse(SyncManager.isDeterministic(.authenticationFailed(detail: "x")))
        XCTAssertFalse(SyncManager.isDeterministic(.networkFailed(detail: "x")))
        XCTAssertFalse(SyncManager.isDeterministic(.busy))
        XCTAssertFalse(SyncManager.isDeterministic(.localChanges(detail: "x")))
    }

    func testPushFailureMessageReusesPullReasonAndSuggestion() {
        let conflict = SyncManager.pushFailureMessage(PullError.mergeConflict(files: ["a.md"], aborted: true))
        XCTAssertTrue(conflict.contains("自动合并已中止"), conflict)
        XCTAssertTrue(conflict.contains("git pull --rebase"), conflict)

        let auth = SyncManager.pushFailureMessage(
            GitCommandError(command: "push", exitCode: 1, stderr: "fatal: Authentication failed for 'https://x'"))
        XCTAssertTrue(auth.contains(AuthClassifier.guidance()), auth)

        let unknown = SyncManager.pushFailureMessage(PullError.failed(detail: "boom"))
        XCTAssertEqual(unknown, "拉取失败：boom")
    }

    /// Unrelated histories cannot be reconciled automatically: the auto-push
    /// loop must report once and stop rather than retrying on a timer.
    func testAutoPushStopsOnUnrelatedHistories() async throws {
        let remote = makeBareRemote("r5")
        // Seed the remote from a different repo (a different root history).
        let seed = root + "/seedRepo"
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        TestSupport.write("seed\n", to: seed + "/seed.md")
        _ = try await repos.ensureRepo(at: seed)
        try await repos.setRemote(path: seed, url: remote)
        _ = try await repos.runner.run(["push", "-u", "origin", "HEAD"], cwd: seed)

        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("own\n", to: repo + "/own.md")
        _ = try await repos.commitAll(path: repo)
        let localHead = try await repos.resolveHead(path: repo)

        var messages: [String] = []
        let lock = NSLock()
        sync.onPushFailure.handler = { _, reason in lock.lock(); messages.append(reason); lock.unlock() }
        let change = try await sync.configureRemote(repoPath: repo, url: remote, autoPush: true)
        XCTAssertTrue(change.needsDecision, "a remote that already has commits needs an explicit decision")
        let pending = await repos.remoteSwitchPending(path: repo)
        XCTAssertTrue(pending)
        let statusWhilePending = await sync.status(for: repo)
        XCTAssertEqual(statusWhilePending, .pendingPush, "nothing is auto-pushed while undecided")

        // After the user explicitly opts to push, v4.1.5 reconciliation refuses
        // the unrelated histories with a readable message instead of retrying.
        await repos.clearRemoteSwitchPending(path: repo)
        await sync.enqueuePush(repoPath: repo)
        await waitForStatus(.failed, repo: repo)
        try? await Task.sleep(nanoseconds: 400_000_000)
        lock.lock(); let seen = messages; lock.unlock()
        XCTAssertTrue(seen.contains { $0.contains("互不相关") }, seen.joined(separator: " || "))
        let headNow = try await repos.resolveHead(path: repo)
        XCTAssertEqual(headNow, localHead, "the local history must be preserved")
        let dirty = try await repos.status(path: repo).count
        XCTAssertEqual(dirty, 0)
        let finalStatus = await sync.status(for: repo)
        XCTAssertEqual(finalStatus, .failed)
    }

    // MARK: - Switching the remote repository (v4.1.6)

    /// Replacing the remote with an EMPTY repository re-points everything and
    /// pushes the local history there (no stale refs/upstream from the old one).
    func testSwitchToEmptyRemoteRepointsStateAndPushes() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: repo)
        let oldRemote = makeBareRemote("old")
        try await sync.configureRemote(repoPath: repo, url: oldRemote, autoPush: true)
        await waitForStatus(.synced, repo: repo)
        TestSupport.write("v2", to: repo + "/v2.md")
        _ = try await repos.commitAll(path: repo)
        let okOld = await sync.pushNow(repoPath: repo)
        XCTAssertTrue(okOld)
        let head = try await repos.resolveHead(path: repo)

        let newRemote = makeBareRemote("new")
        let change = try await sync.configureRemote(repoPath: repo, url: newRemote, autoPush: true)
        XCTAssertTrue(change.changed)
        XCTAssertFalse(change.needsDecision, "an empty remote needs no decision")
        XCTAssertTrue(change.fetchSucceeded)
        XCTAssertEqual(change.remoteCommitCount, 0)
        await waitForStatus(.synced, repo: repo)

        let urlNow = try await repos.runner.run(["remote", "get-url", "origin"], cwd: repo)
        XCTAssertEqual(urlNow.stdout.trimmingCharacters(in: .whitespacesAndNewlines), newRemote)
        let newLog = try await repos.runner.run(["--git-dir=" + newRemote, "log", "--oneline", "main"],
                                                cwd: newRemote)
        XCTAssertTrue(newLog.succeeded, newLog.stderr)
        XCTAssertTrue(newLog.stdout.contains("auto:"), newLog.stdout)
        let upstream = try await repos.runner.run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], cwd: repo)
        XCTAssertTrue(upstream.succeeded, "upstream must be re-bound to the new remote")
        let pending = await repos.remoteSwitchPending(path: repo)
        XCTAssertFalse(pending)
        let remoteMain = try await repos.runner.run(["rev-parse", "refs/remotes/origin/main"], cwd: repo)
        XCTAssertEqual(remoteMain.stdout.trimmingCharacters(in: .whitespacesAndNewlines), head,
                       "remote-tracking refs must describe the NEW remote")
    }

    /// A replaced remote that already has commits must not be merged or pushed
    /// automatically: the user decides (sync / force pull / push) afterwards.
    func testSwitchToRemoteWithContentWaitsForDecision() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: repo)
        let oldRemote = makeBareRemote("old2")
        try await sync.configureRemote(repoPath: repo, url: oldRemote, autoPush: true)
        await waitForStatus(.synced, repo: repo)
        TestSupport.write("local", to: repo + "/local.md")
        _ = try await repos.commitAll(path: repo)
        let localHead = try await repos.resolveHead(path: repo)

        // The new remote already carries its own commit.
        let newRemote = makeBareRemote("content")
        let seed = root + "/seedSwitch"
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        TestSupport.write("seed", to: seed + "/seed.md")
        _ = try await repos.ensureRepo(at: seed)
        try await repos.setRemote(path: seed, url: newRemote)
        _ = try await repos.runner.run(["push", "-u", "origin", "HEAD"], cwd: seed)

        let change = try await sync.configureRemote(repoPath: repo, url: newRemote, autoPush: true)
        XCTAssertTrue(change.changed)
        XCTAssertTrue(change.needsDecision)
        XCTAssertGreaterThan(change.remoteCommitCount, 0)
        let pending = await repos.remoteSwitchPending(path: repo)
        XCTAssertTrue(pending)
        let statusNow = await sync.status(for: repo)
        XCTAssertEqual(statusNow, .pendingPush)

        // Nothing was pushed while the decision is pending.
        let beforeCount = try await repos.runner.run(["--git-dir=" + newRemote, "rev-list", "--count", "main"],
                                                     cwd: newRemote)
        try? await Task.sleep(nanoseconds: 400_000_000)
        let afterCount = try await repos.runner.run(["--git-dir=" + newRemote, "rev-list", "--count", "main"],
                                                    cwd: newRemote)
        XCTAssertEqual(beforeCount.stdout, afterCount.stdout, "auto-push must wait for the decision")
        let headNow = try await repos.resolveHead(path: repo)
        XCTAssertEqual(headNow, localHead)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/.git/rebase-merge"))
    }

    /// An explicit push after the switch resolves the pending decision.
    func testExplicitPushAfterRemoteSwitchClearsDecision() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: repo)
        let oldRemote = makeBareRemote("old3")
        try await sync.configureRemote(repoPath: repo, url: oldRemote, autoPush: true)
        await waitForStatus(.synced, repo: repo)

        // The new remote starts with the SAME history (so an explicit push can
        // fast-forward); it still counts as "remote already has commits".
        let newRemote = makeBareRemote("related")
        _ = try await repos.runner.run(["push", newRemote, "main:main"], cwd: repo)
        let change = try await sync.configureRemote(repoPath: repo, url: newRemote, autoPush: true)
        XCTAssertTrue(change.needsDecision)
        let pendingBefore = await repos.remoteSwitchPending(path: repo)
        XCTAssertTrue(pendingBefore)

        TestSupport.write("after", to: repo + "/after.md")
        _ = try await repos.commitAll(path: repo)
        let ok = await sync.pushNow(repoPath: repo)
        XCTAssertTrue(ok, "an explicit push must resolve the switch")
        let pendingAfter = await repos.remoteSwitchPending(path: repo)
        XCTAssertFalse(pendingAfter, "explicit push clears the pending decision")
        let statusAfter = await sync.status(for: repo)
        XCTAssertEqual(statusAfter, .synced)
        let log = try await repos.runner.run(["--git-dir=" + newRemote, "log", "--oneline", "main"],
                                             cwd: newRemote)
        XCTAssertTrue(log.stdout.contains("after.md") || log.stdout.contains("auto:"), log.stdout)
    }

    /// Re-saving the same remote URL must not detach anything.
    func testBindingTheSameRemoteIsNotAChange() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: repo)
        let remote = makeBareRemote("same")
        let first = try await sync.configureRemote(repoPath: repo, url: remote, autoPush: true)
        XCTAssertTrue(first.changed)
        await waitForStatus(.synced, repo: repo)
        let upstreamBefore = try await repos.runner.run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], cwd: repo)
        XCTAssertTrue(upstreamBefore.succeeded)

        let second = try await sync.configureRemote(repoPath: repo, url: remote, autoPush: true)
        XCTAssertFalse(second.changed)
        XCTAssertFalse(second.needsDecision)
        let upstreamAfter = try await repos.runner.run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], cwd: repo)
        XCTAssertTrue(upstreamAfter.succeeded, "saving the same URL must keep the upstream")
        let pending = await repos.remoteSwitchPending(path: repo)
        XCTAssertFalse(pending)
    }
}
