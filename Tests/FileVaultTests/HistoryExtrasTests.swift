import XCTest
@testable import FileVaultCore

/// v4.0.5 extra history capabilities (diff, compare, blame, tags, backups,
/// export, fsck, folder restore, content search, submodule/LFS detection).
final class HistoryExtrasTests: XCTestCase {
    var root: String!
    var repo: String!
    var repos: RepoManager!
    var history: HistoryService!

    override func setUp() {
        root = TestSupport.makeTempDir("extras")
        repo = root + "/repo"
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        repos = RepoManager(runner: TestSupport.newRunner())
        history = HistoryService(repoManager: repos)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root!)
    }

    @discardableResult
    private func commit(_ message: String? = nil) async throws -> String {
        _ = try await repos.commitAll(path: repo, message: message)
        return try await repos.resolveHead(path: repo)
    }

    private func commits() async throws -> [CommitInfo] {
        try await history.commits(repoPath: repo, limit: 50)
    }

    func testDiffCountsAddedAndRemovedLines() async throws {
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("one\ntwo\n", to: repo + "/a.md")
        _ = try await commit("v1")
        TestSupport.write("one\nTWO\nthree\n", to: repo + "/a.md")
        let head = try await commit("v2")

        let diff = try await history.diff(repoPath: repo, hash: head, file: "a.md")
        XCTAssertFalse(diff.isBinary)
        XCTAssertFalse(diff.truncated)
        XCTAssertTrue(diff.text.contains("-two"))
        XCTAssertTrue(diff.text.contains("+TWO"))
        XCTAssertTrue(diff.text.contains("+three"))
        XCTAssertEqual(diff.added, 2)
        XCTAssertEqual(diff.removed, 1)
    }

    func testRootCommitDiffTreatsFileAsAdded() async throws {
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("alpha\nbeta\n", to: repo + "/first.md")
        let head = try await commit("initial")

        let diff = try await history.diff(repoPath: repo, hash: head, file: "first.md")
        XCTAssertEqual(diff.added, 2)
        XCTAssertEqual(diff.removed, 0)
        XCTAssertTrue(diff.text.contains("+alpha"))
    }

    func testDiffFlagsBinaryFiles() async throws {
        _ = try await repos.ensureRepo(at: repo)
        try Data([0x00, 0x01, 0xff, 0x42]).write(to: URL(fileURLWithPath: repo + "/blob.bin"))
        let head = try await commit("binary")
        let diff = try await history.diff(repoPath: repo, hash: head, file: "blob.bin")
        XCTAssertTrue(diff.isBinary)
        XCTAssertEqual(diff.added, 0)
    }

    func testChangeStatsMapsEveryChangedFile() async throws {
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("a\nb\nc\n", to: repo + "/keep.md")
        _ = try await commit("v1")
        TestSupport.write("a\nB\nc\nd\n", to: repo + "/keep.md")
        TestSupport.write("new\n", to: repo + "/new.md")
        let head = try await commit("v2")

        let stats = try await history.changeStats(repoPath: repo, hash: head)
        XCTAssertEqual(stats["keep.md"]?.added, 2)
        XCTAssertEqual(stats["keep.md"]?.removed, 1)
        XCTAssertEqual(stats["new.md"]?.added, 1)
    }

    func testCompareListsStatusAndCounts() async throws {
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("one\ntwo\n", to: repo + "/a.md")
        TestSupport.write("same\n", to: repo + "/b.md")
        let first = try await commit("v1")
        TestSupport.write("one\nTWO\n", to: repo + "/a.md")
        TestSupport.write("added\n", to: repo + "/c.md")
        let second = try await commit("v2")

        let files = try await history.compare(repoPath: repo, from: first, to: second)
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        XCTAssertEqual(byPath["a.md"]?.statusCharacter, "M")
        XCTAssertEqual(byPath["a.md"]?.added, 1)
        XCTAssertEqual(byPath["a.md"]?.removed, 1)
        XCTAssertEqual(byPath["c.md"]?.statusCharacter, "A")
        XCTAssertNil(byPath["b.md"])
    }

    func testBlameAttributesLinesToCommits() async throws {
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("first\nsecond\n", to: repo + "/f.md")
        let first = try await commit("v1")
        TestSupport.write("FIRST\nsecond\n", to: repo + "/f.md")
        let second = try await commit("v2")

        let lines = try await history.blame(repoPath: repo, hash: second, file: "f.md")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "FIRST")
        XCTAssertEqual(lines[0].hash, second)
        XCTAssertEqual(lines[1].text, "second")
        XCTAssertEqual(lines[1].hash, first)
        XCTAssertFalse(lines[0].author.isEmpty)
    }

    func testTagsListCreateAndDelete() async throws {
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("x\n", to: repo + "/x.md")
        let head = try await commit("v1")

        try await history.createTag(repoPath: repo, name: "v1.0", hash: head, message: "第一个版本")
        let tags = try await history.tags(repoPath: repo)
        XCTAssertEqual(tags.map(\.name), ["v1.0"])
        XCTAssertEqual(tags.first?.hash, head)
        XCTAssertEqual(tags.first?.subject, "第一个版本")
        XCTAssertNotNil(tags.first?.date)

        do {
            try await history.createTag(repoPath: repo, name: "bad name", hash: head)
            XCTFail("names with spaces must be rejected")
        } catch let error as HistoryError {
            guard case .invalidTagName = error else { return XCTFail("unexpected: \(error)") }
        }

        try await history.deleteTag(repoPath: repo, name: "v1.0")
        let after = try await history.tags(repoPath: repo)
        XCTAssertTrue(after.isEmpty)
    }

    func testBackupsListPreRollbackSnapshots() async throws {
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("v1\n", to: repo + "/a.md")
        let first = try await commit("v1")
        TestSupport.write("v2\n", to: repo + "/a.md")
        let second = try await commit("v2")

        try await history.resetRepo(repoPath: repo, to: first)
        let backups = try await history.backups(repoPath: repo)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(backups.first?.hash, second)
        XCTAssertFalse(backups.first?.stamp.isEmpty ?? true)
        XCTAssertNotNil(backups.first?.date)
    }

    func testExportSnapshotWritesZip() async throws {
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("content\n", to: repo + "/a.md")
        try? FileManager.default.createDirectory(atPath: repo + "/nested", withIntermediateDirectories: true)
        TestSupport.write("deep\n", to: repo + "/nested/b.md")
        let head = try await commit("v1")

        let dest = URL(fileURLWithPath: root + "/out/snapshot.zip")
        try await history.exportSnapshot(repoPath: repo, hash: head, to: dest)
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? UInt64) ?? 0
        XCTAssertGreaterThan(size, 100)
        let data = try Data(contentsOf: dest)
        // ZIP local file header magic.
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4b])
    }

    func testFsckReportsHealthyRepo() async throws {
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("x\n", to: repo + "/x.md")
        _ = try await commit("v1")
        let report = try await history.fsck(repoPath: repo)
        XCTAssertTrue(report.ok)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertTrue(report.summary.contains("完好"))
    }

    func testRestoreDirectoryRemovesNewFilesAndRestoresOldOnes() async throws {
        _ = try await repos.ensureRepo(at: repo)
        try? FileManager.default.createDirectory(atPath: repo + "/docs", withIntermediateDirectories: true)
        TestSupport.write("v1\n", to: repo + "/docs/a.md")
        let first = try await commit("v1")
        TestSupport.write("v2\n", to: repo + "/docs/a.md")
        TestSupport.write("extra\n", to: repo + "/docs/b.md")
        _ = try await commit("v2")

        _ = try await history.restoreDirectory(repoPath: repo, directory: "docs", to: first)
        XCTAssertEqual(try String(contentsOfFile: repo + "/docs/a.md", encoding: .utf8), "v1\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/docs/b.md"),
                       "file added after that version must be removed")
        let latest = try await commits()
        XCTAssertTrue(latest.first?.subject.contains("恢复文件夹 docs") ?? false)
    }

    func testRestoreDirectoryRemovesFolderThatDidNotExistYet() async throws {
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("seed\n", to: repo + "/seed.md")
        let before = try await commit("before docs")
        try? FileManager.default.createDirectory(atPath: repo + "/docs", withIntermediateDirectories: true)
        TestSupport.write("doc\n", to: repo + "/docs/a.md")
        _ = try await commit("add docs")

        _ = try await history.restoreDirectory(repoPath: repo, directory: "docs", to: before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/docs/a.md"))
        let status = try await repos.status(path: repo)
        XCTAssertFalse(status.contains { $0.path.hasPrefix("docs") })
    }

    func testSearchHistoryFindsCommitsByContent() async throws {
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("这里有 needle 关键字\n", to: repo + "/a.md")
        let withNeedle = try await commit("add needle")
        TestSupport.write("完全无关的内容\n", to: repo + "/b.md")
        _ = try await commit("unrelated")

        let hits = try await history.searchHistory(repoPath: repo, query: "needle")
        XCTAssertEqual(hits.map(\.hash), [withNeedle])
    }

    func testSubmoduleEntryIsNilForRegularFile() async throws {
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("x\n", to: repo + "/x.md")
        let head = try await commit("v1")
        let entry = try await history.submoduleEntry(repoPath: repo, hash: head, path: "x.md")
        XCTAssertNil(entry)
    }

    func testLFSPointerDetection() {
        let pointer = GitLFSPointer.header + "\noid sha256:abc\nsize 42\n"
        XCTAssertTrue(GitLFSPointer.isPointer(pointer))
        XCTAssertFalse(GitLFSPointer.isPointer("# ordinary markdown\n"))
    }
}
