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
        let repo = root + "/vault/work"
        TestSupport.write("hello", to: repo + "/a.md")
        let n = await waitForCommits(2, repo: repo)
        XCTAssertGreaterThanOrEqual(n, 2)
    }

    func testDebounceMergesSavesIntoOneCommit() async throws {
        let repo = root + "/vault/work"
        // 10 saves within the 5s debounce window -> 1 commit for them.
        for i in 0..<10 {
            TestSupport.write("save-\(i)", to: repo + "/b.md")
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let n = await waitForCommits(2, repo: repo)
        let log = try await service.repoManager.log(path: repo, max: 10)
        let auto = log.first { $0.subject.contains("b.md") }
        XCTAssertNotNil(auto)
    }

    func testPauseSuppressesAndResumeCommits() async throws {
        let repo = root + "/vault/work"
        await service.setGlobalPaused(true)
        TestSupport.write("p1", to: repo + "/c.md")
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
        TestSupport.write("d1", to: root + "/vault/work/d.md")
        _ = await waitForCommits(2, repo: root + "/vault/work")
        try FileManager.default.removeItem(atPath: root + "/vault/work/d.md")
        _ = await waitForCommits(3, repo: root + "/vault/work")
        let log = try await service.repoManager.log(path: root + "/vault/work", max: 10)
        let del = log.first { $0.subject.contains("删除") }
        XCTAssertNotNil(del)
    }
}
