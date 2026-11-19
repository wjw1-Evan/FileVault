import XCTest
@testable import FileVaultCore

/// Deep-audit regression tests for the history core edge fixes.
///
/// Two bugs are pinned here:
/// 1. Per-file diffs of MERGE commits used the combined diff, so a file the
///    merge brought in from the other branch was listed by changedFiles
///    (first-parent since v4.2.28) but its own diff view was empty — the file
///    list and the diff of the very same file disagreed.
/// 2. exportFile left a 0-byte destination behind when the git process could
///    not even be spawned, while every other failure branch removed it.
final class HistoryCoreEdgeFixTests: XCTestCase {
    private var root = ""
    private var repos: RepoManager!
    private var runner: GitRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = TestSupport.makeTempDir("coreedge")
        runner = TestSupport.newRunner()
        repos = RepoManager(runner: runner)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
        try super.tearDownWithError()
    }

    private func git(_ args: [String], cwd: String) async throws -> GitResult {
        try await runner.run(args, cwd: cwd, timeout: 30)
    }

    // MARK: - Merge commit: changed files vs per-file diff

    /// A file the merge brought in from the side branch must be BOTH listed by
    /// changedFiles AND show a non-empty diff. Before the fix, `git show` on a
    /// merge printed the combined diff, which is empty for content that is
    /// identical to the other parent.
    func testMergeCommitDiffMatchesChangedFilesListing() async throws {
        let repo = root + "/merge-diff"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("base\n", to: repo + "/base.md")
        _ = try await repos.commitAll(path: repo, message: "C0")
        _ = try await git(["checkout", "-b", "feature"], cwd: repo)
        TestSupport.write("side\ncontent\n", to: repo + "/feature.md")
        _ = try await repos.commitAll(path: repo, message: "side work")
        _ = try await git(["checkout", "main"], cwd: repo)
        TestSupport.write("main\n", to: repo + "/main.md")
        _ = try await repos.commitAll(path: repo, message: "main work")
        let merge = try await git(["merge", "feature", "-m", "sync: merge feature"], cwd: repo)
        XCTAssertTrue(merge.succeeded, merge.stderr)
        let mergeHash = try await repos.resolveHead(path: repo)

        let history = HistoryService(repoManager: repos)
        let files = try await history.changedFiles(repoPath: repo, hash: mergeHash)
        XCTAssertTrue(files.contains { $0.hasSuffix("\tfeature.md") },
                      "changedFiles must list the file the merge brought in: \(files)")

        let diff = try await history.diff(repoPath: repo, hash: mergeHash, file: "feature.md")
        XCTAssertFalse(diff.isEmpty,
                       "the file listed by changedFiles must show its diff, got: \(diff)")
        XCTAssertTrue(diff.text.contains("+side"), "diff must show the side content: \(diff.text)")
        XCTAssertTrue(diff.text.contains("+content"), "diff must show the side content: \(diff.text)")

        // The first-parent semantics are unchanged for the merge's own side:
        // main.md was already in the first parent and must not appear.
        let mainDiff = try await history.diff(repoPath: repo, hash: mergeHash, file: "main.md")
        XCTAssertTrue(mainDiff.isEmpty, "first-parent diff must not invent changes: \(mainDiff)")
    }

    // MARK: - exportFile cleanup on spawn failure

    /// When git itself cannot be spawned, the empty destination that exportFile
    /// just created must be removed — not parked next to a failure notice as a
    /// 0-byte file with the user's chosen name.
    func testExportFileRemovesDestinationWhenGitCannotSpawn() async throws {
        let brokenRunner = GitRunner(gitExecutable: root + "/no-such-git")
        let history = HistoryService(repoManager: RepoManager(runner: brokenRunner))
        let repoPath = root + "/repo"
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        let destination = URL(fileURLWithPath: root + "/exported-note.md")

        do {
            try await history.exportFile(repoPath: repoPath, hash: "deadbeef",
                                         file: "note.md", to: destination)
            XCTFail("exportFile must fail when git cannot be spawned")
        } catch let error as HistoryError {
            XCTAssertEqual(error, .exportFailed(file: "note.md"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "a failed export must not leave a 0-byte destination behind")
    }
}
