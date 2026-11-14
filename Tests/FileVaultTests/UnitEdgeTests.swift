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
