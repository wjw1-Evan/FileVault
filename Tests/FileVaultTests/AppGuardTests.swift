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
        var foundUrlField = false
        var foundOpenButton = false
        var foundStatusDot = false
        func walk(_ v: NSView) {
            if let b = v as? NSButton, b.title.contains("添加根目录") { foundAddButton = true }
            if let b = v as? NSButton, b.title == "打开", b.identifier?.rawValue.contains("/vault") == true {
                foundOpenButton = true
            }
            if let f = v as? NSTextField, f.placeholderString?.contains("远程仓库地址") == true { foundUrlField = true }
            if let iv = v as? NSImageView, iv.image != nil { foundStatusDot = true }
            for sub in v.subviews { walk(sub) }
        }
        walk(content)
        XCTAssertEqual(controller.rootCards.count, 1, "one card per root (v1.2.0 card layout)")
        XCTAssertTrue(foundAddButton, "添加根目录 button must be visible")
        XCTAssertTrue(foundUrlField, "per-repo remote config field must be visible")
        XCTAssertTrue(foundOpenButton, "root 打开 button must exist with the root path identifier (FR-21)")
        XCTAssertTrue(foundStatusDot, "per-repo status glyph must be visible")
        try? FileManager.default.removeItem(atPath: root)
    }
}


/// Menu bar icon state mapping (FR-08, v1.1.3 — fixes invisible "·" glyph).
final class StatusSymbolTests: XCTestCase {
    func testSymbolMapping() {
        let all: [SyncStatus] = [.noRemote, .synced, .pendingPush, .pushing, .failed]
        // Normal / no-remote: always-visible clock glyph.
        XCTAssertEqual(AppDelegate.statusSymbol(paused: false, envReady: true, statuses: []), "clock.arrow.circlepath")
        XCTAssertEqual(AppDelegate.statusSymbol(paused: false, envReady: true, statuses: [.noRemote]), "clock.arrow.circlepath")
        XCTAssertEqual(AppDelegate.statusSymbol(paused: false, envReady: true, statuses: [.synced]), "clock.arrow.circlepath")
        // Pending / pushing.
        XCTAssertEqual(AppDelegate.statusSymbol(paused: false, envReady: true, statuses: [.pendingPush]), "arrow.up.arrow.down.circle")
        XCTAssertEqual(AppDelegate.statusSymbol(paused: false, envReady: true, statuses: [.pushing]), "arrow.up.arrow.down.circle")
        // Failure / env missing / paused.
        XCTAssertEqual(AppDelegate.statusSymbol(paused: false, envReady: true, statuses: [.failed]), "exclamationmark.triangle")
        XCTAssertEqual(AppDelegate.statusSymbol(paused: false, envReady: false, statuses: all), "exclamationmark.triangle")
        XCTAssertEqual(AppDelegate.statusSymbol(paused: true, envReady: true, statuses: all), "pause.circle")
    }

    /// Every mapped symbol must actually exist on this macOS (render proof).
    func testSymbolsExistInSystem() {
        for name in ["clock.arrow.circlepath", "arrow.up.arrow.down.circle", "exclamationmark.triangle", "pause.circle"] {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "missing symbol: \(name)")
        }
    }
}


/// Renders the settings window offscreen to a PNG (visual design review) and
/// asserts the render succeeds with a sane size.
final class SettingsRenderTests: XCTestCase {
    @MainActor
    func testRenderSettingsWindow() async throws {
        let base = TestSupport.makeTempDir("settingsrender")
        try? FileManager.default.createDirectory(atPath: base + "/vault/work", withIntermediateDirectories: true)
        TestSupport.write("seed", to: base + "/vault/work/a.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: base + "/vault")
        let repos = service.repoManager!
        let bare = URL(fileURLWithPath: base).appendingPathComponent("remote.git")
        _ = try? await repos.runner.run(["init", "--bare", bare.path])
        try? await repos.setRemote(path: base + "/vault/work", url: bare.path)
        await repos.setAutoPush(path: base + "/vault/work", enabled: true)
        // Give async fills time to land.
        let controller = SettingsWindowController(service: service)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 800_000_000)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        guard let content = controller.window?.contentView else {
            return XCTFail("no content view")
        }
        let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = rep.representation(using: .png, properties: [:])
        XCTAssertNotNil(png)
        XCTAssertGreaterThan(png!.count, 10_000, "render should be substantial")
        let out = URL(fileURLWithPath: "/tmp/settings_render.png")
        try? png!.write(to: out)
        print("[render] saved \(out.path) (\(png!.count) bytes)")
        try? FileManager.default.removeItem(atPath: base)
    }
}
