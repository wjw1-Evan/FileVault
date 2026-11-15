import XCTest
@testable import FileVaultCore

/// Pipeline-level large-file protection (FR-12 end-to-end) with the v4.0
/// root-repo model: the managed root itself is the repo.
final class LargeFilePipelineTests: XCTestCase {
    var root: String!
    var repo: String!
    var service: FileVaultService!

    override func setUp() async throws {
        root = TestSupport.makeTempDir("bigpipe")
        repo = root + "/vault"
        // A root that holds BOTH a plain file and a nested folder used to crash
        // addRoot with ENOTDIR (the old per-subfolder enumeration bug).
        try? FileManager.default.createDirectory(atPath: repo + "/work", withIntermediateDirectories: true)
        TestSupport.write("readme", to: repo + "/readme.md")
        // Keep the nested folder tracked from the initial commit: git otherwise
        // reports the whole directory as one untracked entry, hiding files in it.
        TestSupport.write("keep", to: repo + "/work/keep.md")
        service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        try await service.addRoot(path: repo)
        // v3.1.3: no local threshold — the pipeline follows the remote. Point the
        // repo at a github.com URL so GitHub's 100 MiB limit applies (auto-push is
        // off by default, so no network is touched).
        try await service.repoManager.setRemote(path: repo,
                                                url: "https://github.com/acme/vault.git")
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

    func testPipelineExcludesLargeFileButCommitsSmall() async throws {
        // Root-level file (used to break ENOTDIR in addRoot) is committed too.
        TestSupport.write("top", to: repo + "/top.md")
        XCTAssertTrue(TestSupport.writeSparse(repo + "/work/big.bin", bytes: 120 * 1024 * 1024))
        TestSupport.write("small", to: repo + "/work/small.md")
        let n = await waitForCommits(2, repo: repo)
        XCTAssertGreaterThanOrEqual(n, 2, "auto-commit should still fire")
        let log = try await service.repoManager.log(path: repo, max: 5)
        let subjects = log.map(\.subject)
        XCTAssertTrue(subjects.contains { $0.contains("small.md") },
                      "small file committed, got: \(subjects)")
        XCTAssertFalse(subjects.contains { $0.contains("big.bin") },
                       "large file must not be committed, got: \(subjects)")
        let excludeFile = try String(contentsOfFile: repo + "/.git/info/exclude", encoding: .utf8)
        XCTAssertTrue(excludeFile.contains("big.bin"), "large file recorded in .git/info/exclude")
        XCTAssertFalse(excludeFile.isEmpty)
    }
}

/// Regression guards for the watcher filters (self-trigger fix + root activity).
final class WatcherFilterTests: XCTestCase {
    func testDotGitInternalChangesDoNotTriggerActivity() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("fv-dotgit-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("sub/.git/objects"), withIntermediateDirectories: true)
        let engine = WatcherEngine(rootPath: base.path, source: FSEventsChangeSource())
        let flag = ActivityFlag()
        engine.start(onActivity: { flag.mark() })
        defer { engine.stop() }
        // Let FSEvents replay the directory-creation events from just before the
        // stream started (they are NOT .git writes) before arming the assertion.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        flag.reset()
        try "junk".write(toFile: base.appendingPathComponent("sub/.git/index").path, atomically: true, encoding: .utf8)
        // .git-internal changes must never map to repo activity (self-trigger fix).
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertFalse(flag.fired, "git-internal changes leaked as activity")
    }

    func testRootLevelFileChangeFiresActivity() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("fv-rootchg-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let engine = WatcherEngine(rootPath: base.path, source: FSEventsChangeSource())
        let exp = expectation(description: "root-level activity fires")
        let onceLock = NSLock()
        var fulfilled = false
        engine.start(onActivity: {
            onceLock.lock()
            let first = !fulfilled
            fulfilled = true
            onceLock.unlock()
            if first { exp.fulfill() }
        })
        defer { engine.stop() }
        try await Task.sleep(nanoseconds: 500_000_000)
        try "t".write(toFile: base.appendingPathComponent("top.txt").path, atomically: true, encoding: .utf8)
        await fulfillment(of: [exp], timeout: 10)
        engine.stop()
    }
}

/// Required v4.0 coverage: a root-level file change auto-commits the root repo.
final class RootRepoAutoCommitTests: XCTestCase {
    func testRootLevelFileChangeAutoCommitsRootRepo() async throws {
        let base = TestSupport.makeTempDir("rootauto")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repo = base + "/vault"
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: repo)

        TestSupport.write("top-level v1", to: repo + "/top-level.md")

        var found = false
        for _ in 0..<100 {
            let log = (try? await service.repoManager.log(path: repo, max: 10)) ?? []
            if log.contains(where: { $0.subject.contains("top-level.md") }) {
                found = true
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(found, "root-level file change must be auto-committed by the root repo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/.git"))
        let tracked = await service.repoManager.listFiles(path: repo)
        XCTAssertTrue(tracked.contains("top-level.md"), "tracked: \(tracked)")
    }
}

/// FileVaultService lifecycle under the v4.0 root-repo model (FR-02/03).
final class ServiceLifecycleTests: XCTestCase {
    func testAddRemoveRootKeepsSingleRootRepo() async throws {
        let root = TestSupport.makeTempDir("svc")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let vault = root + "/vault"
        // A plain file AND a nested folder in the same root: addRoot used to
        // fail with ENOTDIR while enumerating first-level folders.
        try? FileManager.default.createDirectory(atPath: vault + "/nested", withIntermediateDirectories: true)
        TestSupport.write("top", to: vault + "/top.txt")
        TestSupport.write("deep", to: vault + "/nested/deep.md")

        let service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        try await service.addRoot(path: vault)

        XCTAssertTrue(FileManager.default.fileExists(atPath: vault + "/.git"), "the root IS the repo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault + "/nested/.git"),
                       "nested folders must never become their own repos")
        XCTAssertTrue(service.repoManager.isRepo(at: vault))
        XCTAssertEqual(service.rootsSnapshot().count, 1)

        // Flush deterministically (stop the watcher first so the debounce cannot
        // race the explicit pipeline call).
        service.watcher(for: vault)?.stop()
        TestSupport.write("top v2", to: vault + "/top.txt")
        TestSupport.write("deep v2", to: vault + "/nested/deep.md")
        await service.commitEngine.commitAllDirty(root: vault)

        let log = try await service.repoManager.log(path: vault, max: 10)
        XCTAssertEqual(log.count, 2, "initial commit + one root-wide auto-commit")
        let commit = try XCTUnwrap(log.first)
        XCTAssertTrue(commit.subject.contains("top.txt"), "root-level file recorded: \(commit.subject)")
        XCTAssertTrue(commit.subject.contains("deep.md"), "nested file recorded: \(commit.subject)")
        let tracked = await service.repoManager.listFiles(path: vault)
        XCTAssertTrue(tracked.contains("top.txt"))
        XCTAssertTrue(tracked.contains("nested/deep.md"))

        // removeRoot clears config but keeps the root repo on disk.
        await service.removeRoot(path: vault)
        XCTAssertEqual(service.rootsSnapshot().count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault + "/.git"),
                      "the root repo must survive removeRoot")
        XCTAssertEqual(service.configStore.load().roots.count, 0)
    }
}

/// A moved/deleted configured folder must not brick startup (v4.0).
final class MissingRootTests: XCTestCase {
    func testStartSkipsMissingConfiguredRoot() async throws {
        let base = TestSupport.makeTempDir("missingroot")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let alive = base + "/alive"
        try? FileManager.default.createDirectory(atPath: alive, withIntermediateDirectories: true)
        TestSupport.write("x", to: alive + "/x.md")

        let cfgDir = URL(fileURLWithPath: base + "/cfg")
        let store = ConfigStore(directory: cfgDir)
        var cfg = store.load()
        cfg.roots = [
            ManagedRoot(path: base + "/gone"),
            ManagedRoot(path: alive),
        ]
        store.save(cfg)

        let service = FileVaultService(configDirectory: cfgDir)
        try await service.start()   // must not throw because of the missing root

        let resolvedAlive = try URL(fileURLWithPath: alive).resolvingSymlinksInPath().path
        XCTAssertEqual(service.rootsSnapshot(), [resolvedAlive],
                       "only the existing root is attached")
        XCTAssertNil(service.watcher(for: base + "/gone"))
        XCTAssertTrue(service.repoManager.isRepo(at: resolvedAlive),
                      "the remaining root still gets its repo")
    }
}
