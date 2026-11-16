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
}
