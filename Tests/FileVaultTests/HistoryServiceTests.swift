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
        _ = try await repos.ensureRepo(at: root + "/repo")
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

    /// v4.0: one root repo means a whole-root rollback reverts files from
    /// DIFFERENT subfolders in a single reset.
    func testWholeRootRollbackRevertsFilesInDifferentSubfolders() async throws {
        let repoPath = root + "/repo"
        _ = try await repos.ensureRepo(at: repoPath)
        try? FileManager.default.createDirectory(atPath: repoPath + "/a", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: repoPath + "/b", withIntermediateDirectories: true)
        TestSupport.write("one v1", to: repoPath + "/a/one.md")
        TestSupport.write("two v1", to: repoPath + "/b/two.md")
        _ = try await repos.commitAll(path: repoPath, message: "snapshot")
        let commits = try await history.commits(repoPath: repoPath)
        let snapshot = try XCTUnwrap(commits.first)

        TestSupport.write("one v2", to: repoPath + "/a/one.md")
        TestSupport.write("two v2", to: repoPath + "/b/two.md")
        _ = try await repos.commitAll(path: repoPath, message: "edit both")

        try await history.resetRepo(repoPath: repoPath, to: snapshot.hash)

        XCTAssertEqual(try String(contentsOfFile: repoPath + "/a/one.md", encoding: .utf8), "one v1",
                       "subfolder a must be rolled back")
        XCTAssertEqual(try String(contentsOfFile: repoPath + "/b/two.md", encoding: .utf8), "two v1",
                       "subfolder b must be rolled back by the SAME root rollback")
    }

    /// Regression (v2.6.2): git quotes non-ASCII paths as octal escapes by
    /// default; the runner must force `core.quotepath=false` so Chinese
    /// filenames come back as raw UTF-8 in history listings — and stay usable
    /// as arguments for show/restore.
    func testChineseFilenamesSurviveHistoryPipeline() async throws {
        let repoPath = root + "/repo"
        _ = try await repos.ensureRepo(at: repoPath)
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

/// v3.4.3 "open historical version" export path (released with v4.0.0).
final class HistoryExportTests: XCTestCase {
    func testExportFileWritesExactBinaryContent() async throws {
        let base = TestSupport.makeTempDir("export")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repo = base + "/repo"
        try? FileManager.default.createDirectory(atPath: repo + "/nested", withIntermediateDirectories: true)
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: repo)
        // Invalid UTF-8 bytes: export must be binary-safe (text capture would lose them).
        let bytes = Data([0x00, 0x01, 0x7f, 0x80, 0xff, 0x0a, 0x42])
        try bytes.write(to: URL(fileURLWithPath: repo + "/nested/blob.bin"))
        _ = try await repos.commitAll(path: repo)
        let commits = try await repos.log(path: repo)
        let hash = try XCTUnwrap(commits.first?.hash)

        let dest = URL(fileURLWithPath: base + "/out/nested/blob.bin")
        let history = HistoryService(repoManager: repos)
        try await history.exportFile(repoPath: repo, hash: hash, file: "nested/blob.bin", to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), bytes)
    }

    func testExportFileRejectsTraversalAndMissingFiles() async throws {
        let base = TestSupport.makeTempDir("exportbad")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repo = base + "/repo"
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("x", to: repo + "/x.md")
        _ = try await repos.commitAll(path: repo)
        let commits = try await repos.log(path: repo)
        let hash = try XCTUnwrap(commits.first?.hash)
        let history = HistoryService(repoManager: repos)
        let dest = URL(fileURLWithPath: base + "/out.bin")

        do {
            try await history.exportFile(repoPath: repo, hash: hash, file: "../escape.md", to: dest)
            XCTFail("path traversal must be rejected")
        } catch {
            XCTAssertTrue(error is HistoryError, "got \(error)")
        }

        do {
            try await history.exportFile(repoPath: repo, hash: hash, file: "missing.md", to: dest)
            XCTFail("missing file must not export")
        } catch {
            XCTAssertTrue(error is HistoryError, "got \(error)")
        }
    }
}
