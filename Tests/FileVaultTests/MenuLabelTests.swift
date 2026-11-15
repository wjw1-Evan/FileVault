import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// Menu label helpers (v4.0: one label per protected folder, carrying status).
final class MenuLabelTests: XCTestCase {
    @MainActor
    func testRootLabelCarriesStatus() {
        XCTAssertEqual(MenuLabels.root("工作", status: .synced), "工作（已同步）")
        XCTAssertEqual(MenuLabels.root("工作", status: .noRemote), "工作（仅本地）")
        XCTAssertEqual(MenuLabels.root("vault", status: .failed), "vault（失败）")
        XCTAssertEqual(MenuLabels.root("vault", status: .pendingPush), "vault（待推送）")
        XCTAssertEqual(MenuLabels.root("vault", status: .pushing), "vault（同步中）")
    }

    /// Every status produces a distinct, human-readable label (old repo-count
    /// label is gone: a root is a repo, so it announces how it stands).
    @MainActor
    func testEveryStatusHasItsOwnLabel() {
        let all: [SyncStatus] = [.noRemote, .synced, .pendingPush, .pushing, .failed]
        let labels = all.map { MenuLabels.root("vault", status: $0) }
        XCTAssertEqual(Set(labels).count, all.count, "statuses must not collapse into one label")
        for (status, label) in zip(all, labels) {
            XCTAssertTrue(label.hasPrefix("vault（"), "label names the folder: \(label)")
            XCTAssertTrue(label.contains(FVStatusMeta.forSync(status).label), "label carries the status: \(label)")
        }
    }

    @MainActor
    func testOverflowMenuTitle() {
        XCTAssertEqual(MenuLabels.more, "更多")
    }

    /// The menu headline must stay a short single line no matter the state.
    @MainActor
    func testStatusLineStaysShort() async throws {
        let root = TestSupport.makeTempDir("menushort")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try? FileManager.default.createDirectory(atPath: root + "/vault/a", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: root + "/vault/b", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: root + "/vault/c", withIntermediateDirectories: true)
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        try await service.addRoot(path: root + "/vault")

        let state = AppState(service: service)
        await state.refresh()
        XCTAssertEqual(state.statusLine, "1 个文件夹 · 正常", "folder count, not sub-repo count")
        XCTAssertLessThanOrEqual(state.statusLine.count, 20)

        state.toggleGlobalPause()
        await state.refresh()
        XCTAssertEqual(state.statusLine, "1 个文件夹 · 已暂停")

        state.toggleGlobalPause()
        await state.refresh()
        XCTAssertEqual(state.statusLine, "1 个文件夹 · 正常")
    }
}
