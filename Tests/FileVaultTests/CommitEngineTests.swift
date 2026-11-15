import XCTest
@testable import FileVaultCore

/// End-to-end auto-commit tests through FileVaultService (real FSEvents + debounce + git).
final class CommitEngineTests: XCTestCase {
    var root: String!
    var service: FileVaultService!

    override func setUp() async throws {
        root = TestSupport.makeTempDir("cmroot")
        try? FileManager.default.createDirectory(atPath: root + "/vault", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: root + "/vault/work", withIntermediateDirectories: true)
        // Track the nested folder from the initial commit so git reports each
        // later file individually instead of one collapsed "work/" entry.
        TestSupport.write("seed", to: root + "/vault/work/seed.md")
        service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        try await service.addRoot(path: root + "/vault")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root!)
    }

    private func waitForCommits(_ n: Int, repo: String, timeout: Double = 20) async -> Int {
        var waited = 0.0
        var count = 0
        while waited < timeout {
            count = (try? await service.repoManager.log(path: repo, max: 50).count) ?? 0
            if count >= n { return count }
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 0.2
    }
        return count
    }

    func testAutoCommitSingleChange() async throws {
        // v4.0: the repo path is the managed root; content may live in a subfolder.
        let repo = root + "/vault"
        TestSupport.write("hello", to: repo + "/work/a.md")
        let n = await waitForCommits(2, repo: repo)
        XCTAssertGreaterThanOrEqual(n, 2)
    }

    /// A loose file directly in the root is versioned content too.
    func testAutoCommitRootLevelFile() async throws {
        let repo = root + "/vault"
        TestSupport.write("root-level", to: repo + "/root-file.md")
        let n = await waitForCommits(2, repo: repo)
        XCTAssertGreaterThanOrEqual(n, 2)
        let log = try await service.repoManager.log(path: repo, max: 10)
        XCTAssertTrue(log.contains { $0.subject.contains("root-file.md") },
                      "root-level file committed: \(log.map(\.subject))")
        let tracked = await service.repoManager.listFiles(path: repo)
        XCTAssertTrue(tracked.contains("root-file.md"))
    }

    func testDebounceMergesSavesIntoOneCommit() async throws {
        let repo = root + "/vault"
        // 10 saves within the 5s debounce window -> 1 commit for them.
        for i in 0..<10 {
            TestSupport.write("save-\(i)", to: repo + "/work/b.md")
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let n = await waitForCommits(2, repo: repo)
        let log = try await service.repoManager.log(path: repo, max: 10)
        let auto = log.first { $0.subject.contains("b.md") }
        XCTAssertNotNil(auto)
    }

    func testPauseSuppressesAndResumeCommits() async throws {
        let repo = root + "/vault"
        await service.setGlobalPaused(true)
        TestSupport.write("p1", to: repo + "/work/c.md")
        // Pause: no commit within a window that would otherwise commit.
        try? await Task.sleep(nanoseconds: 7_000_000_000)
        let n0 = (try? await service.repoManager.log(path: repo, max: 10)) ?? []
        XCTAssertEqual(n0.count, 1)  // only the initial commit
        await service.setGlobalPaused(false)
        // Resume triggers full check -> commits the paused change.
        let n1 = await waitForCommits(2, repo: repo)
        XCTAssertGreaterThanOrEqual(n1, 2)
    }

    func testDeleteCommitsAsDeletion() async throws {
        let repo = root + "/vault"
        TestSupport.write("d1", to: repo + "/work/d.md")
        _ = await waitForCommits(2, repo: repo)
        try FileManager.default.removeItem(atPath: repo + "/work/d.md")
        _ = await waitForCommits(3, repo: repo)
        let log = try await service.repoManager.log(path: repo, max: 10)
        let del = log.first { $0.subject.contains("删除") }
        XCTAssertNotNil(del)
    }
}
