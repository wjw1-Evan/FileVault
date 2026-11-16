import XCTest
@testable import FileVaultCore

/// v4.2.8: a protected folder can disappear (external disk unmounted, folder
/// moved) or lose its .git. The UI must say so, and a silently re-initialised
/// root must be announced instead of looking like an empty history.
final class MissingRepoVisibilityTests: XCTestCase {
    func testMissingFolderHealthIsUnavailable() async {
        let repos = RepoManager(runner: TestSupport.newRunner())
        let missing = TestSupport.makeTempDir("missing") + "/gone"
        let health = await repos.health(path: missing)
        XCTAssertFalse(health.available)
        XCTAssertTrue(health.summary.contains("不可用"), health.summary)
    }

    func testPlainFolderWithoutGitIsUnavailable() async throws {
        let dir = TestSupport.makeTempDir("plain")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        TestSupport.write("x", to: dir + "/x.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        let health = await repos.health(path: dir)
        XCTAssertFalse(health.available, "a managed folder without .git must not look healthy")
    }

    func testStartupAnnouncesReinitialisedRoot() async throws {
        let base = TestSupport.makeTempDir("reinit")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let folder = base + "/vault"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        TestSupport.write("precious", to: folder + "/precious.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        var cfg = service.configStore.load()
        cfg.roots = [ManagedRoot(path: folder)]
        service.configStore.save(cfg)

        var messages: [String] = []
        let lock = NSLock()
        service.onFailure.handler = { title, body in
            lock.lock(); messages.append(title + "|" + body); lock.unlock()
        }
        try await service.start()
        lock.lock(); let seen = messages; lock.unlock()
        XCTAssertTrue(seen.contains { $0.contains("重新初始化") },
                      "the user must be told their history is empty now: " + seen.joined(separator: " || "))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/.git"))
    }

    func testAddingAnExistingPlainFolderDoesNotWarn() async throws {
        let base = TestSupport.makeTempDir("firstadd")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let folder = base + "/vault"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        TestSupport.write("doc", to: folder + "/doc.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()

        var messages: [String] = []
        let lock = NSLock()
        service.onFailure.handler = { title, body in
            lock.lock(); messages.append(title + "|" + body); lock.unlock()
        }
        try await service.addRoot(path: folder)
        try? await Task.sleep(nanoseconds: 300_000_000)
        lock.lock(); let seen = messages; lock.unlock()
        XCTAssertFalse(seen.contains { $0.contains("重新初始化") },
                       "binding a folder for the first time is not a lost history")
    }
}
