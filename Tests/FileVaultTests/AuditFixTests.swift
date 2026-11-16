import XCTest
@testable import FileVaultCore

/// Regression tests for the v4.2.25 full audit (business flows + code).
///
/// Each test pins a defect that was found by reading the code, not a feature:
/// they are deliberately narrow so a regression names the exact invariant.
final class AuditFixTests: XCTestCase {
    // MARK: - GitRunner

    /// A payload larger than the pipe buffer must not deadlock: stdin used to be
    /// written before the child existed, so anything over ~64 KB hung forever.
    func testLargeStdinIsFullyDelivered() async throws {
        let dir = TestSupport.makeTempDir("stdin")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let payload = String(repeating: "FileVault large stdin payload abcdefghij\n", count: 40_000)
        let file = dir + "/payload.txt"
        try payload.write(toFile: file, atomically: true, encoding: .utf8)

        let runner = TestSupport.newRunner()
        let fileHash = try await runner.run(["hash-object", file])
        let stdinHash = try await runner.run(["hash-object", "--stdin"], stdin: payload)
        XCTAssertTrue(fileHash.succeeded)
        XCTAssertTrue(stdinHash.succeeded)
        XCTAssertEqual(stdinHash.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       fileHash.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - RepoManager: status is not "clean" when it fails

    func testStatusAndDirtyFailLoudlyOutsideARepository() async throws {
        let dir = TestSupport.makeTempDir("notrepo")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let repo = RepoManager(runner: TestSupport.newRunner())

        do {
            _ = try await repo.status(path: dir)
            XCTFail("status() must throw when git cannot read the working tree")
        } catch let error as GitCommandError {
            XCTAssertFalse(error.stderr.isEmpty, "the real git reason must survive")
        }
        do {
            _ = try await repo.isDirty(path: dir)
            XCTFail("isDirty() must not answer false when status() failed")
        } catch {
            // expected: fail closed
        }
    }

    // MARK: - Large-file exclusion

    /// A name with glob characters must still be excluded literally, and the
    /// rule must round-trip through excludedLargeFiles for the UI.
    func testLargeFileWithGlobCharactersIsExcludedLiterally() async throws {
        let root = TestSupport.makeTempDir("exclude")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = RepoManager(runner: TestSupport.newRunner())
        _ = try await repo.ensureRepo(at: root)

        let name = "a[1]?.bin"
        XCTAssertTrue(TestSupport.writeSparse(root + "/" + name, bytes: 4096))
        let excluded = await repo.excludeLargeFiles(path: root, threshold: 1024)
        XCTAssertEqual(excluded, [name], "the file must really be excluded, not just reported")

        let entries = try await repo.status(path: root)
        XCTAssertFalse(entries.contains { $0.path == name })
        XCTAssertEqual(repo.excludedLargeFiles(path: root), [name])
    }

    func testExcludeRuleEscapingRoundTrips() {
        XCTAssertEqual(RepoManager.escapedExcludeRule("a[1]*?.bin"), "a\\[1\\]\\*\\?.bin")
        XCTAssertEqual(RepoManager.unescapedExcludeRule("a\\[1\\]\\*\\?.bin"), "a[1]*?.bin")
        XCTAssertEqual(RepoManager.escapedExcludeRule("!secret.txt"), "\\!secret.txt")
        XCTAssertEqual(RepoManager.escapedExcludeRule("#notes.md"), "\\#notes.md")
    }

    // MARK: - History: NUL-safe comparison

    func testCompareKeepsFilenamesContainingNewlines() async throws {
        let root = TestSupport.makeTempDir("compare")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = RepoManager(runner: TestSupport.newRunner())
        let history = HistoryService(repoManager: repo)
        _ = try await repo.ensureRepo(at: root)

        let name = "line\nbreak.txt"
        TestSupport.write("v1", to: root + "/" + name)
        _ = try await repo.commitAll(path: root)
        TestSupport.write("v2", to: root + "/" + name)
        _ = try await repo.commitAll(path: root)

        let log = try await repo.log(path: root)
        XCTAssertGreaterThanOrEqual(log.count, 2)
        let files = try await history.compare(repoPath: root, from: log[1].hash, to: log[0].hash)
        XCTAssertEqual(files.map(\.path), [name], "one file, no bogus split on the newline")
    }

    /// Rolling a folder back must delete files renamed after the target version,
    /// and must not choke on the paths it feeds to git rm.
    func testRestoreDirectoryRemovesRenamedFiles() async throws {
        let root = TestSupport.makeTempDir("dirstore")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = RepoManager(runner: TestSupport.newRunner())
        let history = HistoryService(repoManager: repo)
        _ = try await repo.ensureRepo(at: root)

        try FileManager.default.createDirectory(atPath: root + "/docs", withIntermediateDirectories: true)
        TestSupport.write("keep me", to: root + "/docs/a.txt")
        _ = try await repo.commitAll(path: root)
        let target = try await repo.log(path: root).first!.hash

        try FileManager.default.moveItem(atPath: root + "/docs/a.txt", toPath: root + "/docs/b.txt")
        _ = try await repo.commitAll(path: root)

        _ = try await history.restoreDirectory(repoPath: root, directory: "docs", to: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/docs/a.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/docs/b.txt"))
    }

    // MARK: - SyncManager: one push loop per repo

    func testEnqueuePushRegistersTheLoopBeforeItStarts() async throws {
        let root = TestSupport.makeTempDir("pushloop")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repoPath = root + "/repo"
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: repoPath)

        let remote = root + "/remote.git"
        _ = try repos.runner.runSync(["init", "--bare", remote], cwd: root, timeout: 10)
        let setup = SyncManager(repoManager: repos)
        try await setup.configureRemote(repoPath: repoPath, url: remote, autoPush: true)
        for _ in 0..<50 {
            if await setup.status(for: repoPath) == .synced { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let sync = SyncManager(repoManager: repos)
        TestSupport.write("new content", to: repoPath + "/later.txt")
        _ = try await repos.commitAll(path: repoPath)
        await sync.enqueuePush(repoPath: repoPath)
        let registered = await sync.hasActivePushLoop(repoPath: repoPath)
        XCTAssertTrue(registered, "the push loop must be tracked so it cannot be started twice")
        for _ in 0..<50 {
            if await sync.status(for: repoPath) == .synced { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - ConfigStore: a failed write is reported

    func testConfigSaveReportsWriteFailure() throws {
        let base = TestSupport.makeTempDir("cfgsave")
        let dir = URL(fileURLWithPath: base).appendingPathComponent("config")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(atPath: base)
        }
        let store = ConfigStore(directory: dir)
        var cfg = AppConfig()
        cfg.roots = [ManagedRoot(path: base)]
        XCTAssertTrue(store.save(cfg))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        XCTAssertFalse(store.save(cfg), "a read-only folder must be reported, not silently ignored")
    }

    // MARK: - Diagnostics masking

    func testDiagnosticMaskingHidesHomeAndOtherAccounts() {
        let home = NSHomeDirectory()
        let masked = SupportBundle.masked("git at " + home + "/bin/git and /Users/someone/notes")
        XCTAssertFalse(masked.contains(home))
        XCTAssertFalse(masked.contains("/Users/someone"))
    }
}
