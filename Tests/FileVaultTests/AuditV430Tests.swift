import XCTest
@testable import FileVaultCore

/// v4.2.30 settings audit — core behaviour changes:
/// - `SyncManager.testRemote` probes the address in the field (not the
///   stored config) and carries a classified, readable failure line;
/// - `RepoHealth.readError` is readable copy with the exit code kept in
///   `readErrorExitCode` for diagnostics.
final class AuditV430Tests: XCTestCase {
    // MARK: - testRemote (settings "测试" now probes the field, not the config)

    func testRemoteProbesUnsavedAddressWithoutTouchingConfig() async throws {
        let base = TestSupport.makeTempDir("v429-remote-ok")
        defer { try? FileManager.default.removeItem(atPath: base) }
        try? FileManager.default.createDirectory(atPath: base + "/repo", withIntermediateDirectories: true)
        TestSupport.write("seed", to: base + "/repo/s.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        let sync = SyncManager(repoManager: repos)
        _ = try await repos.ensureRepo(at: base + "/repo")
        let bare = base + "/r.git"
        _ = try await repos.runner.runSync(["init", "--bare", bare], cwd: base, timeout: 10)
        // No setRemote anywhere: the whole point is probing an address that is
        // not stored yet.
        let r = await sync.testRemote(url: bare, repoPath: base + "/repo")
        XCTAssertTrue(r.ok, r.detail)
        // The probe must not silently persist anything.
        let stored = await repos.remoteURL(path: base + "/repo")
        XCTAssertNil(stored, "testRemote must not write the address into git config")
    }

    func testRemoteFailureIsClassifiedWithRawDetailIntact() async throws {
        let base = TestSupport.makeTempDir("v429-remote-bad")
        defer { try? FileManager.default.removeItem(atPath: base) }
        try? FileManager.default.createDirectory(atPath: base + "/repo", withIntermediateDirectories: true)
        TestSupport.write("seed", to: base + "/repo/s.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        let sync = SyncManager(repoManager: repos)
        _ = try await repos.ensureRepo(at: base + "/repo")
        let r = await sync.testRemote(url: base + "/absent.git", repoPath: base + "/repo")
        XCTAssertFalse(r.ok)
        // Primary line: the classified, readable reason.
        let summary = try XCTUnwrap(r.failureMessage, "classified failure expected, got: \(r.detail)")
        XCTAssertTrue(summary.contains("无法访问"), summary)
        // Secondary line: the condensed raw output — AuthMonitor matches
        // English phrases against `detail`, so it must stay untranslated.
        XCTAssertTrue(r.detail.contains("does not appear to be a git repository"), r.detail)
    }

    func testRemoteEmptyAddressFailsCleanly() async throws {
        let base = TestSupport.makeTempDir("v429-remote-empty")
        defer { try? FileManager.default.removeItem(atPath: base) }
        try? FileManager.default.createDirectory(atPath: base + "/repo", withIntermediateDirectories: true)
        TestSupport.write("seed", to: base + "/repo/s.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        let sync = SyncManager(repoManager: repos)
        _ = try await repos.ensureRepo(at: base + "/repo")
        let r = await sync.testRemote(url: "   ", repoPath: base + "/repo")
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.detail.contains("未配置"), r.detail)
        XCTAssertNil(r.failureMessage, "no git ran, so there is nothing classified to add")
    }

    func testConnectivityFailureNowLeadsWithClassifiedReason() async throws {
        // The saved-path probe (save-then-test) gets the same treatment.
        let base = TestSupport.makeTempDir("v429-conn-classify")
        defer { try? FileManager.default.removeItem(atPath: base) }
        try? FileManager.default.createDirectory(atPath: base + "/repo", withIntermediateDirectories: true)
        TestSupport.write("seed", to: base + "/repo/s.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        let sync = SyncManager(repoManager: repos)
        _ = try await repos.ensureRepo(at: base + "/repo")
        try await sync.configureRemote(repoPath: base + "/repo", url: base + "/absent.git", autoPush: true)
        let r = await sync.testConnectivity(repoPath: base + "/repo")
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.failureMessage?.contains("无法访问"), true, r.failureMessage ?? "")
        XCTAssertTrue(r.detail.contains("does not appear to be a git repository"), r.detail)
    }

    // MARK: - RepoHealth read errors (v4.2.30 audit item 5)

    func testHealthReportsReadableReadErrorWithExitCodeInDiagnostics() async throws {
        let base = TestSupport.makeTempDir("v429-health-broken")
        defer { try? FileManager.default.removeItem(atPath: base) }
        try? FileManager.default.createDirectory(atPath: base + "/repo", withIntermediateDirectories: true)
        TestSupport.write("seed", to: base + "/repo/s.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: base + "/repo")
        // Simulate a repo git can no longer read: HEAD is gone, .git still
        // exists (corrupt/truncated HEAD file, disk unavailable mid-read, …).
        try FileManager.default.removeItem(atPath: base + "/repo/.git/HEAD")
        let h = await repos.health(path: base + "/repo")
        XCTAssertNotNil(h.readError, "a failed rev-list must not look like an empty repo")
        XCTAssertTrue(h.readError?.contains("仓库暂时读不到") ?? false, h.readError ?? "")
        XCTAssertEqual(h.readErrorExitCode, 128, "the exit code is diagnostic data, not user copy")
        XCTAssertTrue(h.summary.contains("读取失败"), h.summary)
        XCTAssertTrue(h.summary.contains("仓库暂时读不到"), h.summary)
        XCTAssertFalse(h.summary.contains("128"), "exit codes must not be glued into the health line: \(h.summary)")
    }

    func testHealthOnIntactRepoHasNoReadError() async throws {
        let base = TestSupport.makeTempDir("v429-health-ok")
        defer { try? FileManager.default.removeItem(atPath: base) }
        try? FileManager.default.createDirectory(atPath: base + "/repo", withIntermediateDirectories: true)
        TestSupport.write("seed", to: base + "/repo/s.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: base + "/repo")
        let h = await repos.health(path: base + "/repo")
        XCTAssertNil(h.readError)
        XCTAssertNil(h.readErrorExitCode)
        XCTAssertFalse(h.summary.contains("读取失败"), h.summary)
        XCTAssertGreaterThanOrEqual(h.commitCount, 1)
    }
}
