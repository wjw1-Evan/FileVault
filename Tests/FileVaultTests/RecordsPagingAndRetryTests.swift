import AppKit
import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// v4.2.31 records-window round (fix-records): pins the two contracts behind
/// the v4.2.30 affordances — subject search must be able to REACH matches
/// beyond the first loaded page (previously only the empty-result case got a
/// way forward), and a scan error must clear on retry once the repo heals.
final class HistorySearchPagingTests: XCTestCase {
    @MainActor
    func testSubjectSearchReachesMatchesBeyondTheLoadedWindow() async throws {
        let base = TestSupport.makeTempDir("hist-paging")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let vault = base + "/vault"
        try FileManager.default.createDirectory(atPath: vault, withIntermediateDirectories: true)
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: vault)

        // 110 direct commits (identity is configured by RepoManager on init):
        // enough to spill past the 100-commit window the model loads first.
        let runner = TestSupport.newRunner()
        for i in 1...110 {
            TestSupport.write("v\(i)", to: vault + "/f\(i).md")
            _ = try await runner.run(["add", "f\(i).md"], cwd: vault)
            // git log is newest-first: with 110 commits the first page
            // covers the newest ~100, so the needle must live near the
            // OLDEST end to actually land on page two.
            _ = try await runner.run(["commit", "-m",
                                      i == 5 ? "needle beyond the loaded window" : "auto: edit \(i)"],
                                     cwd: vault)
        }

        let model = HistoryModel()
        model.bind(AppState(service: service))
        for _ in 0..<200 where model.commits.count < 100 || !model.canLoadMore {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThanOrEqual(model.commits.count, 100)
        XCTAssertTrue(model.canLoadMore, "110+ commits → older pages exist")

        // The needle lives on the second page: the loaded window cannot see
        // it. The v4.2.30 promise is a way forward, and v4.2.31 extends it to
        // partial-match searches via the bottom pager.
        model.searchText = "needle beyond the loaded window"
        XCTAssertTrue(model.filteredCommits.isEmpty,
                      "the match is beyond the first window")
        XCTAssertTrue(model.canLoadMore, "the continue-search affordance depends on this")

        model.loadMoreCommits()
        for _ in 0..<200 where model.loadingMore {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(model.loadingMore, "the pager must reset once the page lands")
        XCTAssertEqual(model.filteredCommits.count, 1,
                       "the freshly loaded page brings the match into the filtered window")
        XCTAssertEqual(model.filteredCommits.first?.subject, "needle beyond the loaded window")
    }
}

final class RecoveryRetryContractTests: XCTestCase {
    @MainActor
    func testScanErrorClearsOnRetryAfterTheRepoHeals() async throws {
        let base = TestSupport.makeTempDir("rec-retry")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let vault = base + "/vault"
        try FileManager.default.createDirectory(atPath: vault, withIntermediateDirectories: true)
        TestSupport.write("hello", to: vault + "/note.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: vault)
        let model = RecoveryModel()
        model.bind(AppState(service: service))
        for _ in 0..<100 where model.snapshot == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotNil(model.snapshot, "a healthy scan completes first")

        // Break the repo: without HEAD every read fails — the window must say
        // so instead of pretending the folder is empty (v4.2.26 contract).
        let head = vault + "/.git/HEAD"
        let headBackup = head + ".fv-test-backup"
        let fm = FileManager.default
        try fm.moveItem(atPath: head, toPath: headBackup)
        model.reload(preserveSelection: true)
        for _ in 0..<100 where model.errorText == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotNil(model.errorText, "a broken repo is an error, not an empty list")

        // The v4.2.30 重试 button contract: healing the repo and retrying
        // must clear the error and restore the scan.
        try fm.moveItem(atPath: headBackup, toPath: head)
        model.reload(preserveSelection: true)
        for _ in 0..<100 where model.errorText != nil || model.snapshot?.files.isEmpty != false {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(model.errorText)
        XCTAssertEqual(model.snapshot?.deletedCount ?? 0, 0)
        XCTAssertFalse(model.snapshot?.files.isEmpty ?? true, "the healed scan lists the tree again")
    }
}
