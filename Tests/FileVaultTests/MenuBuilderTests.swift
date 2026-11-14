import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// Menu structure (v1.2.1 redesign: sections, clickable repos, shortcuts).
final class MenuBuilderTests: XCTestCase {
    @MainActor
    func testMenuStructure() async throws {
        let root = TestSupport.makeTempDir("menutest")
        try? FileManager.default.createDirectory(atPath: root + "/vault/alpha", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: root + "/vault/beta", withIntermediateDirectories: true)
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        try await service.addRoot(path: root + "/vault")
        let statuses: [String: SyncStatus] = [
            root + "/vault/alpha": .synced,
            root + "/vault/beta": .pendingPush,
        ]
        let health = [root + "/vault/alpha": "2 次 · 36KB"]
        let items = AppDelegate.buildMenuItems(service: service, statuses: statuses,
                                               healthCache: health, target: nil)
        // v2.4.0: the update entry lives in silent auto-update, not the menu.
        XCTAssertFalse(items.contains { $0.title.contains("检查更新") || $0.title.contains("更新到") },
                       "no manual update item in the menu")
        // Headline + sections.
        XCTAssertFalse(items[0].isEnabled, "headline disabled")
        XCTAssertTrue(items[0].title.contains("仓库受守护"))
        let headers = items.filter { $0.attributedTitle?.string.contains("受保护的目录") == true || $0.attributedTitle?.string.contains("操作") == true }
        XCTAssertEqual(headers.count, 2, "two section headers")
        // Root row with count + submenu of clickable repos.
        let rootItem = items.first { $0.title.contains("vault（2）") }
        XCTAssertFalse(rootItem?.title.contains("📂") ?? true, "menu titles must be emoji-free")
        XCTAssertNotNil(rootItem?.image, "root row uses a line icon")
        XCTAssertNotNil(rootItem, "root row shows repo count")
        let sub = rootItem?.submenu
        XCTAssertNotNil(sub)
        XCTAssertEqual(sub?.items.filter { $0.action != nil && $0.title.contains("·") }.count, 2,
                       "two clickable repo rows")
        XCTAssertNotNil(sub?.items.first { $0.title.contains("在 Finder 中打开根目录") })
        let betaRow = sub?.items.first { $0.title.contains("beta") }
        XCTAssertNotNil(betaRow?.image, "repo row carries status glyph")
        XCTAssertNotNil(betaRow?.representedObject, "repo row opens the repo in Finder")
        // Actions present with shortcuts.
        XCTAssertTrue(items.contains { $0.title == "暂停自动提交" })
        XCTAssertTrue(items.contains { $0.title == "设置…" })
        XCTAssertTrue(items.contains { $0.keyEquivalent == "," && $0.title.contains("设置") })
        XCTAssertTrue(items.contains { $0.keyEquivalent == "q" && $0.title.contains("退出") })
        XCTAssertTrue(items.contains { $0.title == "关于 FileVault" })
        XCTAssertTrue(items.contains { $0.title.contains("立即提交全部") })
        try? FileManager.default.removeItem(atPath: root)
    }
}
