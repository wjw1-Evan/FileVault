import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// Regression guards for bundle-less execution (the launch-crash class).
final class AppGuardTests: XCTestCase {
    /// UNUserNotificationCenter.current() throws an uncatchable ObjC exception
    /// without an app bundle; setup/notify must degrade instead of crashing.
    /// This test would have CRASHED the suite before the guard was added.
    func testNotificationServiceDegradesWithoutBundle() {
        let svc = NotificationService()
        svc.setup()               // must not throw/crash
        svc.notifyFailure("t", "b") // must be a no-op when not authorized
        // And repeated setup must stay harmless.
        svc.setup()
    }

    func testLaunchAtLoginGating() {
        // The test runner is not our .app bundle, so the feature must report
        // unavailable and stay inert.
        XCTAssertFalse(LaunchAtLogin.available)
        XCTAssertFalse(LaunchAtLogin.isEnabled)
        XCTAssertNoThrow(try LaunchAtLogin.setEnabled(true))
        XCTAssertFalse(LaunchAtLogin.isEnabled)
    }

    func testMenuSignatureChangesWithStatus() async throws {
        let root = TestSupport.makeTempDir("sigsvc")
        try? FileManager.default.createDirectory(atPath: root + "/vault/alpha", withIntermediateDirectories: true)
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        try await service.addRoot(path: root + "/vault")
        let repoPath = root + "/vault/alpha"
        let s1 = AppDelegate.menuSignature(service: service, statuses: [repoPath: .synced])
        let s2 = AppDelegate.menuSignature(service: service, statuses: [repoPath: .failed])
        XCTAssertNotEqual(s1, s2, "failed vs synced must produce different signatures")
        try? FileManager.default.removeItem(atPath: root)
    }
}


/// UI-structure regression: the settings window must actually contain the
/// root-directory management UI (caught the v1.1.0 layout bug in real use).
final class SettingsUIStructureTests: XCTestCase {
    @MainActor
    func testSettingsWindowContainsRootManagementUI() async throws {
        let root = TestSupport.makeTempDir("settingsui")
        try? FileManager.default.createDirectory(atPath: root + "/vault/work", withIntermediateDirectories: true)
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        try await service.addRoot(path: root + "/vault")
        let controller = SettingsWindowController(service: service)
        defer { controller.window?.close() }
        guard let content = controller.window?.contentView else {
            return XCTFail("settings window has no content view")
        }
        var foundAddButton = false
        var foundGrid = false
        var foundUrlField = false
        var foundOpenButton = false
        func walk(_ v: NSView) {
            if let b = v as? NSButton, b.title.contains("添加根目录") { foundAddButton = true }
            if let b = v as? NSButton, b.title.contains("打开"), b.identifier?.rawValue.contains("/vault") == true {
                foundOpenButton = true
            }
            if let g = v as? NSGridView, g === controller.grid { foundGrid = true }
            if let f = v as? NSTextField, f.placeholderString?.contains("远程仓库地址") == true { foundUrlField = true }
            for sub in v.subviews { walk(sub) }
        }
        walk(content)
        XCTAssertTrue(foundGrid, "settings grid must be attached to the window (v1.1.0 regression)")
        XCTAssertTrue(foundAddButton, "添加根目录 button must be visible")
        XCTAssertTrue(foundUrlField, "per-repo remote config field must be visible")
        XCTAssertTrue(foundOpenButton, "root 打开 button must exist with the root path identifier (FR-21)")
        try? FileManager.default.removeItem(atPath: root)
    }
}
