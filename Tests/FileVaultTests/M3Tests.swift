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
        try await repos.setRemote(path: root + "/repo", url: root + "/absent.git")
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
