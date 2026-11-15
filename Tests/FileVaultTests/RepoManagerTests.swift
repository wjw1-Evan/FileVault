import XCTest
@testable import FileVaultCore

/// v4.0: the protected root folder IS the one repository. These tests cover
/// creation, adoption and the "everything under the root is versioned" rule.
final class RepoManagerTests: XCTestCase {
    var root: String!
    var repo: String!
    var repos: RepoManager!

    override func setUp() {
        root = TestSupport.makeTempDir("reproot")
        repo = root + "/repo"
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        TestSupport.write("hello", to: repo + "/note.md")
        repos = RepoManager(runner: TestSupport.newRunner())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root!)
    }

    @discardableResult
    private func git(_ args: [String]) async throws -> GitResult {
        try await repos.runner.run(args, cwd: repo)
    }

    func testIsRepoDetectsGitEntry() async throws {
        XCTAssertFalse(repos.isRepo(at: repo), "no .git before setup")
        _ = try await repos.ensureRepo(at: repo)
        XCTAssertTrue(repos.isRepo(at: repo))
        let plain = root + "/not-a-repo"
        try? FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        XCTAssertFalse(repos.isRepo(at: plain))
    }

    func testEnsureRepoCreatesOneRepoAtRoot() async throws {
        let result = try await repos.ensureRepo(at: repo)
        XCTAssertTrue(result.created, "fresh folder -> repo created")
        XCTAssertFalse(result.adopted, "nothing to adopt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/.git"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/.gitignore"),
                      "template .gitignore injected into a new repo")
        let log = try await repos.log(path: repo)
        XCTAssertEqual(log.count, 1, "pre-existing content is captured in the initial commit")
    }

    func testEnsureRepoIsIdempotentForAnExistingRootRepo() async throws {
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("later", to: repo + "/later.md")
        let second = try await repos.ensureRepo(at: repo)
        XCTAssertFalse(second.created)
        XCTAssertTrue(second.adopted)
        let log = try await repos.log(path: repo)
        XCTAssertEqual(log.count, 1, "re-running never creates new history")
    }

    func testEnsureRepoAdoptsExistingRootRepoUntouched() async throws {
        // An existing repository the user made with their own tooling.
        try await git(["init", "-b", "main"])
        try await git(["config", "user.name", "Manual"])
        try await git(["config", "user.email", "manual@example.com"])
        try await git(["add", "-A"])
        try await git(["commit", "-m", "manual seed"])
        let before = try await repos.log(path: repo)
        XCTAssertEqual(before.count, 1)

        let result = try await repos.ensureRepo(at: repo)
        XCTAssertTrue(result.adopted, "existing .git must be adopted")
        XCTAssertFalse(result.created, "an adopted repo is not created again")
        let after = try await repos.log(path: repo)
        XCTAssertEqual(after.count, 1, "adoption must not create a new history")
        XCTAssertEqual(after.first?.subject, "manual seed", "existing commit is untouched")
    }

    func testEnsureRepoVersionsEverythingUnderRoot() async throws {
        _ = try await repos.ensureRepo(at: repo)
        // Root-level loose file, a nested folder and a hidden folder.
        TestSupport.write("top", to: repo + "/loose.md")
        try? FileManager.default.createDirectory(atPath: repo + "/nested/deeper", withIntermediateDirectories: true)
        TestSupport.write("deep", to: repo + "/nested/deeper/deep.md")
        try? FileManager.default.createDirectory(atPath: repo + "/.hidden", withIntermediateDirectories: true)
        TestSupport.write("hidden", to: repo + "/.hidden/h.md")

        let hash = try await repos.commitAll(path: repo)
        XCTAssertFalse(hash.isEmpty)

        let tracked = await repos.listFiles(path: repo)
        XCTAssertTrue(tracked.contains("note.md"), "pre-existing file tracked: \(tracked)")
        XCTAssertTrue(tracked.contains("loose.md"), "root-level loose file tracked: \(tracked)")
        XCTAssertTrue(tracked.contains("nested/deeper/deep.md"), "nested file tracked: \(tracked)")
        XCTAssertTrue(tracked.contains(".hidden/h.md"), "hidden folder file tracked: \(tracked)")
        // One repo only: no nested repositories are created.
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/nested/.git"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/nested/deeper/.git"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/.hidden/.git"))
        XCTAssertFalse(repos.isRepo(at: repo + "/nested"))
    }

    func testCommitAllAndMessageFormat() async throws {
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("line1\nline2", to: repo + "/note.md")
        let hash = try await repos.commitAll(path: repo)
        XCTAssertFalse(hash.isEmpty)
        let log = try await repos.log(path: repo)
        XCTAssertEqual(log.count, 2)  // initial + note.md
        XCTAssertEqual(log.first?.subject, "auto: 1 处变更 (+2 -1)，修改 note.md")
    }

    func testRemoteConfigAndAutoPushFlag() async throws {
        _ = try await repos.ensureRepo(at: repo)
        let remote = root + "-remote.git"
        _ = try await repos.runner.run(["init", "--bare", remote])
        try await repos.setRemote(path: repo, url: remote)
        let url = await repos.remoteURL(path: repo)
        XCTAssertEqual(url, remote)
        let auto1 = await repos.autoPushEnabled(path: repo)
        XCTAssertFalse(auto1)
        await repos.setAutoPush(path: repo, enabled: true)
        let auto2 = await repos.autoPushEnabled(path: repo)
        XCTAssertTrue(auto2)
        try await repos.clearRemote(path: repo)
        let url2 = await repos.remoteURL(path: repo)
        XCTAssertNil(url2)
    }

    func testExcludeLargeFiles() async throws {
        _ = try await repos.ensureRepo(at: repo)
        let big = String(repeating: "A", count: 2 * 1024 * 1024)
        TestSupport.write(big, to: repo + "/big.bin")
        let excluded = await repos.excludeLargeFiles(path: repo, threshold: 1024 * 1024)
        XCTAssertEqual(excluded.count, 1)
        let excludeFile = try String(contentsOfFile: repo + "/.git/info/exclude", encoding: .utf8)
        XCTAssertTrue(excludeFile.contains("big.bin"))
    }
}
