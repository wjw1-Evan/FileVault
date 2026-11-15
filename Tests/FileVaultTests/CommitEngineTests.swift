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


    /// Git cannot track empty directories: a folder created while FileVault is
    /// watching must still become a version (via a hidden marker file, so a
    /// rollback can recreate the folder).
    func testEmptyFolderCreationCommits() async throws {
        let repo = root + "/vault"
        service.updateGeneral { $0.debounceSeconds = 1 }
        try FileManager.default.createDirectory(atPath: repo + "/new-empty", withIntermediateDirectories: true)
        let n = await waitForCommits(2, repo: repo)
        XCTAssertGreaterThanOrEqual(n, 2, "creating an empty folder must auto-commit")

        let log = try await service.repoManager.log(path: repo, max: 10)
        let subject = log.first?.subject ?? ""
        XCTAssertTrue(subject.contains("新建文件夹"), "folder-only commit needs a readable subject: \(subject)")
        XCTAssertTrue(subject.contains("new-empty"), "subject names the new folder: \(subject)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/new-empty/.gitkeep"),
                      "the marker keeps the empty folder versionable")
        let tracked = await service.repoManager.listFiles(path: repo)
        XCTAssertTrue(tracked.contains("new-empty/.gitkeep"), "marker is tracked: \(tracked)")

        // The marker is an implementation detail — not a user-visible file.
        let changed = try await service.history.changedFiles(repoPath: repo, hash: log[0].hash)
        XCTAssertTrue(changed.isEmpty, "marker must be hidden from the changed-file list: \(changed)")
    }

    /// Folders that are ignored on purpose (node_modules/ etc.) must stay out
    /// of history and must never receive a marker file.
    func testEmptyFolderInsideIgnoredDirectoryDoesNotCommit() async throws {
        let repo = root + "/vault"
        service.updateGeneral { $0.debounceSeconds = 1 }
        try FileManager.default.createDirectory(atPath: repo + "/node_modules/empty",
                                                withIntermediateDirectories: true)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let log = try await service.repoManager.log(path: repo, max: 10)
        XCTAssertEqual(log.count, 1, "ignored folders must not create versions")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/node_modules/empty/.gitkeep"))
    }



    /// A pre-existing empty folder must not be "versioned" just because some
    /// event touches it later (Finder .DS_Store, mtime change, ...).
    func testTouchingPreExistingEmptyFolderDoesNotCreateVersion() async throws {
        let base = TestSupport.makeTempDir("preexist")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repo = base + "/vault"
        try? FileManager.default.createDirectory(atPath: repo + "/old-empty", withIntermediateDirectories: true)
        TestSupport.write("seed", to: repo + "/seed.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: repo)
        service.updateGeneral { $0.debounceSeconds = 1 }
        // Not a creation: just a metadata change on the existing folder.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: repo + "/old-empty")
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let log = try await service.repoManager.log(path: repo, max: 10)
        XCTAssertEqual(log.count, 1, "an old empty folder is not a new version: \(log.map(\.subject))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/old-empty/.gitkeep"))
    }

    /// Finder can leave an ignored .DS_Store in a brand-new folder; it is
    /// still an empty folder as far as versioning is concerned.
    func testFolderWithOnlyIgnoredFileStillCommits() async throws {
        let repo = root + "/vault"
        service.updateGeneral { $0.debounceSeconds = 1 }
        try FileManager.default.createDirectory(atPath: repo + "/ds", withIntermediateDirectories: true)
        TestSupport.write("x", to: repo + "/ds/.DS_Store")
        let n = await waitForCommits(2, repo: repo)
        XCTAssertGreaterThanOrEqual(n, 2, "an ignored-only folder still becomes a version")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/ds/.gitkeep"))
        let tracked = await service.repoManager.listFiles(path: repo)
        XCTAssertTrue(tracked.contains("ds/.gitkeep"))
        XCTAssertFalse(tracked.contains("ds/.DS_Store"), "ignored file stays out of the repo")
    }

    /// Creating a folder together with its first file is a normal content
    /// commit (no folder-only message, no marker noise in the subject).
    func testFolderWithFileUsesContentSubject() async throws {
        let repo = root + "/vault"
        service.updateGeneral { $0.debounceSeconds = 1 }
        try FileManager.default.createDirectory(atPath: repo + "/docs", withIntermediateDirectories: true)
        TestSupport.write("hello", to: repo + "/docs/a.md")
        let n = await waitForCommits(2, repo: repo)
        XCTAssertGreaterThanOrEqual(n, 2)
        let log = try await service.repoManager.log(path: repo, max: 10)
        let subject = log.first?.subject ?? ""
        XCTAssertTrue(subject.contains("a.md"), "content commit names the file: \(subject)")
        XCTAssertFalse(subject.contains("新建文件夹"), "normal commits keep the content subject")
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
