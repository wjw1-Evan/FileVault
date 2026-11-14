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
        _ = try await repos.ensureRepos(root: root)
        TestSupport.write("v1", to: root + "/repo/s.md")
        _ = try await repos.commitAll(path: root + "/repo")
        let h = await repos.health(path: root + "/repo")
        XCTAssertGreaterThanOrEqual(h.commitCount, 2)
        XCTAssertGreaterThan(h.sizeBytes, 0)
        XCTAssertNotNil(h.lastCommitDate)
        XCTAssertFalse(h.summary.isEmpty)
    }

    func testMaintenanceGcInterval() async throws {
        _ = try await repos.ensureRepos(root: root)
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
        _ = try await repos.ensureRepos(root: root)
        let remote = root + "/r.git"
        _ = try await repos.runner.runSync(["init", "--bare", remote], cwd: root, timeout: 10)
        try await repos.setRemote(path: root + "/repo", url: remote)
        let r = await sync.testConnectivity(repoPath: root + "/repo")
        XCTAssertTrue(r.ok, r.detail)
    }

    func testMissingRemoteFails() async throws {
        _ = try await repos.ensureRepos(root: root)
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
        _ = try await repos.ensureRepos(root: root)
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
        _ = try await repos.ensureRepos(root: root)
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
