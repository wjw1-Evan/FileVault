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
    /// v4.2.2: the automatic push loop resolves a same-file conflict with the
    /// lossless keep-local merge (remote version saved as a copy) and converges
    /// to "synced" — no failed state, no rebase leftovers left behind.
    func testAutoPushConflictIsResolvedLosslessly() async throws {
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
        // whose reconcile hits the conflict and falls back to the lossless merge.
        TestSupport.write("local change", to: repo + "/seed.txt")
        _ = try await repos.commitAll(path: repo)
        await sync.setAutoPush(repoPath: repo, enabled: true)
        // Wait for the NEW attempt to finish (a stale "synced" from the push
        // above must not satisfy the wait): the copy is created only on success.
        var waited = 0.0
        while waited < 10 {
            let st = await sync.status(for: repo)
            if st == .synced,
               FileManager.default.fileExists(atPath: repo + "/seed (远程副本).txt") { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }

        let content = try String(contentsOfFile: repo + "/seed.txt", encoding: .utf8)
        XCTAssertEqual(content, "local change", "the local version keeps the original name")
        let copy = repo + "/seed (远程副本).txt"
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy), "the remote version must be kept")
        XCTAssertEqual(try String(contentsOfFile: copy, encoding: .utf8), "remote change")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/.git/rebase-merge"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/.git/rebase-apply"))
        let dirty = try await repos.status(path: repo).count
        XCTAssertEqual(dirty, 0, "the resolved merge leaves a clean tree")
        lock.lock(); let seen = messages; lock.unlock()
        XCTAssertTrue(seen.isEmpty, "a resolved conflict must not be reported as a failure: " + seen.joined(separator: " || "))
        let finalStatus = await sync.status(for: repo)
        XCTAssertEqual(finalStatus, .synced)
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
        XCTAssertFalse(SyncManager.isDeterministic(.repositoryLocked(detail: "index.lock")))
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


    func testDeterministicPushRejectionCoverage() {
        let protected = SyncManager.deterministicPushRejection(
            GitCommandError(command: "push", exitCode: 1,
                            stderr: "remote: error: GH006: Protected branch update failed for refs/heads/main."))
        XCTAssertNotNil(protected)
        XCTAssertTrue(protected?.contains("分支保护") == true)
        let hook = SyncManager.deterministicPushRejection(
            GitCommandError(command: "push", exitCode: 1,
                            stderr: "remote: error: pre-receive hook declined"))
        XCTAssertTrue(hook?.contains("分支保护") == true)
        let tooLargeStderr = """
            remote: error: File big.bin is 150.00 MB; this exceeds GitHub's file size limit of 100.00 MB
            remote: error: File photos/b.jpg is 120.00 MB; this exceeds GitHub's file size limit of 100.00 MB
            """
        let tooLarge = SyncManager.deterministicPushRejection(
            GitCommandError(command: "push", exitCode: 1, stderr: tooLargeStderr))
        XCTAssertTrue(tooLarge?.contains("文件过大") == true)
        XCTAssertTrue(tooLarge?.contains("big.bin") == true, tooLarge ?? "")
        XCTAssertTrue(tooLarge?.contains("photos/b.jpg") == true, tooLarge ?? "")
        XCTAssertEqual(SyncManager.oversizedFiles(in: tooLargeStderr), ["big.bin", "photos/b.jpg"])
        let readOnly = SyncManager.deterministicPushRejection(
            GitCommandError(command: "push", exitCode: 1,
                            stderr: "remote: You are not allowed to push code to this project."))
        XCTAssertTrue(readOnly?.contains("只读") == true, readOnly ?? "")
        let archived = SyncManager.deterministicPushRejection(
            GitCommandError(command: "push", exitCode: 1,
                            stderr: "remote: Repository is archived and cannot be pushed to."))
        XCTAssertTrue(archived?.contains("只读") == true, archived ?? "")
        XCTAssertNil(SyncManager.deterministicPushRejection(
            GitCommandError(command: "push", exitCode: 1,
                            stderr: "fatal: unable to access 'https://x': Could not resolve host")))
    }

    func testPushTimeoutHasItsOwnMessage() {
        let message = SyncManager.pushFailureMessage(
            GitCommandError(command: "push", exitCode: -9, stderr: "git command timed out after 120s"))
        XCTAssertTrue(message.contains("推送超时"), message)
    }
    /// v4.2: an unrelated remote is no longer a dead end. The remote files are
    /// merged into the folder losslessly (both sides kept) and the result is
    /// pushed — no decision step, no retry loop, no forced update.
    func testUnrelatedHistoriesAreMergedAutomatically() async throws {
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

        let change = try await sync.configureRemote(repoPath: repo, url: remote, autoPush: true)
        XCTAssertTrue(change.needsDecision, "the remote does carry its own history")
        let pending = await repos.remoteSwitchPending(path: repo)
        XCTAssertFalse(pending, "the automatic merge resolves the switch")
        await waitForStatus(.synced, repo: repo)

        // Both sides survive and the merge commit reached the remote.
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/own.md"), "local file kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/seed.md"), "remote file merged in")
        let headNow = try await repos.resolveHead(path: repo)
        XCTAssertNotEqual(headNow, localHead, "a merge commit was created")
        let dirty = try await repos.status(path: repo).count
        XCTAssertEqual(dirty, 0)
        let remoteLog = try await repos.runner.run(["--git-dir=" + remote, "log", "--oneline", "main"],
                                                   cwd: remote)
        XCTAssertTrue(remoteLog.succeeded, remoteLog.stderr)
        XCTAssertTrue(remoteLog.stdout.contains("own.md") || remoteLog.stdout.contains("auto:"), remoteLog.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/.git/rebase-merge"))
    }


    /// v4.2.2: a same-file conflict during automatic reconciliation falls back
    /// to the lossless keep-local merge (both contents survive) instead of
    /// dead-ending in a notification the user cannot act on.
    func testAutoPushConflictFallsBackToLosslessMerge() async throws {
        let remote = makeBareRemote("conf")
        let machineA = root + "/machineA"
        try FileManager.default.createDirectory(atPath: machineA, withIntermediateDirectories: true)
        TestSupport.write("base\n", to: machineA + "/note.md")
        _ = try await repos.ensureRepo(at: machineA)
        try await repos.setRemote(path: machineA, url: remote)
        _ = try await repos.runner.run(["push", "-u", "origin", "HEAD"], cwd: machineA)
        let machineB = root + "/machineB"
        _ = try await repos.runner.run(["clone", remote, machineB], cwd: root)
        try await sync.configureRemote(repoPath: machineB, url: remote, autoPush: true)
        await waitForStatus(.synced, repo: machineB)

        // Both machines change the same file.
        TestSupport.write("remote edit\n", to: machineA + "/note.md")
        _ = try await repos.commitAll(path: machineA)
        _ = try await repos.runner.run(["push"], cwd: machineA)
        TestSupport.write("local edit\n", to: machineB + "/note.md")
        _ = try await repos.commitAll(path: machineB)

        let ok = await sync.pushNow(repoPath: machineB)
        XCTAssertTrue(ok, "the conflict must be resolved losslessly, not dead-end")
        XCTAssertEqual(try String(contentsOfFile: machineB + "/note.md", encoding: .utf8), "local edit\n")
        let copy = machineB + "/note (远程副本).md"
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy), "the remote version must be kept")
        XCTAssertEqual(try String(contentsOfFile: copy, encoding: .utf8), "remote edit\n")
        let status = await sync.status(for: machineB)
        XCTAssertEqual(status, .synced)
        XCTAssertFalse(FileManager.default.fileExists(atPath: machineB + "/.git/rebase-merge"))
        let log = try await repos.runner.run(["--git-dir=" + remote, "log", "--oneline", "main"], cwd: remote)
        XCTAssertTrue(log.stdout.contains("sync: 同步远程文件到本地") || log.stdout.contains("auto:"), log.stdout)
    }

    /// v4.2.2: an unrelated remote history (e.g. the repository was recreated)
    /// also falls back to the lossless union merge, then pushes.
    func testAutoPushUnrelatedRemoteFallsBackToLosslessMerge() async throws {
        let remote = makeBareRemote("replaced")
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: repo)
        try await repos.setRemote(path: repo, url: remote)
        _ = try await repos.runner.run(["push", "-u", "origin", "HEAD"], cwd: repo)

        // A different project force-replaces the remote history.
        let other = root + "/otherProject"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        TestSupport.write("other\n", to: other + "/other.md")
        _ = try await repos.ensureRepo(at: other)
        _ = try await repos.runner.run(["push", "-f", remote, "HEAD:main"], cwd: other)

        let ok = await sync.pushNow(repoPath: repo)
        XCTAssertTrue(ok, "unrelated histories must be merged losslessly, not dead-end")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/seed.txt"), "local file kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/other.md"), "remote file merged in")
        let status = await sync.status(for: repo)
        XCTAssertEqual(status, .synced)
        let log = try await repos.runner.run(["--git-dir=" + remote, "log", "--oneline", "main"], cwd: remote)
        XCTAssertTrue(log.stdout.contains("sync: 同步远程文件到本地") || log.stdout.contains("auto:"), log.stdout)
    }


    /// v4.2.3: a flaky network must not produce one notification per retry; the
    /// first failure and the final give-up are reported, retries stay quiet.
    func testPushFailureNotifiesOncePerEpisode() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: repo)
        let limited = SyncManager(repoManager: repos, backoffSchedule: [0.05], maxAttempts: 4)
        var messages: [String] = []
        let lock = NSLock()
        limited.onPushFailure.handler = { _, reason in lock.lock(); messages.append(reason); lock.unlock() }

        try await limited.configureRemote(repoPath: repo, url: root + "/absent.git", autoPush: true)
        var waited = 0.0
        while waited < 10 {
            if await limited.status(for: repo) == .failed { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        lock.lock(); let seen = messages; lock.unlock()
        XCTAssertEqual(seen.count, 2,
                       "one failure + one give-up, not one per retry: " + seen.joined(separator: " || "))
        XCTAssertTrue(seen.last?.contains("已自动重试 4 次") == true, seen.last ?? "")
    }

    /// v4.2.7: a large first push can exceed the normal budget; it must be
    /// retried once with the much longer budget instead of failing the episode.
    func testPushTimeoutRetriesWithLongerBudget() async throws {
        let dir = root + "/fakePush"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let counter = dir + "/count"
        let script = dir + "/fake-git"
        let content = "#!/bin/sh\n"
            + "c=$(cat " + counter + " 2>/dev/null || echo 0)\n"
            + "c=$((c+1))\n"
            + "echo $c > " + counter + "\n"
            + "if [ \"$c\" -eq 1 ]; then sleep 5; fi\n"
            + "exit 0\n"
        TestSupport.write(content, to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let fakeRepos = RepoManager(runner: GitRunner(gitExecutable: script))
        // The first run must have PLENTY of time to record the call before the
        // timeout kills it (a tight budget is flaky under full-suite load); the
        // retry then finds the counter and exits fast.
        let timeoutSync = SyncManager(repoManager: fakeRepos, pushTimeout: 3, longPushTimeout: 8)
        try await timeoutSync.pushOnce(repoPath: dir)
        let calls = (try? String(contentsOfFile: counter, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(calls, "2", "the timed-out push must be retried once with the longer budget")
    }

    // MARK: - Periodic remote sync (v4.2.17)

    /// A commit pushed from another machine must reach the local folder without
    /// the user pressing anything.
    func testPeriodicSyncBringsRemoteChangesDown() async throws {
        let remote = makeBareRemote("periodic")
        let repoA = root + "/repoA"
        _ = try await repos.ensureRepo(at: repoA)
        try await sync.configureRemote(repoPath: repoA, url: remote, autoPush: true)
        await waitForStatus(.synced, repo: repoA)

        let machineB = root + "/machineB"
        _ = try await repos.runner.run(["clone", remote, machineB], cwd: root)
        TestSupport.write("from B", to: machineB + "/from-b.md")
        _ = try await repos.runner.run(["add", "-A"], cwd: machineB)
        _ = try await repos.runner.run(["-c", "user.name=B", "-c", "user.email=b@x",
                                        "commit", "-m", "B change"], cwd: machineB)
        _ = try await repos.runner.run(["push"], cwd: machineB)

        await sync.syncWithRemote(repoPath: repoA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repoA + "/from-b.md"),
                      "the remote-only file must be pulled into the folder")
        await waitForStatus(.synced, repo: repoA)
        let dirty = try await repos.status(path: repoA).count
        XCTAssertEqual(dirty, 0)
    }

    /// Diverged histories reconcile automatically (rebase) and the local commit
    /// is pushed back.
    func testPeriodicSyncMergesDivergedAndPushes() async throws {
        let remote = makeBareRemote("periodic-diverge")
        let repoA = root + "/repoA"
        _ = try await repos.ensureRepo(at: repoA)
        try await sync.configureRemote(repoPath: repoA, url: remote, autoPush: true)
        await waitForStatus(.synced, repo: repoA)

        let machineB = root + "/machineB"
        _ = try await repos.runner.run(["clone", remote, machineB], cwd: root)
        TestSupport.write("from B", to: machineB + "/from-b.md")
        _ = try await repos.runner.run(["add", "-A"], cwd: machineB)
        _ = try await repos.runner.run(["-c", "user.name=B", "-c", "user.email=b@x",
                                        "commit", "-m", "B change"], cwd: machineB)
        _ = try await repos.runner.run(["push"], cwd: machineB)
        TestSupport.write("from A", to: repoA + "/from-a.md")
        _ = try await repos.commitAll(path: repoA)

        await sync.syncWithRemote(repoPath: repoA)
        await waitForStatus(.synced, repo: repoA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repoA + "/from-b.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repoA + "/from-a.md"))
        let remoteLog = try await repos.runner.run(["--git-dir=" + remote, "log", "--oneline", "main"],
                                                   cwd: remote)
        XCTAssertTrue(remoteLog.stdout.contains("from-a.md") || remoteLog.stdout.contains("auto:"),
                      remoteLog.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoA + "/.git/rebase-merge"))
    }

    /// Same-file conflict on a periodic sync keeps both sides losslessly.
    func testPeriodicSyncResolvesConflictLosslessly() async throws {
        let remote = makeBareRemote("periodic-conflict")
        let repoA = root + "/repoA"
        _ = try await repos.ensureRepo(at: repoA)
        TestSupport.write("base\n", to: repoA + "/note.md")
        _ = try await repos.commitAll(path: repoA)
        try await sync.configureRemote(repoPath: repoA, url: remote, autoPush: true)
        await waitForStatus(.synced, repo: repoA)

        let machineB = root + "/machineB"
        _ = try await repos.runner.run(["clone", remote, machineB], cwd: root)
        TestSupport.write("remote edit\n", to: machineB + "/note.md")
        _ = try await repos.runner.run(["add", "-A"], cwd: machineB)
        _ = try await repos.runner.run(["-c", "user.name=B", "-c", "user.email=b@x",
                                        "commit", "-m", "B edit"], cwd: machineB)
        _ = try await repos.runner.run(["push"], cwd: machineB)
        TestSupport.write("local edit\n", to: repoA + "/note.md")
        _ = try await repos.commitAll(path: repoA)

        await sync.syncWithRemote(repoPath: repoA)
        await waitForStatus(.synced, repo: repoA)
        XCTAssertEqual(try String(contentsOfFile: repoA + "/note.md", encoding: .utf8), "local edit\n")
        let copy = repoA + "/note (远程副本).md"
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy), "remote version must be kept")
        XCTAssertEqual(try String(contentsOfFile: copy, encoding: .utf8), "remote edit\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoA + "/.git/rebase-merge"))
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

    /// v4.2: a replaced remote that already has commits is merged into the folder
    /// automatically — local files stay, remote-only files come in — and the
    /// merged result is pushed. Nothing waits for the user.
    func testSwitchToRemoteWithContentMergesAutomatically() async throws {
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
        XCTAssertFalse(pending, "no decision is left behind")
        await waitForStatus(.synced, repo: repo)

        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/local.md"), "local file kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/seed.md"), "remote file merged in")
        let headNow = try await repos.resolveHead(path: repo)
        XCTAssertNotEqual(headNow, localHead, "the merge commit replaced the old head")
        let countResult = try await repos.runner.run(["--git-dir=" + newRemote, "rev-list", "--count", "main"],
                                                     cwd: newRemote)
        let remoteCount = Int(countResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(remoteCount, 1, "the merged local commits are pushed to the new remote")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/.git/rebase-merge"))
    }

    /// v4.2: switching to a diverged remote reconciles on the spot (merge of both
    /// sides, then push) instead of waiting for an explicit push.
    func testDivergedRemoteSwitchMergesAndPushes() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: repo)
        let oldRemote = makeBareRemote("old3")
        try await sync.configureRemote(repoPath: repo, url: oldRemote, autoPush: true)
        await waitForStatus(.synced, repo: repo)

        // The new remote starts with the same history, then BOTH sides move on:
        // the histories diverge, so an explicit push must reconcile (rebase).
        let newRemote = makeBareRemote("related")
        _ = try await repos.runner.run(["push", newRemote, "main:main"], cwd: repo)
        TestSupport.write("after", to: repo + "/after.md")
        _ = try await repos.commitAll(path: repo)
        let sibling = root + "/newRemoteSibling"
        let clone = try await repos.runner.run(["clone", "-b", "main", newRemote, sibling], cwd: root)
        XCTAssertTrue(clone.succeeded, "clone: " + clone.stderr)
        TestSupport.write("sibling", to: sibling + "/sibling.md")
        _ = try await repos.runner.run(["add", "-A"], cwd: sibling)
        _ = try await repos.runner.run(["-c", "user.name=Other", "-c", "user.email=o@x",
                                        "commit", "-m", "sibling"], cwd: sibling)
        let pushSibling = try await repos.runner.run(["push", "origin", "HEAD:main"], cwd: sibling)
        XCTAssertTrue(pushSibling.succeeded, "sibling push: " + pushSibling.stderr)
        let change = try await sync.configureRemote(repoPath: repo, url: newRemote, autoPush: true)
        XCTAssertTrue(change.needsDecision)
        let pendingAfter = await repos.remoteSwitchPending(path: repo)
        XCTAssertFalse(pendingAfter, "the automatic merge resolves the switch")
        await waitForStatus(.synced, repo: repo)

        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/after.md"), "local commit kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/sibling.md"), "remote commit merged in")
        let log = try await repos.runner.run(["--git-dir=" + newRemote, "log", "--oneline", "main"],
                                             cwd: newRemote)
        XCTAssertTrue(log.stdout.contains("sibling") || log.stdout.contains("after.md") || log.stdout.contains("auto:"),
                      log.stdout)
    }


    /// Switching to a remote that already has the SAME (fast-forwardable)
    /// history is safe to automate: no decision needed, upstream re-bound.
    func testSwitchToRelatedRemoteWithFastForwardableHistoryContinuesAutomatically() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: repo)
        let oldRemote = makeBareRemote("ffOld")
        try await sync.configureRemote(repoPath: repo, url: oldRemote, autoPush: true)
        await waitForStatus(.synced, repo: repo)
        TestSupport.write("v2", to: repo + "/v2.md")
        _ = try await repos.commitAll(path: repo)

        // The new remote already contains exactly this history (an https→ssh or
        // re-clone switch): pushing is a fast-forward, so no user decision.
        let newRemote = makeBareRemote("ffNew")
        _ = try await repos.runner.run(["push", newRemote, "main:main"], cwd: repo)
        let change = try await sync.configureRemote(repoPath: repo, url: newRemote, autoPush: true)
        XCTAssertTrue(change.changed)
        XCTAssertFalse(change.needsDecision, "fast-forwardable history needs no decision")
        let pending = await repos.remoteSwitchPending(path: repo)
        XCTAssertFalse(pending)
        await waitForStatus(.synced, repo: repo)
        let upstream = try await repos.runner.run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], cwd: repo)
        XCTAssertTrue(upstream.succeeded, "upstream re-bound to the new remote")
        let newHead = try await repos.runner.run(["--git-dir=" + newRemote, "rev-parse", "main"],
                                                 cwd: newRemote)
        let localHead = try await repos.resolveHead(path: repo)
        XCTAssertEqual(newHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines), localHead)
    }

    /// Hand-edited/imported remotes may lack the fetch refspec; binding must add it.
    func testSetRemoteAddsDefaultFetchRefspec() async throws {
        let repo = root + "/repoA"
        _ = try await repos.ensureRepo(at: repo)
        let first = makeBareRemote("refspecA")
        let second = makeBareRemote("refspecB")
        _ = try await repos.runner.run(["remote", "add", "origin", first], cwd: repo)
        _ = try await repos.runner.run(["config", "--unset-all", "remote.origin.fetch"], cwd: repo)

        let change = try await repos.setRemote(path: repo, url: second)
        XCTAssertTrue(change.changed)
        let refspec = try await repos.runner.run(["config", "--local", "--get-all", "remote.origin.fetch"],
                                                 cwd: repo)
        XCTAssertTrue(refspec.succeeded, refspec.stderr)
        XCTAssertTrue(refspec.stdout.contains("refs/remotes/origin/*"), refspec.stdout)
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
