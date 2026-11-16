import XCTest
@testable import FileVaultCore

/// v4.2.12: a corrupt config.json must not silently wipe the protected-folder
/// list from the UI — the last good backup is used, the corrupt file is kept
/// for forensics, and the user is told what happened.
final class ConfigBackupRecoveryTests: XCTestCase {
    private func tempDir() -> String { TestSupport.makeTempDir("cfgrec") }

    func testBackupRecoversPreviousGoodConfig() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir)
        let store = ConfigStore(directory: url)
        let a = AppConfig(roots: [ManagedRoot(path: dir + "/A")])
        let b = AppConfig(roots: [ManagedRoot(path: dir + "/B")])
        store.save(a)
        store.save(b)   // the backup now holds the previous good config (a)

        let backupURL = url.appendingPathComponent(ConfigStore.backupFileName)
        let backup = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: backupURL))
        XCTAssertEqual(backup.roots.map { $0.path }, [ManagedRoot(path: dir + "/A").path])

        // Corrupt the primary: a fresh store must recover the backup.
        try Data("{not json".utf8).write(to: url.appendingPathComponent("config.json"))
        let recovered = ConfigStore(directory: url)
        let cfg = recovered.load()
        XCTAssertEqual(cfg.roots.map { $0.path }, [ManagedRoot(path: dir + "/A").path])
        XCTAssertEqual(recovered.lastLoadIssue, .recoveredFromBackup)

        // The next save rewrites a valid config and keeps the corrupt file aside.
        recovered.save(b)
        let fresh = ConfigStore(directory: url)
        XCTAssertEqual(fresh.load().roots.map { $0.path }, [ManagedRoot(path: dir + "/B").path])
        XCTAssertNil(fresh.lastLoadIssue)
        let corrupt = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasPrefix("config.corrupt-") }
        XCTAssertFalse(corrupt.isEmpty, "the corrupt file is kept for forensics")
    }

    func testBothFilesCorruptStartsWithIssue() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: url.appendingPathComponent("config.json"))
        try Data("garbage".utf8).write(to: url.appendingPathComponent(ConfigStore.backupFileName))
        let store = ConfigStore(directory: url)
        XCTAssertTrue(store.load().roots.isEmpty)
        XCTAssertEqual(store.lastLoadIssue, .unreadable)
    }

    func testFreshInstallHasNoIssue() {
        let store = ConfigStore(directory: URL(fileURLWithPath: tempDir()))
        XCTAssertTrue(store.load().roots.isEmpty)
        XCTAssertNil(store.lastLoadIssue)
    }

    func testServiceNotifiesWhenConfigRecoveredFromBackup() async throws {
        let base = tempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let folder = base + "/vault"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        TestSupport.write("seed", to: folder + "/seed.md")
        let cfgURL = URL(fileURLWithPath: base + "/cfg")
        let store = ConfigStore(directory: cfgURL)
        let cfg = AppConfig(roots: [ManagedRoot(path: folder)])
        store.save(cfg)
        store.save(cfg)   // create the backup
        try Data("garbage".utf8).write(to: cfgURL.appendingPathComponent("config.json"))

        let service = FileVaultService(configDirectory: cfgURL)
        var messages: [String] = []
        let lock = NSLock()
        service.onFailure.handler = { title, body in
            lock.lock(); messages.append(title + "|" + body); lock.unlock()
        }
        try await service.start()
        lock.lock(); let seen = messages; lock.unlock()
        XCTAssertTrue(seen.contains { $0.contains("备份恢复") },
                      "recovering from a corrupt config must be announced: " + seen.joined(separator: " || "))
        XCTAssertNotNil(service.watchers[folder], "the recovered folder list is used")
    }
}
