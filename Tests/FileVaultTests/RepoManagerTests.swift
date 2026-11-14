import XCTest
@testable import FileVaultCore

final class RepoManagerTests: XCTestCase {
    var root: String!
    var repos: RepoManager!

    override func setUp() {
        root = TestSupport.makeTempDir("reproot")
        try? FileManager.default.createDirectory(atPath: root + "/alpha", withIntermediateDirectories: true)
        TestSupport.write("hello", to: root + "/alpha/note.md")
        try? FileManager.default.createDirectory(atPath: root + "/beta", withIntermediateDirectories: true)
        TestSupport.write("x", to: root + "/beta/b.txt")
        repos = RepoManager(runner: TestSupport.newRunner())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root!)
    }

    func testFirstLevelFoldersSkipsHidden() {
        try? FileManager.default.createDirectory(atPath: root + "/.hidden", withIntermediateDirectories: true)
        let folders = repos.firstLevelFolders(root: root)
        let names = folders.map(\.name)
        XCTAssertTrue(names.contains("alpha"))
        XCTAssertTrue(names.contains("beta"))
        XCTAssertFalse(names.contains(".hidden"))
    }

    func testEnsureReposInitsAndAdopts() async throws {
        // Pre-create an existing repo in gamma (to be adopted).
        try? FileManager.default.createDirectory(atPath: root + "/gamma", withIntermediateDirectories: true)
        _ = try await repos.runner.run(["init", "-b", "main"], cwd: root + "/gamma")
        let result = try await repos.ensureRepos(root: root)
        XCTAssertTrue(result.created.contains("alpha"))
        XCTAssertTrue(result.created.contains("beta"))
        XCTAssertTrue(result.adopted.contains("gamma"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/alpha/.git"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/gamma/.git"))
        // Hidden folders are never touched (no .git inside).
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.hidden/.git"))
    }

    func testCommitAllAndMessageFormat() async throws {
        _ = try await repos.ensureRepos(root: root)
        TestSupport.write("line1\nline2", to: root + "/alpha/note.md")
        let hash = try await repos.commitAll(path: root + "/alpha")
        XCTAssertFalse(hash.isEmpty)
        let log = try await repos.log(path: root + "/alpha")
        XCTAssertEqual(log.count, 2)  // initial + note.md
        XCTAssertEqual(log.first?.subject, "auto: 1 处变更 (+2 -1)，修改 note.md")
    }


    func testRemoteConfigAndAutoPushFlag() async throws {
        let repo = root + "/alpha"
        _ = try await repos.ensureRepos(root: root)
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
        let repo = root + "/beta"
        _ = try await repos.ensureRepos(root: root)
        let big = String(repeating: "A", count: 2 * 1024 * 1024)
        TestSupport.write(big, to: repo + "/big.bin")
        let excluded = await repos.excludeLargeFiles(path: repo, threshold: 1024 * 1024)
        XCTAssertEqual(excluded.count, 1)
        let excludeFile = try String(contentsOfFile: repo + "/.git/info/exclude", encoding: .utf8)
        XCTAssertTrue(excludeFile.contains("big.bin"))
    }
}
