import XCTest
@testable import FileVaultCore

/// v4.2.32: Core-side contract for the repository-integrity check that the
/// Settings card surfaces ("检查仓库完整性…"). Until now only the healthy
/// path had a test; the two outcomes users actually act on — a CORRUPTED
/// object (ok=false + issues) and DANGLING leftovers (ok=true + counted) —
/// were unpinned. Constructing a corrupted repo is Core work, hence here.
final class FsckReportContractTests: XCTestCase {
    var root: String!
    var repo: String!
    var repos: RepoManager!
    var history: HistoryService!

    override func setUp() {
        root = TestSupport.makeTempDir("fsck")
        repo = root + "/repo"
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        repos = RepoManager(runner: TestSupport.newRunner())
        history = HistoryService(repoManager: repos)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root!)
    }

    @discardableResult
    private func commit(_ message: String) async throws -> String {
        _ = try await repos.commitAll(path: repo, message: message)
        return try await repos.resolveHead(path: repo)
    }

    private func run(_ args: [String]) async throws -> GitResult {
        try await TestSupport.newRunner().run(args, cwd: repo)
    }

    /// A healthy repository: ok, no issues, and the summary is the copy the
    /// Settings card shows.
    func testHealthyRepoIsOkAndSummaryIsUserFacing() async throws {
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("hello\n", to: repo + "/a.md")
        _ = try await commit("v1")
        let report = try await history.fsck(repoPath: repo)
        XCTAssertTrue(report.ok)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertTrue(report.summary.contains("完好"))
    }

    /// Deleting a reachable blob must surface as a failure with a non-empty
    /// issue list — the state the Settings alert warns about ("不要删 .git").
    func testMissingBlobIsReportedAsIssue() async throws {
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("payload that will be deleted\n", to: repo + "/a.md")
        _ = try await commit("v1")

        let revParse = try await run(["rev-parse", "HEAD:a.md"])
        let hash = revParse.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(hash.count, 40, "expected a full object id, got: \(hash)")
        let objectPath = repo + "/.git/objects/" + String(hash.prefix(2)) + "/" + String(hash.dropFirst(2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: objectPath), "blob object must exist first")
        try FileManager.default.removeItem(atPath: objectPath)

        let report = try await history.fsck(repoPath: repo)
        XCTAssertFalse(report.ok, "a missing object must not read as a healthy repository")
        XCTAssertFalse(report.issues.isEmpty, "the alert renders report.issues — it cannot be empty")
    }

    /// An unreferenced object is genuinely dangling: fsck stays ok, but the
    /// count tells the user the weekly gc has work. (A reset alone does NOT
    /// produce dangling output — reflogs keep the discarded commit reachable;
    /// writing a blob with no reference is the honest way to construct this.)
    func testDanglingObjectsAreCountedWhileStillOk() async throws {
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("v1\n", to: repo + "/a.md")
        _ = try await commit("v1")

        let loose = root + "/loose.txt"
        TestSupport.write("never referenced by any commit\n", to: loose)
        let written = try await run(["hash-object", "-w", loose])
        XCTAssertEqual(written.stdout.trimmingCharacters(in: .whitespacesAndNewlines).count, 40,
                       "hash-object must have written a real blob")

        let report = try await history.fsck(repoPath: repo)
        XCTAssertTrue(report.ok, "dangling objects are normal history churn, not corruption")
        XCTAssertGreaterThan(report.danglingCount, 0,
                             "the discarded commit must be counted as dangling")
        XCTAssertTrue(report.summary.contains("悬空"))
    }
}
