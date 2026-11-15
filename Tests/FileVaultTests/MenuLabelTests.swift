import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// Menu label helpers (v3.1.5 menu simplification).
final class MenuLabelTests: XCTestCase {
    @MainActor
    func testRootLabelCountsRepos() {
        XCTAssertEqual(MenuLabels.root("工作", repoCount: 3), "工作（3）")
        XCTAssertEqual(MenuLabels.root("vault", repoCount: 0), "vault（0）")
    }

    @MainActor
    func testRepoLabelIsJustTheName() {
        XCTAssertEqual(MenuLabels.repo("论文"), "论文")
        XCTAssertFalse(MenuLabels.repo("论文").contains("次"), "no health/commit text in menu rows")
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
        XCTAssertEqual(state.statusLine, "3 个仓库 · 正常")
        XCTAssertLessThanOrEqual(state.statusLine.count, 20)

        state.toggleGlobalPause()
        await state.refresh()
        XCTAssertEqual(state.statusLine, "3 个仓库 · 已暂停")

        state.toggleGlobalPause()
        await state.refresh()
        XCTAssertEqual(state.statusLine, "3 个仓库 · 正常")
    }
}
