import XCTest
@testable import FileVaultCore

/// Table-driven porcelain XY parsing (regression for the " D" deletion bug).
final class PorcelainParsingTests: XCTestCase {
    func testChangeFromXY() {
        let cases: [(String, StatusEntry.Change)] = [
            ("??", .added), ("A ", .added), ("AM", .modified),
            ("M ", .modified), (" M", .modified), ("T ", .typeChanged),
            ("D ", .deleted), (" D", .deleted), ("RM", .renamed),
            ("R ", .renamed), ("UU", .modified), ("AA", .added),
        ]
        for (xy, expected) in cases {
            XCTAssertEqual(RepoManager.change(fromXY: xy), expected, "XY=\(xy)")
        }
    }
}

/// Commit message builder edges (FR-05).
final class CommitMessageTests: XCTestCase {
    private func entry(_ c: StatusEntry.Change, _ name: String) -> StatusEntry {
        StatusEntry(change: c, path: name)
    }

    func testCapsFileListAtFive() {
        let entries = (1...8).map { entry(.added, "f\($0).md") }
        let msg = RepoManager.buildCommitMessage(entries: entries, additions: 10, deletions: 0)
        XCTAssertTrue(msg.hasPrefix("auto: 8 处变更 (+10 -0)"))
        XCTAssertEqual(msg.components(separatedBy: "、").count, 5, "should list at most 5 names")
        XCTAssertFalse(msg.contains("f8.md"))
    }

    func testFallbackWithoutGroups() {
        let msg = RepoManager.buildCommitMessage(entries: [], additions: 3, deletions: 4)
        XCTAssertEqual(msg, "auto: 0 处变更 (+3 -4)")
    }

    func testMixedGroups() {
        let entries = [entry(.added, "new.md"), entry(.deleted, "old.log"), entry(.modified, "edit.md")]
        let msg = RepoManager.buildCommitMessage(entries: entries, additions: 5, deletions: 2)
        XCTAssertTrue(msg.contains("新增 new.md"))
        XCTAssertTrue(msg.contains("修改 edit.md"))
        XCTAssertTrue(msg.contains("删除 old.log"))
    }
}

/// GitRunner timeout with a fake git that sleeps (real timeout verification).
final class GitTimeoutTests: XCTestCase {
    func testTimeoutActuallyFires() async {
        let dir = TestSupport.makeTempDir("fakegit")
        let script = dir + "/git"
        let body = "#!/bin/sh\nsleep 10\n"
        try? body.write(toFile: script, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let runner = GitRunner(gitExecutable: script, defaultTimeout: 0.5)
        do {
            _ = try await runner.run(["anything"], cwd: dir)
            XCTFail("should have timed out")
        } catch let e as GitCommandError {
            XCTAssertEqual(e.exitCode, -9)
            XCTAssertTrue(e.stderr.contains("timed out"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        try? FileManager.default.removeItem(atPath: dir)
    }
}

/// ConfigStore robustness: corrupted JSON must not crash and resets to empty.
final class ConfigRecoveryTests: XCTestCase {
    func testCorruptedConfigRecovers() {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("cfgbad"))
        try? "not-json{{{".write(toFile: dir.appendingPathComponent("config.json").path, atomically: true, encoding: .utf8)
        let store = ConfigStore(directory: dir)
        var cfg = store.load()
        XCTAssertEqual(cfg.roots.count, 0, "corrupt config degrades to empty")
        // And saving afterwards still works.
        cfg.roots.append(ManagedRoot(path: "/tmp/x"))
        store.save(cfg)
        XCTAssertEqual(ConfigStore(directory: dir).load().roots.count, 1)
        try? FileManager.default.removeItem(atPath: dir.path)
    }
}


/// v1.3.0 complete settings: general preferences persistence + runtime apply.
final class GeneralSettingsTests: XCTestCase {
    func testRoundtripAndBackwardCompat() {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("genset"))
        // 1. Old config WITHOUT a general key must decode with defaults.
        let legacy = Data(#"{"roots": [{"path": "/tmp/a"}]}"#.utf8)
        try? legacy.write(to: dir.appendingPathComponent("config.json"))
        let store1 = ConfigStore(directory: dir)
        let loaded = store1.load()
        XCTAssertEqual(loaded.general, .default, "missing general key decodes to defaults")
        // 2. Save -> load roundtrip.
        var cfg = loaded
        cfg.general.notificationsEnabled = false
        cfg.general.debounceSeconds = 10
        cfg.general.largeFileThresholdMB = 512
        store1.save(cfg)
        let again = ConfigStore(directory: dir).load()
        XCTAssertFalse(again.general.notificationsEnabled)
        XCTAssertEqual(again.general.debounceSeconds, 10)
        XCTAssertEqual(again.general.largeFileThresholdMB, 512)
        try? FileManager.default.removeItem(atPath: dir.path)
    }

    /// Debouncer quiet window must follow runtime changes.
    func testDebouncerDynamicInterval() {
        let exp = expectation(description: "fires after changed interval")
        let d = Debouncer(quietInterval: 30, maxWait: 60) { _ in exp.fulfill() }
        d.setQuietInterval(0.2)
        XCTAssertEqual(d.currentQuietInterval, 0.2)
        d.touch("dyn")
        wait(for: [exp], timeout: 2)
        d.cancelAll()
    }

    func testServiceApplyGeneral() async throws {
        let root = TestSupport.makeTempDir("svcgen")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        service.updateGeneral { $0.debounceSeconds = 30; $0.largeFileThresholdMB = 1 }
        XCTAssertEqual(service.debouncer?.currentQuietInterval, 30)
        XCTAssertEqual(service.commitEngine?.largeFileThreshold, 1 * 1024 * 1024)
        let persisted = service.configStore.load().general
        XCTAssertEqual(persisted.debounceSeconds, 30)
        try? FileManager.default.removeItem(atPath: root)
    }
}

/// ff-only pull (multi-machine sync entry).
final class PullTests: XCTestCase {
    var root: String!
    var repos: RepoManager!

    override func setUp() {
        root = TestSupport.makeTempDir("pull")
        try? FileManager.default.createDirectory(atPath: root + "/repo", withIntermediateDirectories: true)
        TestSupport.write("seed", to: root + "/repo/s.md")
        repos = RepoManager(runner: TestSupport.newRunner())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root!)
    }

    func testPullFailsGracefullyWithoutRemote() async throws {
        _ = try await repos.ensureRepos(root: root)
        do {
            _ = try await repos.pull(path: root + "/repo")
            XCTFail("pull without remote should throw")
        } catch {
            // expected
        }
    }

    func testPullAlreadyUpToDate() async throws {
        _ = try await repos.ensureRepos(root: root)
        let remote = root + "/r.git"
        _ = try await repos.runner.run(["init", "--bare", remote])
        try await repos.setRemote(path: root + "/repo", url: remote)
        TestSupport.write("v1", to: root + "/repo/s.md")
        _ = try await repos.commitAll(path: root + "/repo")
        try await repos.runner.run(["push", "-u", "origin", "HEAD"], cwd: root + "/repo")
        let out = try await repos.pull(path: root + "/repo")
        _ = out
        XCTAssertTrue(true, "ff-only pull on up-to-date repo succeeds")
    }
}
