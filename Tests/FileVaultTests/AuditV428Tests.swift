import XCTest
@testable import FileVaultCore

/// Regression tests for the v4.2.28 audit round (third full pass over the
/// 18-module list). Naming follows AuditV427*Tests.
final class AuditV428Tests: XCTestCase {
    // MARK: - Helpers

    private var root = ""
    private var repos: RepoManager!
    private var runner: GitRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = TestSupport.makeTempDir("v428")
        runner = TestSupport.newRunner()
        repos = RepoManager(runner: runner)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
        try super.tearDownWithError()
    }

    private func git(_ args: [String], cwd: String) async -> GitResult {
        (try? await runner.run(args, cwd: cwd, timeout: 30))
            ?? GitResult(exitCode: -1, stdout: "", stderr: "spawn failed")
    }

    private func makeRepo(_ name: String) async throws -> String {
        let path = root + "/" + name
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: path)
        return path
    }

    /// The backup-ref name must be `refs/filevault/backup/<stamp>-<4 hex>`.
    /// v4.2.27 wrote the random suffix as literal source text — the Swift
    /// string interpolation scans to the first balanced paren, so
    /// `\(stamp)-(UUID().uuidString.prefix(4))` produced refs literally named
    /// "…-(UUID().uuidString.prefix(4))" and two snapshots in the same second
    /// still overwrote each other.
    private func assertBackupRefName(_ ref: String, file: StaticString = #filePath,
                                     line: UInt = #line) {
        XCTAssertTrue(ref.hasPrefix("refs/filevault/backup/"), "unexpected ref: \(ref)", file: file, line: line)
        let last = ref.split(separator: "/").last.map(String.init) ?? ""
        XCTAssertFalse(last.contains("("), "the random suffix must be interpolated, not literal source text: \(ref)",
                       file: file, line: line)
        let pattern = "^\\d{8}-\\d{6}-[0-9A-Fa-f]{4}$"
        XCTAssertNotNil(last.range(of: pattern, options: .regularExpression),
                        "backup ref stamp must be <yyyyMMdd-HHmmss>-<4 hex>: \(ref)", file: file, line: line)
    }

    // MARK: - Backup refs

    /// Two rollbacks in the same second must produce TWO backup refs; the
    /// literal-interpolation bug made the second update-ref overwrite the
    /// first, leaving the replaced HEAD unreferenced (gc-able).
    func testResetRepoBackupRefsAreUniqueWithinTheSameSecond() async throws {
        let repo = try await makeRepo("v428-reset-refs")
        TestSupport.write("v1\n", to: repo + "/a.txt")
        _ = try await repos.commitAll(path: repo, message: "C1")
        let c1 = try await repos.resolveHead(path: repo)
        TestSupport.write("v2\n", to: repo + "/a.txt")
        _ = try await repos.commitAll(path: repo, message: "C2")
        let c2 = try await repos.resolveHead(path: repo)

        try await repos.resetRepo(path: repo, to: c1)
        try await repos.resetRepo(path: repo, to: c2)

        let backups = try await HistoryService(repoManager: repos).backups(repoPath: repo)
        let names = backups.map(\.refName)
        XCTAssertEqual(names.count, 2, "two rollbacks in the same second must leave two backup refs: \(names)")
        XCTAssertEqual(Set(names).count, 2, "backup refs must not overwrite each other: \(names)")
        for name in names { assertBackupRefName(name) }
        // Each ref must still resolve to the HEAD it replaced.
        let resolved = try await runner.run(["rev-parse", names[0]], cwd: repo)
        XCTAssertTrue(resolved.succeeded, "backup ref must resolve: \(names[0])")
    }

    /// mergeSync's backup ref previously had NO random suffix at all (it was
    /// missed when resetRepo/forcePull got one) — same-second syncs collided.
    func testMergeSyncBackupRefCarriesRandomSuffix() async throws {
        // Remote with its own history.
        let remote = root + "/remote.git"
        let seed = root + "/seed"
        try FileManager.default.createDirectory(atPath: remote, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        _ = try await runner.run(["init", "--bare", "-b", "main"], cwd: remote)
        _ = try await runner.run(["init", "-b", "main"], cwd: seed)
        TestSupport.write("seed\n", to: seed + "/seed.md")
        _ = try await repos.commitAll(path: seed, message: "seed")
        _ = try await runner.run(["remote", "add", "origin", remote], cwd: seed)
        _ = try await runner.run(["push", "-u", "origin", "HEAD"], cwd: seed)

        // Local folder with its own (unrelated) history.
        let local = try await makeRepo("v428-sync-local")
        TestSupport.write("local\n", to: local + "/local.md")
        _ = try await repos.commitAll(path: local, message: "local work")
        try await repos.setRemote(path: local, url: remote)

        let result = try await repos.mergeSync(path: local)
        let backupRef = try XCTUnwrap(result.backupRef, "a diverged merge-sync must leave a backup ref")
        assertBackupRefName(backupRef)
        let resolved = try await runner.run(["rev-parse", backupRef], cwd: local)
        XCTAssertTrue(resolved.succeeded, "backup ref must resolve")
    }

    // MARK: - Merge commits in the history browser

    /// `git diff-tree` prints NOTHING for merge commits by default, so every
    /// auto-sync merge showed "没有文件变更" and its files could not be
    /// browsed/restored. --diff-merges=first-parent fixes the listing.
    func testChangedFilesListsMergeCommitChanges() async throws {
        let repo = try await makeRepo("v428-merge-files")
        TestSupport.write("base\n", to: repo + "/base.md")
        _ = try await repos.commitAll(path: repo, message: "C0")
        _ = try await git(["checkout", "-b", "feature"], cwd: repo)
        TestSupport.write("feature\n", to: repo + "/feature.md")
        _ = try await repos.commitAll(path: repo, message: "feature file")
        _ = try await git(["checkout", "main"], cwd: repo)
        TestSupport.write("main\n", to: repo + "/main.md")
        _ = try await repos.commitAll(path: repo, message: "main file")
        let merge = try await git(["merge", "feature", "-m", "sync: merge feature"], cwd: repo)
        XCTAssertTrue(merge.succeeded, merge.stderr)
        let mergeHash = try await repos.resolveHead(path: repo)
        let parents = try await git(["rev-list", "--parents", "-n", "1", mergeHash], cwd: repo)
        XCTAssertEqual(parents.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").count, 3, "sanity: this must be a merge commit")

        let history = HistoryService(repoManager: repos)
        let files = try await history.changedFiles(repoPath: repo, hash: mergeHash)
        let paths = files.map { line in
            line.split(separator: "\t", maxSplits: 1).last.map(String.init) ?? line
        }
        // first-parent semantics: the merge diff is vs the commit main was on,
        // so it lists what the merge BROUGHT IN (feature.md). main.md already
        // lived in the first parent and must NOT appear.
        XCTAssertTrue(paths.contains("feature.md"), "merge listing must contain feature.md: \(files)")
        XCTAssertFalse(paths.contains("main.md"), "first-parent diff must not list first-parent content: \(files)")
        XCTAssertFalse(files.isEmpty, "a merge commit must not list as having no changes: \(files)")

        let stats = try await history.changeStats(repoPath: repo, hash: mergeHash)
        XCTAssertTrue(stats.keys.contains("feature.md"), "merge stats must contain feature.md: \(stats.keys)")
        XCTAssertEqual(stats["feature.md"]?.added, 1)
    }

    // MARK: - Content search / log parsing unaffected by the formatter hoist

    /// The per-line ISO8601DateFormatter was hoisted out of the loop; parsing
    /// must behave identically (dates still populate, malformed → epoch).
    func testLogStillParsesDatesAfterFormatterHoist() async throws {
        let repo = try await makeRepo("v428-log-dates")
        TestSupport.write("v1\n", to: repo + "/a.txt")
        _ = try await repos.commitAll(path: repo, message: "C1")
        let commits = try await repos.log(path: repo, max: 10)
        // The initial "auto: 初始版本" commit (created for the injected
        // .gitignore) plus C1.
        XCTAssertGreaterThanOrEqual(commits.count, 1)
        XCTAssertGreaterThan(commits[0].date.timeIntervalSince1970, 1_600_000_000,
                             "commit date must parse into a real timestamp")
    }
}
