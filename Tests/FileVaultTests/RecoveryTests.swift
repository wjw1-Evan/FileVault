import XCTest
@testable import FileVaultCore

/// v4.1 file recovery redesign: 「恢复」 means recovering a DELETED file or
/// reverting a MODIFIED one. These tests cover the index (what the window
/// lists), one file's version timeline, and the restore transaction itself.
final class RecoveryTests: XCTestCase {
    var root: String!
    var repo: String!
    var repos: RepoManager!
    var history: HistoryService!
    var recovery: RecoveryService!
    var runner: GitRunner!

    override func setUp() async throws {
        root = TestSupport.makeTempDir("recovery")
        repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        runner = TestSupport.newRunner()
        repos = RepoManager(runner: runner)
        history = HistoryService(repoManager: repos)
        recovery = RecoveryService(repoManager: repos, history: history)
        try await git(["init", "-b", "main"])
        try await git(["config", "user.name", "Recovery Tester"])
        try await git(["config", "user.email", "recovery@example.com"])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root!)
    }

    // MARK: - Helpers

    @discardableResult
    private func git(_ args: [String]) async throws -> GitResult {
        let r = try await runner.run(args, cwd: repo)
        XCTAssertTrue(r.succeeded, "\(args.joined(separator: " ")) failed: \(r.stderr)")
        return r
    }

    private func commitAll(_ message: String) async throws -> String {
        _ = try await git(["add", "-A"])
        _ = try await git(["commit", "-m", message])
        return try await head()
    }

    private func write(_ content: String, to relative: String) throws {
        let url = URL(fileURLWithPath: repo).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeBytes(_ bytes: [UInt8], to relative: String) throws {
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

    private func removeFile(_ relative: String) throws {
        try FileManager.default.removeItem(atPath: repo + "/" + relative)
    }

    private func topSubject() async throws -> String {
        let r = try await git(["log", "-1", "--pretty=%s"])
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func head() async throws -> String {
        let r = try await git(["rev-parse", "HEAD"])
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitCount() async throws -> Int {
        let r = try await git(["rev-list", "--count", "HEAD"])
        return Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func snapshot() async throws -> RecoverySnapshot {
        try await recovery.snapshot(repoPath: repo)
    }

    private func file(_ path: String, in snapshot: RecoverySnapshot) -> RecoverableFile? {
        snapshot.files.first { $0.path == path }
    }

    // MARK: - Index: deleted files

    func testCommittedDeletionIsListedWithDeletionCommit() async throws {
        try write("alpha", to: "a.md")
        try write("beta", to: "b.md")
        _ = try await commitAll("add both")
        try removeFile("a.md")
        let deleteCommit = try await commitAll("删除 a.md")

        let snap = try await snapshot()
        let deleted = try XCTUnwrap(file("a.md", in: snap))
        XCTAssertEqual(deleted.state, .deleted)
        XCTAssertEqual(deleted.deletedIn, String(deleteCommit.prefix(7)))
        XCTAssertTrue(deleted.lastSubject.contains("删除"))
        XCTAssertNotNil(deleted.lastChanged)
        // Untouched files stay available and are not part of the deleted list.
        XCTAssertEqual(file("b.md", in: snap)?.state, .available)
        XCTAssertEqual(snap.deletedCount, 1)
        XCTAssertEqual(snap.modifiedCount, 0)
    }

    func testUncommittedDeletionIsListedWithoutDeletionCommit() async throws {
        try write("alpha", to: "a.md")
        _ = try await commitAll("add a")
        try removeFile("a.md")

        let snap = try await snapshot()
        let deleted = try XCTUnwrap(file("a.md", in: snap))
        XCTAssertEqual(deleted.state, .deleted)
        XCTAssertNil(deleted.deletedIn, "not committed yet, so there is no deletion commit")
    }

    func testDeletedFileThatIsBackOnDiskIsNotListed() async throws {
        try write("alpha", to: "a.md")
        _ = try await commitAll("add a")
        try removeFile("a.md")
        _ = try await commitAll("delete a")
        try write("restored by hand", to: "a.md")   // untracked again

        let snap = try await snapshot()
        XCTAssertNil(file("a.md", in: snap), "it is on disk again, nothing to recover")
    }

    func testFileDeletedAndReAddedLaterIsAvailableNotDeleted() async throws {
        try write("v1", to: "a.md")
        _ = try await commitAll("add a")
        try removeFile("a.md")
        _ = try await commitAll("delete a")
        try write("v2", to: "a.md")
        _ = try await commitAll("re-add a")

        let snap = try await snapshot()
        XCTAssertEqual(file("a.md", in: snap)?.state, .available)
        XCTAssertEqual(snap.deletedCount, 0)
    }

    func testDeletedDeepPathKeepsDirectory() async throws {
        try write("note", to: "笔记/会议/周报.md")
        _ = try await commitAll("add nested")
        try removeFile("笔记/会议/周报.md")
        _ = try await commitAll("delete nested")

        let snap = try await snapshot()
        let deleted = try XCTUnwrap(file("笔记/会议/周报.md", in: snap))
        XCTAssertEqual(deleted.name, "周报.md")
        XCTAssertEqual(deleted.directory, "笔记/会议")
    }

    // MARK: - Index: modified files

    func testUncommittedModificationIsListedAsModified() async throws {
        try write("v1", to: "a.md")
        _ = try await commitAll("add a")
        try write("v2 local", to: "a.md")

        let snap = try await snapshot()
        let modified = try XCTUnwrap(file("a.md", in: snap))
        XCTAssertEqual(modified.state, .modified)
        XCTAssertEqual(snap.modifiedCount, 1)
    }

    func testIdenticalFileIsAvailable() async throws {
        try write("same", to: "a.md")
        _ = try await commitAll("add a")

        let snap = try await snapshot()
        XCTAssertEqual(file("a.md", in: snap)?.state, .available)
        XCTAssertEqual(snap.modifiedCount, 0)
    }

    // MARK: - Index: shape and safety

    func testSnapshotIsEmptyForUnbornRepository() async throws {
        let snap = try await snapshot()
        XCTAssertTrue(snap.files.isEmpty)
        XCTAssertEqual(snap.deletedCount, 0)
    }

    func testSnapshotHidesEmptyFolderMarker() async throws {
        try write("hidden", to: "empty-folder/.gitkeep")
        _ = try await commitAll("folder marker")

        let snap = try await snapshot()
        XCTAssertNil(file("empty-folder/.gitkeep", in: snap))
        XCTAssertFalse(snap.files.contains { $0.path.hasSuffix(".gitkeep") })
    }

    func testSnapshotSortsDeletedFirstThenNewestChange() async throws {
        try write("a", to: "a.md")
        _ = try await commitAll("c1")
        try write("b", to: "b.md")
        _ = try await commitAll("c2 add b")
        try removeFile("a.md")
        _ = try await commitAll("c3 delete a")

        let snap = try await snapshot()
        XCTAssertEqual(snap.files.first?.path, "a.md")
        XCTAssertEqual(snap.files.first?.state, .deleted)
    }

    /// Auto-commit folders produce hundreds of tiny commits; the window must be
    /// able to say "there may be older deletions" instead of silently dropping them.
    func testSnapshotReportsTruncationWhenScanLimitIsHit() async throws {
        for i in 0..<4 {
            try write("v\(i)", to: "a.md")
            _ = try await commitAll("c\(i)")
        }
        let snap = try await recovery.snapshot(repoPath: repo, recentCommits: 2, deletionCommits: 2)
        XCTAssertTrue(snap.truncated)
    }

    func testSnapshotDoesNotReportTruncationWhenEverythingWasScanned() async throws {
        try write("v1", to: "a.md")
        _ = try await commitAll("c1")
        let snap = try await recovery.snapshot(repoPath: repo, recentCommits: 100)
        XCTAssertFalse(snap.truncated)
    }

    // MARK: - Versions of one file

    func testVersionsShowNewestFirstAndMarkTheDeletion() async throws {
        try write("v1", to: "a.md")
        let first = try await commitAll("v1")
        try write("v2", to: "a.md")
        let second = try await commitAll("v2")
        try removeFile("a.md")
        let deletion = try await commitAll("delete")

        let versions = try await recovery.versions(repoPath: repo, file: "a.md")
        XCTAssertEqual(versions.map(\.hash), [deletion, second, first])
        XCTAssertFalse(versions[0].exists)
        XCTAssertTrue(versions[0].isDeletion)
        XCTAssertTrue(versions[1].exists)
        XCTAssertTrue(versions[2].exists)
        XCTAssertEqual(versions.map(\.subject), ["delete", "v2", "v1"])
    }

    func testVersionsStayShortHashesAndDates() async throws {
        try write("v1", to: "a.md")
        let hash = try await commitAll("hello")

        let versions = try await recovery.versions(repoPath: repo, file: "a.md")
        let v = try XCTUnwrap(versions.first)
        XCTAssertEqual(v.hash, hash)
        XCTAssertEqual(v.shortHash, String(hash.prefix(7)))
        XCTAssertGreaterThan(v.date.timeIntervalSince1970, 1_600_000_000)
    }

    func testVersionsForUnknownFileIsEmpty() async throws {
        try write("v1", to: "a.md")
        _ = try await commitAll("c1")
        let versions = try await recovery.versions(repoPath: repo, file: "never.md")
        XCTAssertTrue(versions.isEmpty)
    }

    func testVersionsRejectPathTraversal() async throws {
        for bad in ["../escape.md", "/etc/passwd", "a/../../b.md"] {
            do {
                _ = try await recovery.versions(repoPath: repo, file: bad)
                XCTFail("path must be rejected: \(bad)")
            } catch {
                XCTAssertEqual(error as? HistoryError, .invalidPath(bad))
            }
        }
    }

    func testVersionsSurviveRename() async throws {
        try write("content", to: "old.md")
        _ = try await commitAll("add old")
        _ = try await git(["mv", "old.md", "new.md"])
        let rename = try await commitAll("rename")

        let versions = try await recovery.versions(repoPath: repo, file: "new.md")
        XCTAssertEqual(versions.first?.hash, rename)
        XCTAssertEqual(versions.first?.statusCharacter, "R")
        // The pre-rename version is still listed through --follow.
        XCTAssertEqual(versions.count, 2)
    }


    /// Restoring a deleted file recreates its (also deleted) parent folders.
    func testRestoreRecreatesDeletedParentFolders() async throws {
        try write("deep", to: "notes/2026/idea.md")
        _ = try await commitAll("v1")
        let original = try await head()
        try FileManager.default.removeItem(atPath: repo + "/notes")
        _ = try await commitAll("delete folder")
        XCTAssertNil(read("notes/2026/idea.md"))

        let result = try await recovery.restore(repoPath: repo, file: "notes/2026/idea.md", to: original)
        guard case .restored(_, let recreated) = result else { return XCTFail("got \(result)") }
        XCTAssertTrue(recreated)
        XCTAssertEqual(read("notes/2026/idea.md"), "deep")
    }

    /// A directory sitting at the target path must produce a readable error and
    /// must never be replaced by the app (v4.2.14).
    func testRestoreRefusesWhenTargetPathIsDirectory() async throws {
        try write("file", to: "note.md")
        _ = try await commitAll("v1")
        let original = try await head()
        try FileManager.default.removeItem(atPath: repo + "/note.md")
        try FileManager.default.createDirectory(atPath: repo + "/note.md", withIntermediateDirectories: true)
        try write("child", to: "note.md/child.txt")
        _ = try await commitAll("v2 directory")

        do {
            _ = try await recovery.restore(repoPath: repo, file: "note.md", to: original)
            XCTFail("restoring onto a directory must fail")
        } catch let error as HistoryError {
            guard case .restoreTargetIsDirectory(let file) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(file, "note.md")
            XCTAssertTrue((error.errorDescription ?? "").contains("文件夹"), error.errorDescription ?? "")
        }
        XCTAssertEqual(read("note.md/child.txt"), "child", "the directory must be left untouched")
    }

    // MARK: - Restore a deleted file


    func testRestoreDeletedFileRecreatesItAndCommits() async throws {
        try write("precious", to: "gone.md")
        let original = try await commitAll("add gone")
        try removeFile("gone.md")
        _ = try await commitAll("delete gone")

        let snapBefore = try await snapshot()
        XCTAssertEqual(file("gone.md", in: snapBefore)?.state, .deleted)

        let result = try await recovery.restore(repoPath: repo, file: "gone.md", to: original)
        guard case .restored(let commit, let recreated) = result else {
            XCTFail("expected a restore, got \(result)")
            return
        }
        XCTAssertTrue(recreated)
        XCTAssertFalse(commit.isEmpty)
        XCTAssertEqual(read("gone.md"), "precious")
        let top = try await repos.log(path: repo).first
        XCTAssertTrue(top?.subject.contains("restore") == true)
        XCTAssertTrue(top?.subject.contains("找回") == true)
        XCTAssertTrue(top?.subject.contains("gone.md") == true)

        // The file is back on disk: it is no longer something to recover.
        let snapAfter = try await snapshot()
        XCTAssertEqual(file("gone.md", in: snapAfter)?.state, .available)
        XCTAssertEqual(snapAfter.deletedCount, 0)
    }

    func testRestoreDeletedFileUsesTheVersionThatStillHadIt() async throws {
        try write("v1", to: "a.md")
        let first = try await commitAll("v1")
        try write("v2", to: "a.md")
        _ = try await commitAll("v2")
        try removeFile("a.md")
        let deletion = try await commitAll("delete")

        // 「找回」 from the deletion commit picks the last existing version.
        let target = try await recovery.lastExistingVersion(repoPath: repo, file: "a.md", from: deletion)
        XCTAssertNotNil(target)
        XCTAssertNotEqual(target, deletion)

        let result = try await recovery.restoreDeleted(repoPath: repo, file: "a.md", deletedIn: deletion)
        let restoredHead = try await head()
        XCTAssertEqual(result, .restored(commit: restoredHead, recreated: true))
        XCTAssertEqual(read("a.md"), "v2")
        XCTAssertGreaterThan(target!.count, 7)
        XCTAssertEqual(first.count, target!.count)
    }

    // MARK: - Restore a modified file

    func testRestoreModifiedFileToOlderVersion() async throws {
        try write("v1", to: "a.md")
        let first = try await commitAll("v1")
        try write("v2", to: "a.md")
        _ = try await commitAll("v2")

        let result = try await recovery.restore(repoPath: repo, file: "a.md", to: first)
        guard case .restored(_, let recreated) = result else {
            XCTFail("expected a restore, got \(result)")
            return
        }
        XCTAssertFalse(recreated)
        XCTAssertEqual(read("a.md"), "v1")
        let top = try await repos.log(path: repo).first
        XCTAssertTrue(top?.subject.contains("还原") == true)
    }

    func testRestoreUncommittedChangeBackToLatestVersion() async throws {
        try write("committed", to: "a.md")
        let committed = try await commitAll("c1")
        try write("oops", to: "a.md")

        let result = try await recovery.restore(repoPath: repo, file: "a.md", to: committed)
        let restoredHead = try await head()
        XCTAssertEqual(result, .restored(commit: restoredHead, recreated: false))
        XCTAssertEqual(read("a.md"), "committed")
    }

    func testRestoreIdenticalContentDoesNothing() async throws {
        try write("same", to: "a.md")
        let commit = try await commitAll("c1")
        let before = try await commitCount()

        let result = try await recovery.restore(repoPath: repo, file: "a.md", to: commit)
        XCTAssertEqual(result, .unchanged)
        let after = try await commitCount()
        XCTAssertEqual(after, before, "no empty rollback commit")
    }

    func testRestoreUnknownCommitThrows() async throws {
        try write("v1", to: "a.md")
        _ = try await commitAll("c1")
        let bogus = String(repeating: "f", count: 40)
        do {
            _ = try await recovery.restore(repoPath: repo, file: "a.md", to: bogus)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? HistoryError, .commitNotFound(bogus))
        }
    }

    func testRestoreFileMissingInTargetVersionThrowsAndChangesNothing() async throws {
        try write("v1", to: "a.md")
        let first = try await commitAll("c1")
        try write("v2", to: "later.md")
        let second = try await commitAll("c2 add later")
        XCTAssertFalse(first.isEmpty)
        let before = try await head()

        do {
            _ = try await recovery.restore(repoPath: repo, file: "later.md", to: first)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? HistoryError, .fileNotInCommit(file: "later.md",
                                                                   hash: String(first.prefix(7))))
        }
        let headAfterFailure = try await head()
        XCTAssertEqual(headAfterFailure, before)
        XCTAssertEqual(second, before)
    }

    func testRestoreRejectsTraversalWithoutTouchingOutside() async throws {
        try write("v1", to: "a.md")
        let commit = try await commitAll("c1")
        let outside = root + "/outside.md"
        try "outside".write(toFile: outside, atomically: true, encoding: .utf8)

        for bad in ["../outside.md", "/tmp/outside.md"] {
            do {
                _ = try await recovery.restore(repoPath: repo, file: bad, to: commit)
                XCTFail("path must be rejected: \(bad)")
            } catch {
                XCTAssertEqual(error as? HistoryError, .invalidPath(bad))
            }
        }
        XCTAssertEqual(try String(contentsOfFile: outside, encoding: .utf8), "outside")
    }

    func testRestoreKeepsOtherFilesUntouched() async throws {
        try write("v1", to: "a.md")
        try write("stable", to: "stable.md")
        let first = try await commitAll("c1")
        try write("v2", to: "a.md")
        try write("stable-2", to: "stable.md")
        _ = try await commitAll("c2")

        _ = try await recovery.restore(repoPath: repo, file: "a.md", to: first)
        XCTAssertEqual(read("a.md"), "v1")
        XCTAssertEqual(read("stable.md"), "stable-2")
    }

    func testRestoreBacksUpUncommittedChangesFirst() async throws {
        try write("v1", to: "a.md")
        let first = try await commitAll("c1")
        try write("v2", to: "a.md")
        _ = try await commitAll("c2")
        try write("half-written", to: "draft.md")   // uncommitted, untouched by restore

        _ = try await recovery.restore(repoPath: repo, file: "a.md", to: first)

        let log = try await repos.log(path: repo, max: 10)
        XCTAssertTrue(log.contains { $0.subject.contains("backup") })
        XCTAssertTrue(log.contains { $0.subject.contains("restore") })
        XCTAssertEqual(read("draft.md"), "half-written")
        let tracked = try await git(["ls-files", "draft.md"])
        XCTAssertEqual(tracked.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "draft.md")
    }


    func testRestoreFileInsideDeletedFolderRecreatesParents() async throws {
        try write("note", to: "笔记/会议/周报.md")
        let first = try await commitAll("add nested file")
        try FileManager.default.removeItem(atPath: repo + "/笔记")
        _ = try await commitAll("delete folder")

        let result = try await recovery.restore(repoPath: repo, file: "笔记/会议/周报.md", to: first)
        guard case .restored(_, let recreated) = result else {
            XCTFail("expected a restore, got \(result)")
            return
        }
        XCTAssertTrue(recreated)
        XCTAssertEqual(read("笔记/会议/周报.md"), "note")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/笔记/会议"))
    }

    func testRestoreBinaryFileIsBitExact() async throws {
        let bytes: [UInt8] = [0x00, 0x01, 0xFF, 0xFE, 0x42, 0x0A, 0x7F]
        try writeBytes(bytes, to: "blob.bin")
        let first = try await commitAll("binary v1")
        try writeBytes([0x09, 0x09], to: "blob.bin")
        _ = try await commitAll("binary v2")

        _ = try await recovery.restore(repoPath: repo, file: "blob.bin", to: first)
        XCTAssertEqual(readBytes("blob.bin").map(Array.init), bytes)
    }

    func testRestoreChineseSpacedEmojiPath() async throws {
        let rel = "笔记/我的 草稿 😀.md"
        try write("初稿", to: rel)
        let first = try await commitAll("add emoji file")
        try write("终稿", to: rel)
        _ = try await commitAll("edit emoji file")

        _ = try await recovery.restore(repoPath: repo, file: rel, to: first)
        XCTAssertEqual(read(rel), "初稿")
        let top = try await repos.log(path: repo).first
        XCTAssertTrue(top?.subject.contains(rel) == true)
    }

    // MARK: - Diff with the current folder

    func testWorkingDiffShowsCurrentVersusVersion() async throws {
        try write("v1", to: "a.md")
        let first = try await commitAll("v1")
        try write("v2", to: "a.md")
        let second = try await commitAll("v2")

        let diff = try await recovery.workingDiff(repoPath: repo, file: "a.md", version: first)
        XCTAssertFalse(diff.text.isEmpty)
        XCTAssertTrue(diff.text.contains("-" + "v1"))
        XCTAssertTrue(diff.text.contains("+" + "v2"))
        XCTAssertFalse(diff.isBinary)

        let same = try await recovery.workingDiff(repoPath: repo, file: "a.md", version: second)
        XCTAssertTrue(same.isEmpty, "file matches that version")
    }

    func testWorkingDiffOfDeletedFileShowsItsRemoval() async throws {
        try write("keep me", to: "a.md")
        let first = try await commitAll("v1")
        try removeFile("a.md")

        let diff = try await recovery.workingDiff(repoPath: repo, file: "a.md", version: first)
        XCTAssertTrue(diff.text.contains("-keep me"))
        XCTAssertGreaterThan(diff.removed, 0)
    }

    // MARK: - Log parsing (format regression guard)


    // MARK: - Additional recovery coverage (v4.2.18)

    /// A file deleted and later re-added: "找回" must use the newest version
    /// that existed BEFORE the deletion, not the re-added one.
    func testRestoreDeletedReAddedFileUsesPreDeletionVersion() async throws {
        try write("v1 content", to: "re.md")
        _ = try await commitAll("v1")
        try removeFile("re.md")
        _ = try await commitAll("delete re")
        let dele = try await head()
        try write("v2 re-added", to: "re.md")
        _ = try await commitAll("re-add re")

        let result = try await recovery.restoreDeleted(repoPath: repo, file: "re.md", deletedIn: dele)
        guard case .restored = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(read("re.md"), "v1 content", "must restore the pre-deletion content")
    }

    /// versions(limit:) caps the timeline (the window shows the newest first).
    func testVersionsRespectLimit() async throws {
        try write("one", to: "lim.md")
        _ = try await commitAll("v1")
        try write("two", to: "lim.md")
        _ = try await commitAll("v2")
        try write("three", to: "lim.md")
        _ = try await commitAll("v3")
        let all = try await recovery.versions(repoPath: repo, file: "lim.md")
        XCTAssertEqual(all.count, 3)
        let one = try await recovery.versions(repoPath: repo, file: "lim.md", limit: 1)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].subject, "v3")
        XCTAssertTrue(one[0].exists)
    }

    /// A huge working diff is cut at maxBytes and flagged, so the window cannot
    /// freeze on a multi-megabyte file.
    func testWorkingDiffTruncatesLargeOutput() async throws {
        let lines = (0..<200).map { "line \($0)" }.joined(separator: "\n")
        try write(lines, to: "big.md")
        _ = try await commitAll("v1")
        let v1 = try await head()
        let more = (0..<400).map { "line \($0)" }.joined(separator: "\n")
        try write(more, to: "big.md")

        let diff = try await recovery.workingDiff(repoPath: repo, file: "big.md",
                                                  version: v1, maxBytes: 500)
        XCTAssertTrue(diff.truncated)
        XCTAssertLessThanOrEqual(diff.text.utf8.count, 500)
        XCTAssertFalse(diff.isBinary)
        XCTAssertGreaterThan(diff.added, 0)
    }

    /// Binary files are reported as binary instead of dumping mojibake.
    func testWorkingDiffFlagsBinaryFiles() async throws {
        try writeBytes([0x00, 0x01, 0x02, 0x00], to: "blob.bin")
        _ = try await commitAll("v1 binary")
        let v1 = try await head()
        try writeBytes([0x00, 0x03, 0x04, 0x00], to: "blob.bin")

        let diff = try await recovery.workingDiff(repoPath: repo, file: "blob.bin", version: v1)
        XCTAssertTrue(diff.isBinary, diff.text)
        XCTAssertFalse(diff.text.isEmpty)
    }

    /// Restoring an empty file must produce an actually empty file.
    func testRestoreEmptyFileIsBitExact() async throws {
        try writeBytes([], to: "empty.md")
        _ = try await commitAll("v1 empty")
        let v1 = try await head()
        try write("not empty any more", to: "empty.md")
        _ = try await commitAll("v2")

        _ = try await recovery.restore(repoPath: repo, file: "empty.md", to: v1)
        let bytes = readBytes("empty.md")
        XCTAssertEqual(bytes, Data(), "the restored file must be 0 bytes")
    }

    /// A file without a trailing newline / with CRLF keeps its exact bytes.
    func testRestorePreservesExactBytesWithoutTrailingNewline() async throws {
        let original: [UInt8] = Array("line1\r\nline2".utf8)
        try writeBytes(original, to: "crlf.md")
        _ = try await commitAll("v1 crlf")
        let v1 = try await head()
        try writeBytes(Array("different".utf8), to: "crlf.md")
        _ = try await commitAll("v2")

        _ = try await recovery.restore(repoPath: repo, file: "crlf.md", to: v1)
        XCTAssertEqual(readBytes("crlf.md").map { Array($0) }, original)
    }

    /// After restoring, the file is back in sync with HEAD and the snapshot
    /// shows it as available (not modified).
    func testSnapshotShowsAvailableAfterRestore() async throws {
        try write("v1", to: "back.md")
        _ = try await commitAll("v1")
        let v1 = try await head()
        try write("edited locally", to: "back.md")
        var snap = try await snapshot()
        XCTAssertEqual(file("back.md", in: snap)?.state, .modified)

        _ = try await recovery.restore(repoPath: repo, file: "back.md", to: v1)
        snap = try await snapshot()
        XCTAssertEqual(file("back.md", in: snap)?.state, .available)
        XCTAssertEqual(read("back.md"), "v1")
    }

    /// The auto commit created by a restore names the file (both variants).
    func testRestoreCommitMessageNamesTheFile() async throws {
        try write("v1", to: "note.md")
        _ = try await commitAll("v1")
        let v1 = try await head()
        try write("v2", to: "note.md")
        _ = try await commitAll("v2")
        _ = try await recovery.restore(repoPath: repo, file: "note.md", to: v1)
        var top = try await topSubject()
        XCTAssertTrue(top.contains("restore:"), top)
        XCTAssertTrue(top.contains("note.md"), top)

        try removeFile("note.md")
        _ = try await commitAll("delete note")
        _ = try await recovery.restoreDeleted(repoPath: repo, file: "note.md", deletedIn: try await head())
        top = try await topSubject()
        XCTAssertTrue(top.contains("restore:"), top)
        XCTAssertTrue(top.contains("note.md"), top)
        XCTAssertTrue(top.contains("找回"), top)
    }

    /// Paths with spaces and double quotes survive commit → restore → commit.
    func testRestoreHandlesQuotesAndSpacesInPath() async throws {
        let path = "a \"quoted\" name.md"
        try write("v1", to: path)
        _ = try await commitAll("v1 quoted")
        let v1 = try await head()
        try write("v2", to: path)
        _ = try await commitAll("v2 quoted")

        _ = try await recovery.restore(repoPath: repo, file: path, to: v1)
        XCTAssertEqual(read(path), "v1")
        let top = try await topSubject()
        XCTAssertTrue(top.contains("a \"quoted\" name.md"), top)
        let status = try? await repos.status(path: repo)
        XCTAssertEqual(status?.count, 0)
    }

    func testParseLogUnderstandsNulLayoutAndRenames() throws {
        let nul = "\u{0}"
        let soh = "\u{1}"
        let raw = soh + "AAA" + soh + "aaa" + soh + "2026-01-02T03:04:05+08:00" + soh + "first" + "\n" + "M" + nul
            + "a.txt" + nul + nul
            + soh + "BBB" + soh + "bbb" + soh + "2026-01-03T03:04:05+08:00" + soh + "rename" + "\n" + "R100" + nul
            + "old.txt" + nul + "new.txt" + nul + nul
            + soh + "CCC" + soh + "ccc" + soh + "2026-01-04T03:04:05+08:00" + soh + "delete" + "\n" + "D" + nul
            + "new.txt" + nul + nul

        let parsed = RecoveryService.parseLog(raw)
        XCTAssertEqual(parsed.commitCount, 3)
        XCTAssertEqual(parsed.records.count, 3)
        XCTAssertEqual(parsed.records[0].path, "a.txt")
        XCTAssertEqual(parsed.records[0].status, "M")
        XCTAssertEqual(parsed.records[0].commit, "AAA")
        XCTAssertEqual(parsed.records[1].status, "R100")
        XCTAssertEqual(parsed.records[1].originalPath, "old.txt")
        XCTAssertEqual(parsed.records[1].path, "new.txt")
        XCTAssertEqual(parsed.records[2].status, "D")
        XCTAssertNotNil(parsed.records[2].date)
    }

    func testParseLogAcceptsEmptyInput() {
        let parsed = RecoveryService.parseLog("")
        XCTAssertTrue(parsed.records.isEmpty)
        XCTAssertEqual(parsed.commitCount, 0)
    }
}
