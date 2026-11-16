import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// Menu bar DATA (v3.0.0 SwiftUI migration): the MenuBarExtra renders from
/// AppState's published menu data — structural assertions live here.
///
/// v4.0: one menu entry per protected folder, each carrying its own SyncStatus.
final class MenuDataTests: XCTestCase {
    @MainActor
    func testMenuStructure() async throws {
        let root = TestSupport.makeTempDir("menutest")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try? FileManager.default.createDirectory(atPath: root + "/vault1", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: root + "/vault2", withIntermediateDirectories: true)
        TestSupport.write("a", to: root + "/vault1/a.md")
        TestSupport.write("b", to: root + "/vault2/b.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        try await service.addRoot(path: root + "/vault1")
        try await service.addRoot(path: root + "/vault2")
        let state = AppState(service: service)
        await state.refresh()

        // Headline data: one folder count (not a repo count) and the overall state.
        XCTAssertEqual(state.statusLine, "2 个文件夹 · 正常")
        XCTAssertLessThanOrEqual(state.statusLine.count, 20, "menu headline must stay short")
        XCTAssertFalse(state.statusLine.contains("📂"), "menu data must be emoji-free")
        XCTAssertFalse(state.statusLine.contains("v"), "version moved out of the menu headline")

        // ONE entry per root, each carrying its own status; no nested repo rows.
        XCTAssertEqual(state.roots.count, 2)
        XCTAssertEqual(state.rootCount, state.roots.count, "rootCount matches the menu entries")
        XCTAssertEqual(Set(state.roots.map(\.name)), ["vault1", "vault2"])
        for entry in state.roots {
            XCTAssertFalse(entry.name.isEmpty)
            XCTAssertFalse(entry.path.isEmpty)
            XCTAssertTrue(entry.path.hasSuffix(entry.name))
            // Every entry carries a SyncStatus (these roots have no remote yet).
            XCTAssertEqual(entry.status, .noRemote, "no remote configured -> 仅本地")
        }

        // v4.2.22: auto-commit is always on — there is no pause state to expose.
    }
}
