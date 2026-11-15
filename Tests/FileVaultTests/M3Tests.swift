import XCTest
@testable import FileVaultCore

final class SshKeyCheckerTests: XCTestCase {
    func testDetectsPublicKey() {
        let dir = TestSupport.makeTempDir("ssh")
        TestSupport.write("ssh-ed25519 AAAA test@mac", to: dir + "/id_ed25519.pub")
        let checker = SshKeyChecker(sshDirectory: dir)
        XCTAssertTrue(checker.hasPublicKey)
        XCTAssertNil(checker.guidance)
        XCTAssertEqual(checker.publicKeys(), ["id_ed25519.pub"])
    }

    func testMissingKeyGuidance() {
        let dir = TestSupport.makeTempDir("ssh-empty")
        let checker = SshKeyChecker(sshDirectory: dir)
        XCTAssertFalse(checker.hasPublicKey)
        XCTAssertNotNil(checker.guidance)
    }
}

final class RepoHealthTests: XCTestCase {
    var root: String!
    var repos: RepoManager!

    override func setUp() {
        root = TestSupport.makeTempDir("health")
        try? FileManager.default.createDirectory(atPath: root + "/repo", withIntermediateDirectories: true)
        TestSupport.write("seed", to: root + "/repo/s.md")
        repos = RepoManager(runner: TestSupport.newRunner())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root!)
    }

    func testHealthCountsCommitsAndSize() async throws {
        _ = try await repos.ensureRepo(at: root + "/repo")
        TestSupport.write("v1", to: root + "/repo/s.md")
        _ = try await repos.commitAll(path: root + "/repo")
        let h = await repos.health(path: root + "/repo")
        XCTAssertGreaterThanOrEqual(h.commitCount, 2)
        XCTAssertGreaterThan(h.sizeBytes, 0)
        XCTAssertNotNil(h.lastCommitDate)
        XCTAssertFalse(h.summary.isEmpty)
    }

    func testMaintenanceGcInterval() async throws {
        _ = try await repos.ensureRepo(at: root + "/repo")
        let repo = root + "/repo"
        let ran1 = await repos.runMaintenanceIfNeeded(path: repo, interval: 7 * 24 * 3600)
        XCTAssertTrue(ran1, "first run should gc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/.git/filevault-last-gc"))
        let ran2 = await repos.runMaintenanceIfNeeded(path: repo, interval: 7 * 24 * 3600)
        XCTAssertFalse(ran2, "within interval should skip")
        let ran3 = await repos.runMaintenanceIfNeeded(path: repo, interval: -1)
        XCTAssertTrue(ran3, "negative interval forces gc")
    }
}

final class ConnectivityTests: XCTestCase {
    var root: String!
    var repos: RepoManager!
    var sync: SyncManager!

    override func setUp() {
        root = TestSupport.makeTempDir("conn")
        try? FileManager.default.createDirectory(atPath: root + "/repo", withIntermediateDirectories: true)
        TestSupport.write("seed", to: root + "/repo/s.md")
        repos = RepoManager(runner: TestSupport.newRunner())
        sync = SyncManager(repoManager: repos)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root!)
    }

    func testLocalRemoteReachable() async throws {
        _ = try await repos.ensureRepo(at: root + "/repo")
        let remote = root + "/r.git"
        _ = try await repos.runner.runSync(["init", "--bare", remote], cwd: root, timeout: 10)
        try await repos.setRemote(path: root + "/repo", url: remote)
        let r = await sync.testConnectivity(repoPath: root + "/repo")
        XCTAssertTrue(r.ok, r.detail)
    }

    func testMissingRemoteFails() async throws {
        _ = try await repos.ensureRepo(at: root + "/repo")
        // Product path: configureRemote with autoPush on, targeting a nonexistent remote.
        try await sync.configureRemote(repoPath: root + "/repo", url: root + "/absent.git", autoPush: true)
        let r = await sync.testConnectivity(repoPath: root + "/repo")
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.detail.isEmpty)
    }

    func testNoRemoteFails() async {
        let r = await sync.testConnectivity(repoPath: root + "/repo")
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.detail.contains("未配置"))
    }
}

final class GitignoreHelperTests: XCTestCase {
    func testReadAndSaveGitignore() async throws {
        let root = TestSupport.makeTempDir("gitignore")
        try? FileManager.default.createDirectory(atPath: root + "/repo", withIntermediateDirectories: true)
        TestSupport.write("seed", to: root + "/repo/s.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: root + "/repo")
        let repo = root + "/repo"
        let original = repos.gitignore(path: repo)
        XCTAssertTrue(original.contains(".DS_Store"), "template should be injected on init")
        repos.saveGitignore(path: repo, content: original + "\ncustom-*.log\n")
        let updated = repos.gitignore(path: repo)
        XCTAssertTrue(updated.contains("custom-*.log"))
        try? FileManager.default.removeItem(atPath: root)
    }
}

final class FailureCallbackTests: XCTestCase {
    /// FR-18 core chain: a failed push must fire onPushFailure (regression guard
    /// for the EventCallbackBox self-deadlock found by audit sampling).
    func testPushFailureFiresCallback() async throws {
        let root = TestSupport.makeTempDir("failcb")
        try? FileManager.default.createDirectory(atPath: root + "/repo", withIntermediateDirectories: true)
        TestSupport.write("seed", to: root + "/repo/s.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        let sync = SyncManager(repoManager: repos, backoffSchedule: [0.1], maxAttempts: 1)
        _ = try await repos.ensureRepo(at: root + "/repo")
        try await sync.configureRemote(repoPath: root + "/repo", url: root + "/absent.git", autoPush: true)
        let box = EventCallbackBox()
        var events: [String] = []
        let lock = NSLock()
        box.handler = { repo, reason in
            lock.lock(); events.append(repo + "|" + reason); lock.unlock()
        }
        sync.onPushFailure.handler = { a, b in box(a, b) }
        await sync.enqueuePush(repoPath: root + "/repo")
        // Wait for the failed push to fire the callback.
        var waited = 0.0
        while waited < 5 {
            lock.lock(); let n = events.count; lock.unlock()
            if n > 0 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        lock.lock(); let count = events.count; let first = events.first ?? ""; lock.unlock()
        let finalStatus = await sync.status(for: root + "/repo")
        XCTAssertEqual(finalStatus, .failed, "push to absent remote must end .failed")
        XCTAssertGreaterThanOrEqual(count, 1, "onPushFailure must fire on failed push")
        XCTAssertTrue(first.hasPrefix(root + "/repo|"), "event carries repoPath")
        try? FileManager.default.removeItem(atPath: root)
    }
}

final class StatusEventTests: XCTestCase {
    /// Event-driven refresh depends on status transitions emitting events.
    func testStatusChangeEventsFire() async throws {
        let root = TestSupport.makeTempDir("statev")
        try? FileManager.default.createDirectory(atPath: root + "/repo", withIntermediateDirectories: true)
        TestSupport.write("seed", to: root + "/repo/s.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        let sync = SyncManager(repoManager: repos, backoffSchedule: [0.1], maxAttempts: 1)
        _ = try await repos.ensureRepo(at: root + "/repo")
        let lock = NSLock()
        var events: [String] = []
        sync.onStatusChange.handler = { _, status in
            lock.lock(); events.append(status); lock.unlock()
        }
        try await sync.configureRemote(repoPath: root + "/repo", url: root + "/absent.git", autoPush: true)
        var waited = 0.0
        while waited < 6 {
            let st = await sync.status(for: root + "/repo")
            if st == .failed { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        lock.lock(); let evs = events; lock.unlock()
        XCTAssertTrue(evs.contains(SyncStatus.pendingPush.rawValue), "pendingPush event expected, got \(evs)")
        XCTAssertTrue(evs.contains(SyncStatus.failed.rawValue), "failed event expected, got \(evs)")
        try? FileManager.default.removeItem(atPath: root)
    }
}


/// v2.2.3 auth failure classification + periodic monitor with dedup/recovery.
final class AuthMonitorTests: XCTestCase {
    func testClassifierPatterns() {
        XCTAssertTrue(AuthClassifier.isAuthRelated("Authentication failed for 'https://...'"))
        XCTAssertTrue(AuthClassifier.isAuthRelated("fatal: could not read from remote repository"))
        XCTAssertTrue(AuthClassifier.isAuthRelated("The requested URL returned error: 403"))
        XCTAssertFalse(AuthClassifier.isAuthRelated("fatal: pathspec 'x' did not match"))
        XCTAssertFalse(AuthClassifier.isAuthRelated("Already up to date"))
    }

    /// Probe dedupes while a repo stays broken, resets on recovery, and
    /// re-alerts when it breaks again.
    func testMonitorDedupAndRecovery() async throws {
        let base = TestSupport.makeTempDir("authmon")
        try? FileManager.default.createDirectory(atPath: base + "/vault", withIntermediateDirectories: true)
        TestSupport.write("seed", to: base + "/vault/s.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        let sync = SyncManager(repoManager: repos)
        // v4.0: the managed root itself is the repo the monitor probes.
        _ = try await repos.ensureRepo(at: base + "/vault")
        let repo = base + "/vault"
        // Start with a BROKEN remote (nonexistent path -> fast failure).
        try await repos.setRemote(path: repo, url: base + "/absent.git")
        let monitor = AuthMonitor(repos: repos, sync: sync, interval: 3600)
        var issues: [String] = []
        let lock = NSLock()
        monitor.onAuthIssue.handler = { path, msg in
            lock.lock(); issues.append(path + "|" + msg); lock.unlock()
        }
        let roots: @Sendable () -> [String] = { [base + "/vault"] }
        await monitor.checkAll(rootsProvider: roots)
        lock.lock(); let first = issues.count; let firstMsg = issues.first ?? ""; lock.unlock()
        XCTAssertEqual(first, 1, "first probe alerts once; got: " + firstMsg)
        XCTAssertTrue(monitor.isAlerted(repoPath: repo))
        // Second pass while still broken: NO duplicate alert.
        await monitor.checkAll(rootsProvider: roots)
        lock.lock(); let second = issues.count; lock.unlock()
        XCTAssertEqual(second, 1, "dedup while unchanged")
        // Recovery: point at a valid bare repo.
        let bare = base + "/ok.git"
        _ = try await repos.runner.run(["init", "--bare", bare])
        try await repos.setRemote(path: repo, url: bare)
        await monitor.checkAll(rootsProvider: roots)
        XCTAssertFalse(monitor.isAlerted(repoPath: repo), "recovered repos reset the episode")
        // Break again -> alerts again (new episode).
        try await repos.setRemote(path: repo, url: base + "/absent2.git")
        await monitor.checkAll(rootsProvider: roots)
        lock.lock(); let third = issues.count; lock.unlock()
        XCTAssertEqual(third, 2, "new failure episode re-alerts")
        try? FileManager.default.removeItem(atPath: base)
    }
}
