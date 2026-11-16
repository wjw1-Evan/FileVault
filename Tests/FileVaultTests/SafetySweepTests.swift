import XCTest
@testable import FileVaultCore

/// v4.2.4: a periodic safety sweep must catch changes whose FSEvents
/// notification was missed (sleep/wake, dropped events, watcher restarts), while
/// still respecting the user's "pause auto-commit" choice.
final class SafetySweepTests: XCTestCase {
    var root: String!
    var service: FileVaultService!

    override func setUp() async throws {
        root = TestSupport.makeTempDir("sweep")
        try? FileManager.default.createDirectory(atPath: root + "/vault", withIntermediateDirectories: true)
        TestSupport.write("seed", to: root + "/vault/seed.md")
        service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        try await service.addRoot(path: root + "/vault")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root!)
    }

    private func commitCount(_ repo: String) async -> Int {
        (try? await service.repoManager.log(path: repo, max: 50).count) ?? 0
    }

    private func waitUntilClean(_ repo: String, timeout: Double = 10) async {
        var waited = 0.0
        while waited < timeout {
            if ((try? await service.repoManager.status(path: repo).count) ?? 1) == 0 { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
    }

    func testSweepCommitsChangesMissedByWatcher() async throws {
        let repo = root + "/vault"
        await waitUntilClean(repo)
        // No watcher events: only the sweep can notice this change.
        service.watchers[repo]?.stop()
        TestSupport.write("missed", to: repo + "/missed.md")
        try? await Task.sleep(nanoseconds: 300_000_000)
        let before = await commitCount(repo)
        let dirtyBefore = (try? await service.repoManager.status(path: repo).count) ?? 0
        XCTAssertGreaterThan(dirtyBefore, 0, "the missed change is dirty before the sweep")

        await service.sweepOnce()
        let after = await commitCount(repo)
        XCTAssertGreaterThan(after, before, "the sweep must commit the missed change")
        let files = await service.repoManager.listFiles(path: repo)
        XCTAssertTrue(files.contains("missed.md"))
        let dirtyAfter = (try? await service.repoManager.status(path: repo).count) ?? 1
        XCTAssertEqual(dirtyAfter, 0)
    }

    func testSweepRespectsPause() async throws {
        let repo = root + "/vault"
        await waitUntilClean(repo)
        service.pause.setPaused(true, forRoot: repo)
        service.watchers[repo]?.stop()
        TestSupport.write("paused", to: repo + "/paused.md")
        let before = await commitCount(repo)

        await service.sweepOnce()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let after = await commitCount(repo)
        XCTAssertEqual(after, before, "a paused root must not be committed by the sweep")
        let dirty = (try? await service.repoManager.status(path: repo).count) ?? 0
        XCTAssertGreaterThan(dirty, 0)
        service.pause.setPaused(false, forRoot: repo)
    }
}
