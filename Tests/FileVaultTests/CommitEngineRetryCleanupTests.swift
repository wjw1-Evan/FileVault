import XCTest
@testable import FileVaultCore

/// v4.2.31: unregisterRoot must also drop the auto-commit retry state. The
/// scheduled retry gates on failureCounts, so a leftover count made FileVault
/// commit a folder the user had just removed or relocated up to a minute
/// after the removal.
final class CommitEngineRetryCleanupTests: XCTestCase {
    func testPendingRetryDiesWhenRootIsUnregistered() async throws {
        let base = TestSupport.makeTempDir("retryclean")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let folder = base + "/vault"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        TestSupport.write("seed", to: folder + "/seed.md")

        let repos = RepoManager(runner: TestSupport.newRunner())
        let engine = CommitEngine(repoManager: repos,
                                  debouncer: Debouncer(quietInterval: 5, maxWait: 60) { _ in },
                                  pause: PauseController())
        engine.retryDelay = 0.3
        engine.registerRoot(folder)
        _ = try await repos.ensureRepo(at: folder)

        // Break the repo so the pipeline run fails and schedules a retry.
        try? FileManager.default.removeItem(atPath: folder + "/.git")
        var failures = 0
        let lock = NSLock()
        engine.onCommitFailure = { _, _ in
            lock.lock(); failures += 1; lock.unlock()
        }
        await engine.commitSerialized(repoPath: folder)
        lock.lock(); let firstFailures = failures; lock.unlock()
        XCTAssertEqual(firstFailures, 1, "the failed run must have been reported once")

        // The user removes the folder; afterwards a repo comes back (e.g. the
        // user's own git init) with the previous content still uncommitted.
        engine.unregisterRoot(folder)
        let reinit = try await repos.runner.run(["init", "-b", "main"], cwd: folder)
        XCTAssertTrue(reinit.succeeded, reinit.stderr)
        TestSupport.write("late", to: folder + "/late.md")

        // The scheduled retry (0.3 s) must find no failure state left.
        try? await Task.sleep(nanoseconds: 900_000_000)
        let dirty = try await repos.isDirty(path: folder)
        XCTAssertTrue(dirty, "no auto-commit may run for a root the engine has unregistered")
        lock.lock(); let failuresAfter = failures; lock.unlock()
        XCTAssertEqual(failuresAfter, 1, "no further failure episodes for a forgotten root")
    }
}
