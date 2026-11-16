import XCTest
@testable import FileVaultCore

/// v4.2.6: a file excluded for exceeding the remote's single-file limit is not
/// backed up, so it must be VISIBLE (notification + health warning) instead of
/// silently disappearing from version control.
final class LargeFileBackupVisibilityTests: XCTestCase {
    func testExcludedLargeFilesAreListedAndRulesNotDuplicated() async throws {
        let dir = TestSupport.makeTempDir("bignotify")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        TestSupport.write("seed", to: dir + "/seed.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: dir)
        TestSupport.write(String(repeating: "x", count: 64), to: dir + "/huge.mov")

        let excluded = await repos.excludeLargeFiles(path: dir, threshold: 16)
        XCTAssertEqual(excluded, ["huge.mov"])
        XCTAssertEqual(repos.excludedLargeFiles(path: dir), ["huge.mov"])

        // The file is ignored now: a second pass must not duplicate the rule.
        let again = await repos.excludeLargeFiles(path: dir, threshold: 16)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(repos.excludedLargeFiles(path: dir), ["huge.mov"])
    }

    func testHealthSummaryWarnsAboutExcludedFiles() {
        let health = RepoHealth(commitCount: 3, sizeBytes: 2048, lastCommitDate: nil,
                                excludedLargeFileCount: 2)
        XCTAssertTrue(health.summary.contains("2 个大文件未同步"), health.summary)
        let clean = RepoHealth(commitCount: 1, sizeBytes: 1024, lastCommitDate: nil)
        XCTAssertFalse(clean.summary.contains("大文件"), clean.summary)
    }

    func testServiceNotifiesWhenFilesAreExcluded() async throws {
        let base = TestSupport.makeTempDir("bigsvc")
        defer { try? FileManager.default.removeItem(atPath: base) }
        try? FileManager.default.createDirectory(atPath: base + "/vault", withIntermediateDirectories: true)
        TestSupport.write("seed", to: base + "/vault/seed.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: base + "/vault")

        var titles: [String] = []
        var bodies: [String] = []
        let lock = NSLock()
        service.onFailure.handler = { title, body in
            lock.lock(); titles.append(title); bodies.append(body); lock.unlock()
        }
        service.commitEngine.onLargeFilesExcluded?(base + "/vault", ["huge.mov"])
        lock.lock(); let seenTitles = titles; let seenBodies = bodies; lock.unlock()
        XCTAssertEqual(seenTitles.count, 1)
        XCTAssertTrue(seenTitles[0].contains("大文件"), seenTitles[0])
        XCTAssertTrue(seenBodies[0].contains("huge.mov"), seenBodies[0])
    }
}
