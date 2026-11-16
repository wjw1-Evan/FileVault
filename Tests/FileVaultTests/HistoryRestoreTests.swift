import XCTest
@testable import FileVaultCore

/// Comprehensive coverage of the history timeline + restore features
/// (FR-09/10): commit listing, file content, changed files, single-file
/// restore, whole-repo rollback and edge cases (v3.3.1).
final class HistoryRestoreTests: XCTestCase {
    var root: String!
    var repo: String!
    var repos: RepoManager!
    var history: HistoryService!
    var runner: GitRunner!

    override func setUp() async throws {
        root = TestSupport.makeTempDir("histfull")
        repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        runner = TestSupport.newRunner()
        repos = RepoManager(runner: runner)
        history = HistoryService(repoManager: repos)
        try await git(["init", "-b", "main"])
        try await git(["config", "user.name", "History Tester"])
        try await git(["config", "user.email", "history@example.com"])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root!)
    }


    /// v4.2.16: rolling a folder back to a version where it did not exist must
    /// not delete files that are not under version control (e.g. a .env).
    func testFolderRollbackRefusesToDeleteUntrackedFiles() async throws {
        try write(".env\n", to: ".gitignore")
        try write("root", to: "root.md")
        try await commitAll("v0 without proj")
        let v0 = try await head()
        try write("keep", to: "proj/keep.md")
        try await commitAll("v1 with proj")
        try FileManager.default.removeItem(atPath: repo + "/proj")
        try await commitAll("v2 without proj")

        // A new ignored file inside the recreated folder is NOT under git.
        try write("SECRET=1", to: "proj/.env")
        let dirty = try? await repos.status(path: repo)
        XCTAssertEqual(dirty?.count, 0, "the .env must stay ignored")

        do {
            _ = try await history.restoreDirectory(repoPath: repo, directory: "proj", to: v0)
            XCTFail("rollback must refuse to delete untracked files")
        } catch let error as HistoryError {
            guard case .rollbackWouldDeleteUntracked(let dir, let files) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(dir, "proj")
            XCTAssertTrue(files.contains("proj/.env"), "\(files)")
            XCTAssertTrue((error.errorDescription ?? "").contains("未纳入版本管理"), error.errorDescription ?? "")
        }
        XCTAssertEqual(read("proj/.env"), "SECRET=1", "the untracked file must not be deleted")
    }

    // MARK: - Helpers


    @discardableResult
    private func git(_ args: [String]) async throws -> GitResult {
        let r = try await runner.run(args, cwd: repo)
        XCTAssertTrue(r.succeeded, "\(args.joined(separator: " ")) failed: \(r.stderr)")
        return r
    }

    private func commitAll(_ message: String) async throws {
        _ = try await git(["add", "-A"])
        _ = try await git(["commit", "-m", message])
    }

    private func write(_ content: String, to relative: String) throws {
        let url = URL(fileURLWithPath: repo).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeBinary(_ bytes: [UInt8], to relative: String) throws {
        let url = URL(fileURLWithPath: repo).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    private func read(_ relative: String) -> String? {
        try? String(contentsOfFile: repo + "/" + relative, encoding: .utf8)
    }

    private func readBytes(_ relative: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: repo).appendingPathComponent(relative))
    }

    private func head() async throws -> String {
        let r = try await git(["rev-parse", "HEAD"])
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commits(limit: Int = 50) async throws -> [CommitInfo] {
        try await history.commits(repoPath: repo, limit: limit)
    }

    private func topCommit() async throws -> CommitInfo {
        let list = try await commits()
        return try XCTUnwrap(list.first)
    }

    /// v1 -> v2 history for a single file.
    private func makeTwoVersions(file: String = "f.md") async throws -> (v1: CommitInfo, v2: CommitInfo) {
        try write("v1", to: file)
        try await commitAll("initial")
        try write("v2", to: file)
        try await commitAll("second")
        let list = try await commits()
        XCTAssertEqual(list.count, 2)
        return (v1: list[1], v2: list[0])
    }

    // MARK: - commits()

    func testCommitsEmptyRepoReturnsEmptyList() async throws {
        let list = try await commits()
        XCTAssertTrue(list.isEmpty, "unborn HEAD must not throw or return junk")
    }

    func testCommitsAreNewestFirstAndRespectLimit() async throws {
        for i in 1...4 {
            try write("v\(i)", to: "f.md")
            try await commitAll("c\(i)")
        }
        let all = try await commits()
        XCTAssertEqual(all.map(\.subject), ["c4", "c3", "c2", "c1"])
        let limited = try await commits(limit: 2)
        XCTAssertEqual(limited.map(\.subject), ["c4", "c3"])
    }

    func testCommitFieldsAreParsed() async throws {
        try write("x", to: "f.md")
        try await commitAll("hello history")
        let headHash = try await head()
        let commit = try await topCommit()
        XCTAssertEqual(commit.hash, headHash)
        XCTAssertEqual(commit.shortHash, String(headHash.prefix(7)))
        XCTAssertEqual(commit.subject, "hello history")
        XCTAssertGreaterThan(commit.date.timeIntervalSince1970, 1_600_000_000)
    }

    // MARK: - fileContent()

    func testFileContentAtOldAndNewCommit() async throws {
        let versions = try await makeTwoVersions()
        let old = try await history.fileContent(repoPath: repo, hash: versions.v1.hash, file: "f.md")
        let new = try await history.fileContent(repoPath: repo, hash: versions.v2.hash, file: "f.md")
        XCTAssertEqual(old, "v1")
        XCTAssertEqual(new, "v2")
    }

    func testFileContentMissingFileThrows() async throws {
        _ = try await makeTwoVersions()
        let commit = try await topCommit()
        do {
            _ = try await history.fileContent(repoPath: repo, hash: commit.hash, file: "nope.md")
            XCTFail("expected failure for a file that never existed")
        } catch {
            XCTAssertNotNil(error as? GitCommandError)
        }
    }

    func testFileContentInvalidHashThrows() async throws {
        _ = try await makeTwoVersions()
        do {
            _ = try await history.fileContent(repoPath: repo, hash: "deadbeef", file: "f.md")
            XCTFail("expected failure for an unknown hash")
        } catch {
            XCTAssertNotNil(error as? GitCommandError)
        }
    }

    func testFileContentRejectsTraversalAndAbsolutePaths() async throws {
        _ = try await makeTwoVersions()
        let commit = try await topCommit()
        for bad in ["../escape.txt", "/etc/passwd", "a/../../b.txt", "./f.md"] {
            do {
                _ = try await history.fileContent(repoPath: repo, hash: commit.hash, file: bad)
                XCTFail("path must be rejected: \(bad)")
            } catch {
                XCTAssertEqual(error as? HistoryError, .invalidPath(bad))
            }
        }
    }

    func testFileContentSupportsNestedChineseAndSpacedPaths() async throws {
        let rel = "笔记/会议 记录 😀.md"
        try write("内容 v1", to: rel)
        try await commitAll("中文路径")
        let commit = try await topCommit()
        let content = try await history.fileContent(repoPath: repo, hash: commit.hash, file: rel)
        XCTAssertEqual(content, "内容 v1")
    }

    func testFileContentOfDeletedFileStillReadableAtOldCommit() async throws {
        try write("keep me", to: "gone.md")
        try await commitAll("add gone")
        let old = try await topCommit()
        try FileManager.default.removeItem(atPath: repo + "/gone.md")
        try await commitAll("delete gone")

        let content = try await history.fileContent(repoPath: repo, hash: old.hash, file: "gone.md")
        XCTAssertEqual(content, "keep me", "deleted files stay readable in their commits")
    }

    // MARK: - changedFiles()

    func testChangedFilesAddedModifiedDeleted() async throws {
        try write("a", to: "a.md")
        try write("b", to: "b.md")
        try await commitAll("add two")
        let addCommit = try await topCommit()
        let added = try await history.changedFiles(repoPath: repo, hash: addCommit.hash)
        XCTAssertEqual(Set(added), ["A\ta.md", "A\tb.md"])

        try write("a2", to: "a.md")
        try FileManager.default.removeItem(atPath: repo + "/b.md")
        try await commitAll("modify + delete")
        let changeCommit = try await topCommit()
        let changed = try await history.changedFiles(repoPath: repo, hash: changeCommit.hash)
        XCTAssertEqual(Set(changed), ["M\ta.md", "D\tb.md"])
    }

    func testChangedFilesRootCommitListsAddedFiles() async throws {
        try write("x", to: "dir/x.md")
        try await commitAll("root")
        let rootCommit = try await topCommit()
        let changed = try await history.changedFiles(repoPath: repo, hash: rootCommit.hash)
        XCTAssertEqual(changed, ["A\tdir/x.md"])
    }

    func testChangedFilesInvalidHashThrows() async throws {
        _ = try await makeTwoVersions()
        do {
            _ = try await history.changedFiles(repoPath: repo, hash: "not-a-hash")
            XCTFail("expected failure")
        } catch {
            XCTAssertNotNil(error as? GitCommandError)
        }
    }

    // MARK: - restoreFile()

    func testRestoreFileBringsBackOldContentAndCommitsRollback() async throws {
        let versions = try await makeTwoVersions()
        let hash = try await history.restoreFile(repoPath: repo, file: "f.md", to: versions.v1.hash)
        XCTAssertFalse(hash.isEmpty)
        XCTAssertEqual(try read("f.md"), "v1")

        let top = try await topCommit()
        XCTAssertTrue(top.subject.contains("restore"), "restore must be recorded: \(top.subject)")
        XCTAssertTrue(top.subject.contains("f.md"))
        XCTAssertTrue(top.subject.contains(String(versions.v1.hash.prefix(7))))
    }

    func testRestoreDeletedFileRecreatesIt() async throws {
        try write("precious", to: "gone.md")
        try await commitAll("add")
        let old = try await topCommit()
        try FileManager.default.removeItem(atPath: repo + "/gone.md")
        try await commitAll("delete")

        _ = try await history.restoreFile(repoPath: repo, file: "gone.md", to: old.hash)
        XCTAssertEqual(try read("gone.md"), "precious")
    }

    func testRestoringIdenticalContentCreatesNoCommit() async throws {
        let versions = try await makeTwoVersions()
        let before = try await commits().count
        let hash = try await history.restoreFile(repoPath: repo, file: "f.md", to: versions.v2.hash)
        XCTAssertTrue(hash.isEmpty, "nothing changed → no commit")
        let after = try await commits().count
        XCTAssertEqual(before, after)
    }

    func testRestoreFileMissingInTargetCommitThrowsAndChangesNothing() async throws {
        try write("v1", to: "f.md")
        try await commitAll("only f")
        let old = try await topCommit()
        try write("later", to: "later.md")
        try await commitAll("add later")
        let headBefore = try await head()

        do {
            _ = try await history.restoreFile(repoPath: repo, file: "later.md", to: old.hash)
            XCTFail("expected failure: later.md does not exist in the old commit")
        } catch {
            XCTAssertEqual(error as? HistoryError,
                           .fileNotInCommit(file: "later.md", hash: String(old.hash.prefix(7))))
        }
        let headAfter = try await head()
        XCTAssertEqual(headAfter, headBefore, "failed restore must not commit anything")
    }

    func testRestoreInvalidHashThrows() async throws {
        _ = try await makeTwoVersions()
        do {
            _ = try await history.restoreFile(repoPath: repo, file: "f.md", to: "0000000")
            XCTFail("expected failure for an unknown hash")
        } catch {
            XCTAssertEqual(error as? HistoryError, .fileNotInCommit(file: "f.md", hash: "0000000"))
        }
    }

    func testRestoreRejectsTraversalWithoutTouchingOutside() async throws {
        _ = try await makeTwoVersions()
        let commit = try await topCommit()
        let outside = root + "/outside.txt"
        for bad in ["../outside.txt", "/tmp/outside.txt"] {
            do {
                _ = try await history.restoreFile(repoPath: repo, file: bad, to: commit.hash)
                XCTFail("path must be rejected: \(bad)")
            } catch {
                XCTAssertEqual(error as? HistoryError, .invalidPath(bad))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside))
    }

    func testRestorePreservesOtherFiles() async throws {
        try write("v1", to: "f.md")
        try write("stable", to: "stable.md")
        try await commitAll("v1")
        let v1 = try await topCommit()
        try write("v2", to: "f.md")
        try write("stable-2", to: "stable.md")
        try await commitAll("v2")

        _ = try await history.restoreFile(repoPath: repo, file: "f.md", to: v1.hash)
        XCTAssertEqual(try read("f.md"), "v1")
        XCTAssertEqual(try read("stable.md"), "stable-2", "only the requested file may change")
    }

    func testRestorePreservesUncommittedEditsViaBackupCommit() async throws {
        let versions = try await makeTwoVersions()
        try write("unsaved work", to: "notes.md")   // uncommitted
        _ = try await history.restoreFile(repoPath: repo, file: "f.md", to: versions.v1.hash)

        let log = try await commits(limit: 10)
        XCTAssertTrue(log.contains { $0.subject.contains("backup") },
                      "pending edits must be saved: \(log.map(\.subject))")
        XCTAssertTrue(log.contains { $0.subject.contains("restore") })
        XCTAssertEqual(try read("notes.md"), "unsaved work")
        let trackedResult = try await git(["ls-files", "notes.md"])
        XCTAssertEqual(trackedResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "notes.md")
    }

    func testRestoreBinaryFileBitExact() async throws {
        let bytes: [UInt8] = [0x00, 0x01, 0xFF, 0xFE, 0x42, 0x0A, 0x7F]
        try writeBinary(bytes, to: "blob.bin")
        try await commitAll("binary v1")
        let v1 = try await topCommit()
        try writeBinary([0x09, 0x09], to: "blob.bin")
        try await commitAll("binary v2")

        _ = try await history.restoreFile(repoPath: repo, file: "blob.bin", to: v1.hash)
        XCTAssertEqual(readBytes("blob.bin").map(Array.init), bytes)
    }

    func testRestoreChineseSpacedEmojiFilename() async throws {
        let rel = "笔记/我的 草稿 😀.md"
        try write("初稿", to: rel)
        try await commitAll("add emoji file")
        let old = try await topCommit()
        try write("终稿", to: rel)
        try await commitAll("edit emoji file")

        _ = try await history.restoreFile(repoPath: repo, file: rel, to: old.hash)
        XCTAssertEqual(try read(rel), "初稿")
        let top = try await topCommit()
        XCTAssertTrue(top.subject.contains(rel), "rollback message keeps the raw path: \(top.subject)")
    }

    func testRestoreOnlyTouchesRequestedRepo() async throws {
        let other = root + "/other"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        let otherRunner = TestSupport.newRunner()
        _ = try await otherRunner.run(["init", "-b", "main"], cwd: other)
        _ = try await otherRunner.run(["config", "user.name", "T"], cwd: other)
        _ = try await otherRunner.run(["config", "user.email", "t@example.com"], cwd: other)
        try "other-v1".write(toFile: other + "/g.md", atomically: true, encoding: .utf8)
        _ = try await otherRunner.run(["add", "-A"], cwd: other)
        _ = try await otherRunner.run(["commit", "-m", "other c1"], cwd: other)

        let versions = try await makeTwoVersions()
        _ = try await history.restoreFile(repoPath: repo, file: "f.md", to: versions.v1.hash)

        let otherContent = try String(contentsOfFile: other + "/g.md", encoding: .utf8)
        XCTAssertEqual(otherContent, "other-v1", "restore is scoped to one repo")
    }

    // MARK: - resetRepo()

    func testResetRepoMovesHeadAndRestoresWorktree() async throws {
        let versions = try await makeTwoVersions()
        try await history.resetRepo(repoPath: repo, to: versions.v1.hash)
        let headHash = try await head()
        XCTAssertEqual(headHash, versions.v1.hash)
        XCTAssertEqual(try read("f.md"), "v1")
        let log = try await commits()
        XCTAssertEqual(log.first?.hash, versions.v1.hash, "later commits are dropped")
    }

    func testResetInvalidHashThrowsAndKeepsHead() async throws {
        _ = try await makeTwoVersions()
        let before = try await head()
        let bogus = String(repeating: "f", count: 40)
        do {
            try await history.resetRepo(repoPath: repo, to: bogus)
            XCTFail("expected failure for an unknown commit")
        } catch {
            XCTAssertEqual(error as? HistoryError, .commitNotFound(bogus))
        }
        let after = try await head()
        XCTAssertEqual(after, before)
    }

    func testResetToCurrentHeadIsNoOp() async throws {
        _ = try await makeTwoVersions()
        let before = try await head()
        try await history.resetRepo(repoPath: repo, to: before)
        let after = try await head()
        XCTAssertEqual(after, before)
        XCTAssertEqual(try read("f.md"), "v2")
    }

    func testResetBacksUpDirtyWorkAndPreResetHead() async throws {
        let versions = try await makeTwoVersions()
        try write("我在回滚前写了一半", to: "draft.md")   // uncommitted work
        let headBefore = try await head()

        try await history.resetRepo(repoPath: repo, to: versions.v1.hash)

        let headAfter = try await head()
        XCTAssertEqual(headAfter, versions.v1.hash)
        XCTAssertEqual(try read("f.md"), "v1")

        // Pre-reset HEAD (with the dirty edit committed) is kept in a hidden ref.
        let refsResult = try await git(["for-each-ref", "refs/filevault/backup",
                                        "--format=%(refname) %(objectname)"])
        let refLine = refsResult.stdout.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertTrue(refLine.contains("refs/filevault/backup/"), "pre-reset HEAD must be preserved: \(refLine)")

        let refName = refLine.split(separator: " ").first.map(String.init) ?? ""
        // The backup commit sits on top of the pre-reset HEAD, so the old HEAD
        // must still be reachable from the hidden ref.
        let ancestorCheck = try await git(["merge-base", "--is-ancestor", headBefore, refName])
        XCTAssertTrue(ancestorCheck.succeeded, "pre-reset HEAD \(headBefore) must stay reachable from \(refName)")
        let backupLog = try await git(["log", "--format=%s", refName])
        XCTAssertTrue(backupLog.stdout.contains("backup"),
                      "dirty work must be committed before the reset: \(backupLog.stdout)")

        // The work is still recoverable from the backup ref.
        let draftInBackup = try await git(["show", refName + ":draft.md"])
        XCTAssertEqual(draftInBackup.stdout, "我在回滚前写了一半")
    }

    /// A hard reset returns the worktree to the snapshot. Work that was only
    /// uncommitted is committed to the backup ref first, so nothing is lost —
    /// it just is not in the worktree any more.
    func testResetSnapshotsUntrackedWorkIntoBackupRef() async throws {
        let versions = try await makeTwoVersions()
        try write("not committed yet", to: "untracked.txt")
        try await history.resetRepo(repoPath: repo, to: versions.v1.hash)

        XCTAssertNil(try read("untracked.txt"), "worktree returns to the snapshot")
        let refsResult = try await git(["for-each-ref", "refs/filevault/backup", "--format=%(refname)"])
        let refName = refsResult.stdout.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertFalse(refName.isEmpty)
        let recovered = try await git(["show", refName + ":untracked.txt"])
        XCTAssertEqual(recovered.stdout, "not committed yet")
    }

    func testResetThenRestoreOldVersionStillWorks() async throws {
        let versions = try await makeTwoVersions()
        try await history.resetRepo(repoPath: repo, to: versions.v1.hash)
        // v2 left the branch but its object is still reachable and restorable.
        _ = try await history.restoreFile(repoPath: repo, file: "f.md", to: versions.v2.hash)
        XCTAssertEqual(try read("f.md"), "v2")
    }

    // MARK: - fileHistory()

    func testFileHistoryListsOnlyCommitsTouchingTheFile() async throws {
        try write("a1", to: "a.md")
        try write("b1", to: "b.md")
        try await commitAll("c1")
        try write("b2", to: "b.md")
        try await commitAll("c2 touches b")
        try write("a2", to: "a.md")
        try await commitAll("c3 touches a")

        let historyA = try await history.fileHistory(repoPath: repo, file: "a.md")
        XCTAssertEqual(historyA.map(\.subject), ["c3 touches a", "c1"])
        let historyB = try await history.fileHistory(repoPath: repo, file: "b.md")
        XCTAssertEqual(historyB.map(\.subject), ["c2 touches b", "c1"])
    }

    func testFileHistoryForUnknownFileIsEmpty() async throws {
        _ = try await makeTwoVersions()
        let list = try await history.fileHistory(repoPath: repo, file: "never-existed.md")
        XCTAssertTrue(list.isEmpty)
    }
}
