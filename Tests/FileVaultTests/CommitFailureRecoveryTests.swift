import XCTest
@testable import FileVaultCore

/// v4.2.2: an auto-commit can fail for a reason that clears without any new
/// file event (locked index, disk space, permissions). It must be reported with
/// a readable reason and retried automatically instead of leaving the change
/// unversioned forever.
final class CommitFailureRecoveryTests: XCTestCase {
    func testFailedCommitIsReportedAndRetriedAutomatically() async throws {
        let dir = TestSupport.makeTempDir("commitretry")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        TestSupport.write("seed\n", to: dir + "/seed.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: dir)

        let lock = NSLock()
        var failures: [String] = []
        var commits: [String] = []
        let engine = CommitEngine(repoManager: repos,
                                  debouncer: Debouncer(quietInterval: 30, maxWait: 60, onFired: { _ in }),
                                  pause: PauseController())
        engine.retryDelay = 0.2
        engine.onCommitFailure = { _, reason in lock.lock(); failures.append(reason); lock.unlock() }
        engine.onCommit = { _, hash, _ in lock.lock(); commits.append(hash); lock.unlock() }

        // A read-only .git fails the commit deterministically. (A rejecting
        // pre-commit hook no longer works here: v4.2.27 auto-commits pass
        // --no-verify on purpose — hooks are for human-initiated commits.)
        if geteuid() == 0 {
            throw XCTSkip("filesystem ignores file permissions (running as root?)")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir + "/.git")
        TestSupport.write("pending\n", to: dir + "/pending.md")
        await engine.runCommitPipeline(repoPath: dir)
        lock.lock(); let firstFailures = failures; let firstCommits = commits.count; lock.unlock()
        XCTAssertEqual(firstCommits, 0)
        XCTAssertEqual(firstFailures.count, 1, "the failure is reported once: " + firstFailures.joined(separator: " | "))
        XCTAssertFalse(firstFailures.first?.isEmpty ?? true)

        // The cause disappears; the scheduled retry commits without new events.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir + "/.git")
        var waited = 0.0
        while waited < 8 {
            lock.lock(); let committed = commits.count; lock.unlock()
            if committed > 0 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        lock.lock(); let finalCommits = commits.count; let finalFailures = failures; lock.unlock()
        XCTAssertEqual(finalCommits, 1, "the failed commit must be retried automatically")
        XCTAssertEqual(finalFailures.count, 1, "retries must stay quiet: " + finalFailures.joined(separator: " | "))
        let dirty = try await repos.status(path: dir).count
        XCTAssertEqual(dirty, 0)
    }

    func testFailureDescriptionNamesCommonCauses() {
        XCTAssertTrue(CommitEngine.failureDescription(
            GitCommandError(command: "commit", exitCode: 128,
                            stderr: "fatal: No space left on device")).contains("磁盘空间不足"))
        XCTAssertTrue(CommitEngine.failureDescription(
            GitCommandError(command: "commit", exitCode: 128,
                            stderr: "error: unable to create file: Permission denied")).contains("权限"))
        XCTAssertTrue(CommitEngine.failureDescription(
            GitCommandError(command: "commit", exitCode: 128,
                            stderr: "fatal: Unable to create '/x/.git/index.lock': File exists.")).contains("锁文件"))
    }
}
