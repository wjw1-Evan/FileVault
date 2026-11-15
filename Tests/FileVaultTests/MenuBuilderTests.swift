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

        // Headline data: count + no emoji + no manual update concept.
        XCTAssertTrue(state.statusLine.contains("2 个仓库受守护"))
        XCTAssertFalse(state.statusLine.contains("📂"), "menu data must be emoji-free")

        // One root entry with two repo rows, each carrying status + health.
        XCTAssertEqual(state.roots.count, 1)
        let entry = try XCTUnwrap(state.roots.first)
        XCTAssertEqual(entry.name, "vault")
        XCTAssertEqual(entry.repos.count, 2)
        XCTAssertEqual(Set(entry.repos.map(\.name)), ["alpha", "beta"])
        for repo in entry.repos {
            XCTAssertFalse(repo.health.isEmpty, "repo row carries health info")
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
