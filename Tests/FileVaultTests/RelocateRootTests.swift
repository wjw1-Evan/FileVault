import XCTest
@testable import FileVaultCore

/// v4.2.5: a protected folder can be moved/renamed (or an external disk can
/// mount under a different path). Relocating must keep the Git history, the
/// paused state and the watcher, and refuse a target that is already managed.
final class RelocateRootTests: XCTestCase {
    var root: String!
    var service: FileVaultService!

    override func setUp() async throws {
        root = TestSupport.makeTempDir("relocate")
        try? FileManager.default.createDirectory(atPath: root + "/vault", withIntermediateDirectories: true)
        TestSupport.write("seed", to: root + "/vault/seed.md")
        service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        try await service.addRoot(path: root + "/vault")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root!)
    }

    private func waitUntilClean(_ repo: String, timeout: Double = 10) async {
        var waited = 0.0
        while waited < timeout {
            if ((try? await service.repoManager.status(path: repo).count) ?? 1) == 0 { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
    }

    func testRelocateKeepsHistoryPauseAndWatcher() async throws {
        let oldPath = root + "/vault"
        await waitUntilClean(oldPath)
        let commitsBefore = (try? await service.repoManager.log(path: oldPath, max: 20).count) ?? 0
        XCTAssertGreaterThan(commitsBefore, 0)
        await service.setRootPaused(true, root: oldPath)

        let newPath = root + "/vault-moved"
        try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
        try await service.relocateRoot(from: oldPath, to: newPath)

        let cfg = service.configStore.load()
        XCTAssertEqual(cfg.roots.map { $0.path }, [newPath], "config points at the new location")
        XCTAssertTrue(cfg.roots[0].paused, "the paused state is preserved")
        XCTAssertTrue(service.pause.isPaused(root: newPath))
        XCTAssertNil(service.watchers[oldPath], "the old watcher is gone")
        XCTAssertNotNil(service.watchers[newPath], "the new location is watched")
        let commitsAfter = (try? await service.repoManager.log(path: newPath, max: 20).count) ?? 0
        XCTAssertEqual(commitsAfter, commitsBefore, "history moved with the folder")
        let files = await service.repoManager.listFiles(path: newPath)
        XCTAssertTrue(files.contains("seed.md"))
    }

    func testRelocateRejectsAnAlreadyManagedTarget() async throws {
        try? FileManager.default.createDirectory(atPath: root + "/vault2", withIntermediateDirectories: true)
        TestSupport.write("other", to: root + "/vault2/other.md")
        try await service.addRoot(path: root + "/vault2")
        do {
            try await service.relocateRoot(from: root + "/vault", to: root + "/vault2")
            XCTFail("relocating onto an already managed folder must fail")
        } catch let error as FileVaultServiceError {
            guard case .rootAlreadyManaged = error else { return XCTFail("got \(error)") }
        }
        let cfg = service.configStore.load()
        XCTAssertEqual(Set(cfg.roots.map { $0.path }), Set([root + "/vault", root + "/vault2"]))
        XCTAssertNotNil(service.watchers[root + "/vault"])
    }
}
