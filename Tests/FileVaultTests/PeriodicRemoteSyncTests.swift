import XCTest
@testable import FileVaultCore

/// v4.2.17: the safety sweep also performs a periodic remote sync, so changes
/// pushed from another machine reach the local folder with no user action —
/// including at startup (the first sweep runs immediately).
final class PeriodicRemoteSyncTests: XCTestCase {
    func testSweepPullsRemoteChangesIntoTheFolder() async throws {
        let base = TestSupport.makeTempDir("periodic-svc")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let folder = base + "/vault"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        TestSupport.write("seed", to: folder + "/seed.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: folder)

        let remote = base + "/remote.git"
        _ = try? await service.repoManager.runner.run(["init", "--bare", remote], cwd: base)
        try await service.sync.configureRemote(repoPath: folder, url: remote, autoPush: true)
        var waited = 0.0
        while waited < 10 {
            if await service.sync.status(for: folder) == .synced { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }

        // Another machine pushes a new file.
        let other = base + "/other"
        _ = try await service.repoManager.runner.run(["clone", remote, other], cwd: base)
        TestSupport.write("from other", to: other + "/other.md")
        _ = try await service.repoManager.runner.run(["add", "-A"], cwd: other)
        _ = try await service.repoManager.runner.run(["-c", "user.name=Other", "-c", "user.email=o@x",
                                                       "commit", "-m", "other change"], cwd: other)
        let pushed = try await service.repoManager.runner.run(["push"], cwd: other)
        XCTAssertTrue(pushed.succeeded, pushed.stderr)

        await service.sweepOnce()
        var found = false
        waited = 0.0
        while waited < 10 {
            if FileManager.default.fileExists(atPath: folder + "/other.md") { found = true; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        XCTAssertTrue(found, "the periodic sweep must pull the remote change into the folder")
    }
}
