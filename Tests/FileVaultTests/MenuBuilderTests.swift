import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// Menu bar DATA (v3.0.0 SwiftUI migration): the MenuBarExtra renders from
/// AppState's published menu data — structural assertions live here.
final class MenuDataTests: XCTestCase {
    @MainActor
    func testMenuStructure() async throws {
        let root = TestSupport.makeTempDir("menutest")
        try? FileManager.default.createDirectory(atPath: root + "/vault/alpha", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: root + "/vault/beta", withIntermediateDirectories: true)
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        try await service.addRoot(path: root + "/vault")
        let state = AppState(service: service)
        await state.refresh()

        // Headline data: short single-line summary, no emoji, no version spam.
        XCTAssertEqual(state.statusLine, "2 个仓库 · 正常")
        XCTAssertLessThanOrEqual(state.statusLine.count, 20, "menu headline must stay short")
        XCTAssertFalse(state.statusLine.contains("📂"), "menu data must be emoji-free")
        XCTAssertFalse(state.statusLine.contains("v"), "version moved out of the menu headline")

        // One root entry with two repo rows; rows carry name/path/status only
        // (v3.1.5: health text was dropped to keep the menu readable).
        XCTAssertEqual(state.roots.count, 1)
        let entry = try XCTUnwrap(state.roots.first)
        XCTAssertEqual(entry.name, "vault")
        XCTAssertEqual(entry.repos.count, 2)
        XCTAssertEqual(Set(entry.repos.map(\.name)), ["alpha", "beta"])
        for repo in entry.repos {
            XCTAssertFalse(repo.name.isEmpty)
            XCTAssertFalse(repo.path.isEmpty)
        }

        // Action data state.
        XCTAssertFalse(state.paused)
        state.toggleGlobalPause()
        await state.refresh()   // paused flag lands via the async refresh
        XCTAssertTrue(state.paused, "pause toggles")
        state.toggleGlobalPause()
        await state.refresh()
        XCTAssertFalse(state.paused)
        try? FileManager.default.removeItem(atPath: root)
    }
}
