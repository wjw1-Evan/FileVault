import XCTest
@testable import FileVaultCore

final class HistoryServiceTests: XCTestCase {
    var root: String!
    var repos: RepoManager!
    var history: HistoryService!

    override func setUp() {
        root = TestSupport.makeTempDir("histroot")
        try? FileManager.default.createDirectory(atPath: root + "/repo", withIntermediateDirectories: true)
        TestSupport.write("seed", to: root + "/repo/seed.txt")
        repos = RepoManager(runner: TestSupport.newRunner())
        history = HistoryService(repoManager: repos)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root!)
    }

    private func prepare() async throws {
        _ = try await repos.ensureRepos(root: root)
        TestSupport.write("v1", to: root + "/repo/f.md")
        _ = try await repos.commitAll(path: root + "/repo")
        TestSupport.write("v2", to: root + "/repo/f.md")
        _ = try await repos.commitAll(path: root + "/repo")
    }

    func testLogAndFileContent() async throws {
        try await prepare()
        let commits = try await history.commits(repoPath: root + "/repo")
        XCTAssertEqual(commits.count, 3)  // seed initial + v1 + v2
        let v2Content = try await history.fileContent(repoPath: root + "/repo", hash: commits[0].hash, file: "f.md")
        XCTAssertEqual(v2Content, "v2")
        let v1Content = try await history.fileContent(repoPath: root + "/repo", hash: commits[1].hash, file: "f.md")
        XCTAssertEqual(v1Content, "v1")
    }

    func testRestoreFile() async throws {
        try await prepare()
        let commits = try await history.commits(repoPath: root + "/repo")
        let v1Commit = commits[1]
        _ = try await history.restoreFile(repoPath: root + "/repo", file: "f.md", to: v1Commit.hash)
        let content = try String(contentsOfFile: root + "/repo/f.md", encoding: .utf8)
        XCTAssertEqual(content, "v1")
    }

    func testResetRepo() async throws {
        try await prepare()
        let commits = try await history.commits(repoPath: root + "/repo")
        let v1Commit = commits[1]
        try await history.resetRepo(repoPath: root + "/repo", to: v1Commit.hash)
        let content = try String(contentsOfFile: root + "/repo/f.md", encoding: .utf8)
        XCTAssertEqual(content, "v1")
    }

    /// Regression (v2.6.2): git quotes non-ASCII paths as octal escapes by
    /// default; the runner must force `core.quotepath=false` so Chinese
    /// filenames come back as raw UTF-8 in history listings — and stay usable
    /// as arguments for show/restore.
    func testChineseFilenamesSurviveHistoryPipeline() async throws {
        try await repos.ensureRepos(root: root)
        let repoPath = root + "/repo"
        try FileManager.default.createDirectory(atPath: repoPath + "/笔记", withIntermediateDirectories: true)
        TestSupport.write("会议内容 v1", to: repoPath + "/笔记/会议记录.md")
        _ = try await repos.commitAll(path: repoPath)
        TestSupport.write("会议内容 v2", to: repoPath + "/笔记/会议记录.md")
        _ = try await repos.commitAll(path: repoPath)

        let commits = try await history.commits(repoPath: repoPath)
        let changed = try await history.changedFiles(repoPath: repoPath, hash: commits[0].hash)
        // Raw UTF-8, no octal escapes / surrounding quotes.
        XCTAssertEqual(changed.first, "M\t笔记/会议记录.md")
        // The decoded path must be directly usable for content reads.
        let path = String(changed.first!.split(separator: "\t")[1])
        let content = try await history.fileContent(repoPath: repoPath, hash: commits[0].hash, file: path)
        XCTAssertEqual(content, "会议内容 v2")
    }
}
