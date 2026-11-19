import AppKit
import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// v4.2.31: a background refresh (the 15 s poll / an external-change event)
/// must reload the WHOLE loaded window — it used to fetch the first 100 and
/// assign, collapsing pages the user had paged in and, when the row being
/// read fell off the new list, yanking the selection back to HEAD.
final class HistoryWindowPreservationTests: XCTestCase {
    @MainActor
    func testBackgroundRefreshKeepsLoadedPagesAndDeepSelection() async throws {
        let base = TestSupport.makeTempDir("hist-window-keep")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let vault = base + "/vault"
        try FileManager.default.createDirectory(atPath: vault, withIntermediateDirectories: true)
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: vault)

        // Enough commits for a second page (identity is configured by
        // RepoManager on init).
        let runner = TestSupport.newRunner()
        for i in 1...150 {
            TestSupport.write("v\(i)", to: vault + "/f\(i).md")
            _ = try await runner.run(["add", "f\(i).md"], cwd: vault)
            _ = try await runner.run(["commit", "-m", "auto: edit \(i)"], cwd: vault)
        }

        let model = HistoryModel()
        model.setActive(true)
        model.bind(AppState(service: service))
        for _ in 0..<200 where model.commits.count < 100 || !model.canLoadMore {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThanOrEqual(model.commits.count, 100)

        // The user pages in the older commits.
        model.loadMoreCommits()
        for _ in 0..<200 where model.loadingMore || model.canLoadMore {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let loaded = model.commits.count
        XCTAssertGreaterThan(loaded, 100, "the second page was paged in")

        // …and is reading a DEEP row, beyond the first page.
        let deep = model.commits[140]
        model.selectCommit(deep.hash)
        for _ in 0..<100 where model.selectedCommitHash != deep.hash || model.files.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(model.selectedCommitHash, deep.hash)
        XCTAssertFalse(model.files.isEmpty, "the deep commit's files are on screen")

        // A commit lands on HEAD (exactly what the watcher's own auto-commits
        // do during active editing) and the poll fires the app's reload path.
        let firstBefore = model.commits.first?.hash
        TestSupport.write("head mover", to: vault + "/head-mover.md")
        _ = try await service.repoManager.commitAll(path: vault, message: "external edit moved HEAD")
        model.periodicRefresh()
        for _ in 0..<100 where model.commits.first?.hash == firstBefore {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // The reload keeps the WINDOW SIZE the user had paged in: it refetches
        // the newest `loaded` commits (the window slides — the oldest row
        // drops off, new HEAD enters). Without the fix the count collapsed to
        // 100, the deep row vanished, and the selection snapped to HEAD with
        // HEAD's file list.
        XCTAssertNotEqual(model.commits.first?.hash, firstBefore,
                          "the new HEAD entered the window")
        XCTAssertEqual(model.commits.count, loaded,
                       "the background reload keeps the paged-in window size")
        XCTAssertTrue(model.commits.contains { $0.hash == deep.hash },
                      "the deep row is still in the window")
        XCTAssertEqual(model.selectedCommitHash, deep.hash,
                       "the row being read survives the background reload")
        XCTAssertFalse(model.files.isEmpty, "the file list under review is not blanked")
    }
}
