import XCTest
@testable import FileVaultCore

/// v4.0.4 "full file tree": the commit snapshot listing plus its hierarchy.
final class HistoryTreeTests: XCTestCase {
    private func entry(_ path: String, mode: String = "100644") -> CommitTreeEntry {
        CommitTreeEntry(path: path, mode: mode)
    }

    // MARK: - Tree building

    func testBuildNestsFoldersAndSortsFoldersFirst() {
        let tree = HistoryTree.build(entries: [
            entry("b.md"),
            entry("a/z.md"),
            entry("a/y.md"),
            entry("docs/01.md"),
            entry("docs/img/x.png"),
        ])
        XCTAssertEqual(tree.map(\.name), ["a", "docs", "b.md"])
        XCTAssertEqual(tree[0].fileCount, 2)
        XCTAssertEqual(tree[0].children.map(\.name), ["y.md", "z.md"])
        XCTAssertEqual(tree[1].fileCount, 2)
        XCTAssertEqual(tree[1].children.map(\.name), ["img", "01.md"])  // folder first
        XCTAssertEqual(tree[1].children[0].children.map(\.path), ["docs/img/x.png"])
        XCTAssertEqual(tree[2].kind, .file)
    }

    func testBuildOfEmptyListIsEmpty() {
        XCTAssertTrue(HistoryTree.build(entries: []).isEmpty)
    }

    func testBuildNaturalSortsNumbers() {
        let tree = HistoryTree.build(entries: (1...12).map { entry("chapter-\($0).md") })
        XCTAssertEqual(tree.map(\.name), (1...12).map { "chapter-\($0).md" })
    }

    func testFlattenHonorsExpandedFolders() {
        let tree = HistoryTree.build(entries: [
            entry("a/z.md"), entry("a/y.md"), entry("b.md"),
        ])
        XCTAssertEqual(HistoryTree.flatten(tree, expanded: []).map(\.node.path), ["a", "b.md"])

        let rows = HistoryTree.flatten(tree, expanded: ["a"])
        XCTAssertEqual(rows.map(\.node.path), ["a", "a/y.md", "a/z.md", "b.md"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 0])
    }

    func testAllDirectoryPaths() {
        let tree = HistoryTree.build(entries: [
            entry("docs/img/x.png"), entry("docs/01.md"), entry("a.md"),
        ])
        XCTAssertEqual(HistoryTree.allDirectoryPaths(tree), ["docs", "docs/img"])
    }

    func testAncestorDirectories() {
        XCTAssertEqual(HistoryTree.ancestorDirectories(of: "docs/img/x.png"), ["docs", "docs/img"])
        XCTAssertEqual(HistoryTree.ancestorDirectories(of: "a.md"), [])
    }

    func testEntryKindDerivesFromMode() {
        XCTAssertEqual(entry("f", mode: "100644").kind, .file)
        XCTAssertEqual(entry("f", mode: "100755").kind, .file)
        XCTAssertEqual(entry("l", mode: "120000").kind, .symlink)
        XCTAssertEqual(entry("s", mode: "160000").kind, .submodule)
    }

    func testNodeIdsDistinguishFoldersAndFiles() {
        let tree = HistoryTree.build(entries: [entry("docs/01.md")])
        XCTAssertEqual(tree[0].id, "d:docs")
        XCTAssertEqual(tree[0].children[0].id, "f:docs/01.md")
    }
}

/// Real-git coverage for HistoryService.filesAtCommit.
final class CommitFileListTests: XCTestCase {
    var root: String!
    var repos: RepoManager!
    var history: HistoryService!

    override func setUp() {
        root = TestSupport.makeTempDir("committree")
        try? FileManager.default.createDirectory(atPath: root + "/repo", withIntermediateDirectories: true)
        repos = RepoManager(runner: TestSupport.newRunner())
        history = HistoryService(repoManager: repos)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root!)
    }

    private func headHash(_ repo: String) async throws -> String {
        let commits = try await history.commits(repoPath: repo)
        return try XCTUnwrap(commits.first?.hash)
    }

    func testListsFilesTheCommitDidNotTouch() async throws {
        let repo = root + "/repo"
        try? FileManager.default.createDirectory(atPath: repo + "/docs", withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("a1", to: repo + "/docs/a.md")
        TestSupport.write("b1", to: repo + "/docs/b.md")
        _ = try await repos.commitAll(path: repo)

        TestSupport.write("a2", to: repo + "/docs/a.md")
        _ = try await repos.commitAll(path: repo)
        let head = try await headHash(repo)

        // The commit only touched a.md ...
        let changed = try await history.changedFiles(repoPath: repo, hash: head)
        XCTAssertEqual(changed, ["M\tdocs/a.md"])
        // ... but the complete snapshot still contains the untouched b.md.
        let list = try await history.filesAtCommit(repoPath: repo, hash: head)
        // .gitignore is injected by ensureRepo, so the snapshot has three files.
        XCTAssertEqual(Set(list.entries.map(\.path)), ["docs/a.md", "docs/b.md", ".gitignore"])
        XCTAssertTrue(list.entries.allSatisfy { $0.mode == "100644" })
        XCTAssertFalse(list.truncated)
        // And the untouched file is readable through the same path.
        let untouched = try await history.fileContent(repoPath: repo, hash: head, file: "docs/b.md")
        XCTAssertEqual(untouched, "b1")
    }

    func testKeepsChineseAndSpacedFilenamesIntact() async throws {
        let repo = root + "/repo"
        _ = try await repos.ensureRepo(at: repo)
        try? FileManager.default.createDirectory(atPath: repo + "/笔记", withIntermediateDirectories: true)
        TestSupport.write("会议 v1", to: repo + "/笔记/会议 记录.md")
        _ = try await repos.commitAll(path: repo)
        let hash = try await headHash(repo)

        let list = try await history.filesAtCommit(repoPath: repo, hash: hash)
        XCTAssertEqual(Set(list.entries.map(\.path)), ["笔记/会议 记录.md", ".gitignore"])
        let content = try await history.fileContent(repoPath: repo, hash: hash, file: "笔记/会议 记录.md")
        XCTAssertEqual(content, "会议 v1")
    }

    func testHidesEmptyFolderMarker() async throws {
        let repo = root + "/repo"
        _ = try await repos.ensureRepo(at: repo)
        try? FileManager.default.createDirectory(atPath: repo + "/空文件夹", withIntermediateDirectories: true)
        TestSupport.write("", to: repo + "/空文件夹/.gitkeep")
        TestSupport.write("x", to: repo + "/x.md")
        _ = try await repos.commitAll(path: repo)
        let hash = try await headHash(repo)

        let list = try await history.filesAtCommit(repoPath: repo, hash: hash)
        XCTAssertEqual(Set(list.entries.map(\.path)), ["x.md", ".gitignore"])
    }

    func testDetectsSymlinkMode() async throws {
        let repo = root + "/repo"
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("target", to: repo + "/target.md")
        try FileManager.default.createSymbolicLink(atPath: repo + "/link.md", withDestinationPath: "target.md")
        _ = try await repos.commitAll(path: repo)
        let hash = try await headHash(repo)

        let list = try await history.filesAtCommit(repoPath: repo, hash: hash)
        let link = try XCTUnwrap(list.entries.first { $0.path == "link.md" })
        XCTAssertEqual(link.kind, .symlink)
    }

    func testTruncatesAtLimit() async throws {
        let repo = root + "/repo"
        _ = try await repos.ensureRepo(at: repo)
        for i in 1...3 { TestSupport.write("v\(i)", to: repo + "/f\(i).md") }
        _ = try await repos.commitAll(path: repo)
        let hash = try await headHash(repo)

        let list = try await history.filesAtCommit(repoPath: repo, hash: hash, limit: 2)
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list.truncated)
    }

    func testRejectsBadOrUnknownHash() async throws {
        let repo = root + "/repo"
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("x", to: repo + "/x.md")
        _ = try await repos.commitAll(path: repo)

        do {
            _ = try await history.filesAtCommit(repoPath: repo, hash: "not-a-hash")
            XCTFail("invalid hash must be rejected")
        } catch let error as HistoryError {
            XCTAssertEqual(error, .commitNotFound("not-a-hash"))
        }
        do {
            _ = try await history.filesAtCommit(repoPath: repo, hash: String(repeating: "a", count: 40))
            XCTFail("unknown commit must be rejected")
        } catch let error as HistoryError {
            guard case .commitNotFound = error else { return XCTFail("unexpected: \(error)") }
        }
    }
}
