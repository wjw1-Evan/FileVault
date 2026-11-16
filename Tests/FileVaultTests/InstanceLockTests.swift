import XCTest
@testable import FileVaultCore
#if canImport(Darwin)
import Darwin
#endif

/// v4.2.9: two copies of FileVault must never watch/commit the same folder.
/// A per-folder advisory lock keeps the first live instance in charge, while a
/// stale lock from a crashed run is taken over.
final class InstanceLockTests: XCTestCase {
    private func spawnSleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["10"]
        try p.run()
        return p
    }

    func testLiveForeignHolderBlocksAndStaleLockIsTakenOver() async throws {
        let dir = TestSupport.makeTempDir("instance")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        TestSupport.write("seed", to: dir + "/seed.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: dir)

        let sleeper = try spawnSleeper()
        let pid = sleeper.processIdentifier
        TestSupport.write(String(pid) + "\n", to: dir + "/.git/filevault-instance.pid")
        XCTAssertEqual(repos.foreignInstancePID(path: dir), pid)
        XCTAssertFalse(repos.acquireInstanceLock(path: dir), "a live foreign instance owns the folder")

        sleeper.terminate()
        sleeper.waitUntilExit()
        XCTAssertNil(repos.foreignInstancePID(path: dir))
        XCTAssertTrue(repos.acquireInstanceLock(path: dir), "the stale lock is taken over")
        let mine = (try? String(contentsOfFile: dir + "/.git/filevault-instance.pid", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(mine, String(getpid()))
        repos.releaseInstanceLock(path: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/.git/filevault-instance.pid"))
    }

    func testReleaseLeavesAForeignLockAlone() async throws {
        let dir = TestSupport.makeTempDir("instance-foreign")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        TestSupport.write("seed", to: dir + "/seed.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: dir)
        // PID 1 is alive and is not us.
        TestSupport.write("1\n", to: dir + "/.git/filevault-instance.pid")
        repos.releaseInstanceLock(path: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/.git/filevault-instance.pid"),
                      "another instance's lock must never be removed")
    }

    func testServiceSkipsFolderOwnedByAnotherInstanceAndRecovers() async throws {
        let base = TestSupport.makeTempDir("instance-svc")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let folder = base + "/vault"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        TestSupport.write("seed", to: folder + "/seed.md")
        let setup = RepoManager(runner: TestSupport.newRunner())
        _ = try await setup.ensureRepo(at: folder)

        let sleeper = try spawnSleeper()
        TestSupport.write(String(sleeper.processIdentifier) + "\n",
                          to: folder + "/.git/filevault-instance.pid")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        var cfg = service.configStore.load()
        cfg.roots = [ManagedRoot(path: folder)]
        service.configStore.save(cfg)
        try await service.start()
        XCTAssertNil(service.watchers[folder], "the second instance must not watch the folder")

        sleeper.terminate()
        sleeper.waitUntilExit()
        await service.sweepOnce()
        XCTAssertNotNil(service.watchers[folder],
                        "when the other instance exits, the sweep takes the folder over")
    }
}
