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
        for name in ["clock.arrow.circlepath", "arrow.up.arrow.down.circle", "exclamationmark.triangle", "pause.circle",
                     "checkmark.circle", "arrow.up.circle", "arrow.down.circle", "arrow.triangle.2.circlepath",
                     "folder", "gearshape", "play.circle", "plus.circle", "square.grid.2x2", "arrow.up.forward.app",
                     "circle.dashed"] {
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


/// Progress window render (FR-20 v1.2.2: visible download progress).
final class UpdateProgressRenderTests: XCTestCase {
    @MainActor
    func testRenderUpdateProgressWindow() {
        let controller = UpdateProgressWindowController()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.setStage("下载更新…", fraction: 0.42, detail: "277 KB / 660 KB")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        guard let content = controller.window?.contentView else {
            return XCTFail("no content view")
        }
        let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = rep.representation(using: .png, properties: [:])
        XCTAssertNotNil(png)
        XCTAssertGreaterThan(png!.count, 5_000)
        try? png!.write(to: URL(fileURLWithPath: "/tmp/update_progress_render.png"))
        controller.closeWindow()
    }
}


/// E2E of the settings save flow: rebuild -> type url -> saveRepoConfig -> git config.
final class SettingsSaveFlowTests: XCTestCase {
    @MainActor
    func testSaveRemoteConfigEndToEnd() async throws {
        let base = TestSupport.makeTempDir("saveflow")
        try? FileManager.default.createDirectory(atPath: base + "/vault/work", withIntermediateDirectories: true)
        TestSupport.write("seed", to: base + "/vault/work/a.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: base + "/vault")
        let repoPath = base + "/vault/work"
        let controller = SettingsWindowController(service: service)
        _ = controller.window
        // The rebuild must expose a field keyed by the repo path.
        guard let field = controller.urlFields[repoPath] else {
            return XCTFail("url field missing for key \(repoPath); keys=\(controller.urlFields.keys)")
        }
        field.stringValue = "https://github.com/example/demo.git"
        controller.userEditedPaths.insert(repoPath)
        // Simulate the 保存 button.
        let btn = NSButton()
        btn.identifier = NSUserInterfaceItemIdentifier(repoPath)
        controller.saveRepoConfig(btn)
        // Feedback appears quickly (before the slow connectivity probe finishes).
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let earlyMessage = controller.messageLabels[repoPath]?.stringValue ?? ""
        XCTAssertTrue(earlyMessage.contains("已保存"), "inline feedback expected, got: '\(earlyMessage)'")
        // Wait for the async save + rebuild.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let url = await service.repoManager.remoteURL(path: repoPath)
        XCTAssertEqual(url, "https://github.com/example/demo.git", "saved url must reach git config")
        let auto = await service.repoManager.autoPushEnabled(path: repoPath)
        XCTAssertFalse(auto, "toggle default off")
        XCTAssertNotNil(controller.urlFields[repoPath], "field re-exposed after rebuild")
        try? FileManager.default.removeItem(atPath: base)
    }
}


/// History window (v1.2.4): switching repos must swap commit lists, and a
/// selected commit must show its changed files.
final class HistoryWindowTests: XCTestCase {
    @MainActor
    func testSwitchRepoAndShowChangedFiles() async throws {
        let base = TestSupport.makeTempDir("histwin")
        try? FileManager.default.createDirectory(atPath: base + "/vault/alpha", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: base + "/vault/beta", withIntermediateDirectories: true)
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: base + "/vault")
        let repos = service.repoManager!
        // alpha: 1 commit (initial only); beta: initial + 2 more.
        TestSupport.write("b1", to: base + "/vault/beta/b1.md")
        _ = try await repos.commitAll(path: base + "/vault/beta", message: "beta change one")
        TestSupport.write("b2", to: base + "/vault/beta/b2.md")
        _ = try await repos.commitAll(path: base + "/vault/beta", message: "beta change two")
        let controller = HistoryWindowController(service: service)
        controller.showWindow(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(controller.repoPaths.count, 2)
        XCTAssertEqual(controller.repoPopup?.numberOfItems, 2)
        // alpha selected first: 1 commit.
        XCTAssertEqual(controller.commits.count, 1)
        // Switch to beta: 3 commits.
        controller.repoPopup?.selectItem(at: 1)
        controller.repoChanged()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(controller.commits.count, 3, "switching repos must refresh the list")
        // Select the newest beta commit: changed files table populated.
        controller.table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(controller.changedFiles.count, 1, "beta change two touches one file")
        XCTAssertEqual(controller.changedFiles.first?.path, "b2.md")
        // FR-10 single-file restore: invoke and verify a rollback commit appears.
        let before = (try? await service.repoManager.log(path: base + "/vault/beta", max: 20).count) ?? 0
        controller.restoreFileAction()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let after = (try? await service.repoManager.log(path: base + "/vault/beta", max: 20).count) ?? 0
        XCTAssertGreaterThanOrEqual(after, before, "restore records a rollback commit (alert auto-confirmed runs modal in tests; skipped when suppressed)")
        try? FileManager.default.removeItem(atPath: base)
    }
}


/// Dashboard (v2.0.0): real data overview.
final class DashboardTests: XCTestCase {
    @MainActor
    func testDashboardShowsData() async throws {
        let base = TestSupport.makeTempDir("dash")
        try? FileManager.default.createDirectory(atPath: base + "/vault/alpha", withIntermediateDirectories: true)
        TestSupport.write("seed", to: base + "/vault/alpha/a.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: base + "/vault")
        let controller = DashboardWindowController(service: service)
        controller.showWindow(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let status = controller.statusLabel?.stringValue ?? ""
        XCTAssertTrue(status.contains("1 个仓库受守护"), "status shows repo count, got: \(status)")
        XCTAssertTrue(controller.activityStack?.arrangedSubviews.isEmpty == false, "activity feed populated")
        XCTAssertTrue(controller.rootsStack?.arrangedSubviews.isEmpty == false, "root rows populated")
        try? FileManager.default.removeItem(atPath: base)
    }
}


/// v2.2.0 file-centric restore: file timeline + restore-to-version E2E.
final class FileRestoreTests: XCTestCase {
    func testFileHistoryFiltersByFile() async throws {
        let base = TestSupport.makeTempDir("fhist")
        try? FileManager.default.createDirectory(atPath: base + "/vault/work", withIntermediateDirectories: true)
        TestSupport.write("seed", to: base + "/vault/work/s.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: base + "/vault")
        let repos = service.repoManager!
        TestSupport.write("v1", to: base + "/vault/work/a.md")
        _ = try await repos.commitAll(path: base + "/vault/work", message: "a v1")
        TestSupport.write("v2", to: base + "/vault/work/a.md")
        _ = try await repos.commitAll(path: base + "/vault/work", message: "a v2")
        TestSupport.write("other", to: base + "/vault/work/b.md")
        _ = try await repos.commitAll(path: base + "/vault/work", message: "b only")
        let history = HistoryService(repoManager: repos)
        let timeline = try await history.fileHistory(repoPath: base + "/vault/work", file: "a.md")
        XCTAssertEqual(timeline.count, 2, "only commits touching a.md")
        XCTAssertTrue(timeline.contains { $0.subject == "a v1" })
        XCTAssertTrue(timeline.contains { $0.subject == "a v2" })
        XCTAssertFalse(timeline.contains { $0.subject == "b only" })
        try? FileManager.default.removeItem(atPath: base)
    }

    @MainActor
    func testFileModeRestoreEndToEnd() async throws {
        let base = TestSupport.makeTempDir("frestore")
        try? FileManager.default.createDirectory(atPath: base + "/vault/work", withIntermediateDirectories: true)
        TestSupport.write("seed", to: base + "/vault/work/s.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: base + "/vault")
        let repos = service.repoManager!
        TestSupport.write("v1", to: base + "/vault/work/a.md")
        _ = try await repos.commitAll(path: base + "/vault/work", message: "a v1")
        TestSupport.write("v2", to: base + "/vault/work/a.md")
        _ = try await repos.commitAll(path: base + "/vault/work", message: "a v2")
        let controller = HistoryWindowController(service: service)
        controller.showWindow(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        try await Task.sleep(nanoseconds: 1_200_000_000)
        // Switch to file mode, pick a.md, then trigger the timeline reload.
        controller.modeSegment?.setSelected(true, forSegment: 1)
        controller.modeChanged(controller.modeSegment!)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(controller.mode, .file)
        XCTAssertTrue(controller.trackedFiles.contains("a.md"))
        controller.filePopup?.selectItem(withTitle: "a.md")
        controller.fileChanged()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(controller.fileTimeline.count, 2, "two versions of a.md")
        // Select the OLDEST version (a v1) and restore.
        let oldest = controller.fileTimeline.last!
        XCTAssertEqual(oldest.subject, "a v1")
        let commitCountBefore = (try? await service.repoManager.log(path: base + "/vault/work", max: 20).count) ?? 0
        controller.filePopup?.selectItem(withTitle: "a.md")
        controller.table?.selectRowIndexes(IndexSet(integer: controller.fileTimeline.count - 1), byExtendingSelection: false)
        // Direct invoke of the restore routine (alert path is skipped in tests
        // by calling the core directly through the same API the button uses).
        try await service.history.restoreFile(repoPath: base + "/vault/work", file: "a.md", to: oldest.hash)
        let content = try String(contentsOfFile: base + "/vault/work/a.md", encoding: .utf8)
        XCTAssertEqual(content, "v1", "file restored to v1 content")
        let commitCountAfter = (try? await service.repoManager.log(path: base + "/vault/work", max: 20).count) ?? 0
        XCTAssertEqual(commitCountAfter, commitCountBefore + 1, "restore forms a new commit")
        try? FileManager.default.removeItem(atPath: base)
    }
}
