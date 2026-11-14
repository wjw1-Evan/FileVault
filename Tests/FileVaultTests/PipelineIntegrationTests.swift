import XCTest
@testable import FileVaultCore

/// Pipeline-level large-file protection (FR-12 end-to-end).
final class LargeFilePipelineTests: XCTestCase {
    var root: String!
    var service: FileVaultService!

    override func setUp() async throws {
        root = TestSupport.makeTempDir("bigpipe")
        try? FileManager.default.createDirectory(atPath: root + "/vault/work", withIntermediateDirectories: true)
        service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        try await service.addRoot(path: root + "/vault")
        service.commitEngine.largeFileThreshold = 512 * 1024  // 512KB for tests
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
        let repo = root + "/vault/work"
        TestSupport.write(String(repeating: "B", count: 1024 * 1024), to: repo + "/big.bin")
        TestSupport.write("small", to: repo + "/small.md")
        let n = await waitForCommits(2, repo: repo)
        XCTAssertGreaterThanOrEqual(n, 2, "auto-commit should still fire")
        let log = try await service.repoManager.log(path: repo, max: 5)
        let subject = log.first?.subject ?? ""
        XCTAssertTrue(subject.contains("small.md"), "small file committed, got: \(subject)")
        XCTAssertFalse(subject.contains("big.bin"), "large file must not be committed")
        let excludeFile = try String(contentsOfFile: repo + "/.git/info/exclude", encoding: .utf8)
        XCTAssertTrue(excludeFile.contains("big.bin"), "large file recorded in .git/info/exclude")
    }
}

/// Regression guards for the watcher filters (self-trigger fix + structure events).
final class WatcherFilterTests: XCTestCase {
    func testDotGitInternalChangesDoNotTriggerActivity() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("fv-dotgit-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("sub/.git/objects"), withIntermediateDirectories: true)
        let engine = WatcherEngine(rootPath: base.path, source: FSEventsChangeSource())
        let lock = NSLock()
        var leaked: [String] = []
        engine.start(onActivity: { name in
            lock.lock(); leaked.append(name); lock.unlock()
        }, onRootStructureChanged: {})
        defer { engine.stop() }
        try await Task.sleep(nanoseconds: 500_000_000)
        try "junk".write(toFile: base.appendingPathComponent("sub/.git/index").path, atomically: true, encoding: .utf8)
        // .git-internal changes must never map to repo activity (self-trigger fix).
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        lock.lock(); let leakedCopy = leaked; lock.unlock()
        XCTAssertTrue(leakedCopy.isEmpty, "git-internal changes leaked as activity: \(leakedCopy)")
    }

    func testRootLevelChangeFiresStructureEvent() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("fv-rootchg-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let engine = WatcherEngine(rootPath: base.path, source: FSEventsChangeSource())
        let exp = expectation(description: "structure event fires")
        engine.start(onActivity: { _ in }, onRootStructureChanged: { exp.fulfill() })
        defer { engine.stop() }
        try await Task.sleep(nanoseconds: 500_000_000)
        try "t".write(toFile: base.appendingPathComponent("top.txt").path, atomically: true, encoding: .utf8)
        await fulfillment(of: [exp], timeout: 10)
        engine.stop()
    }
}

/// FileVaultService lifecycle: add/remove/rescan (FR-02/03).
final class ServiceLifecycleTests: XCTestCase {
    func testAddRemoveRescanRoundtrip() async throws {
        let root = TestSupport.makeTempDir("svc")
        try? FileManager.default.createDirectory(atPath: root + "/vault/alpha", withIntermediateDirectories: true)
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        try await service.addRoot(path: root + "/vault")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/vault/alpha/.git"))
        XCTAssertEqual(service.rootsSnapshot().count, 1)
        // New first-level folder is adopted on rescan.
        try? FileManager.default.createDirectory(atPath: root + "/vault/beta", withIntermediateDirectories: true)
        TestSupport.write("b", to: root + "/vault/beta/b.md")
        await service.rescanRoot((root + "/vault"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/vault/beta/.git"))
        // removeRoot clears config but keeps the repos on disk.
        await service.removeRoot(path: root + "/vault")
        XCTAssertEqual(service.rootsSnapshot().count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/vault/alpha/.git"), "repos must survive removeRoot")
        XCTAssertEqual(service.configStore.load().roots.count, 0)
        try? FileManager.default.removeItem(atPath: root)
    }
}
