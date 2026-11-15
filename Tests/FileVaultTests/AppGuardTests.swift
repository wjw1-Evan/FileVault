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
        // Feedback appears quickly; poll (probe-wave threads can delay blocks).
        var earlyMessage = ""
        for _ in 0..<20 {
            earlyMessage = controller.messageLabels[repoPath]?.stringValue ?? ""
            if earlyMessage.contains("已保存") || earlyMessage.contains("失败") { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTAssertTrue(earlyMessage.contains("已保存") || earlyMessage.contains("失败"),
                      "inline feedback expected, got: '\(earlyMessage)'")
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
    private var base: String!
    private var service: FileVaultService!
    private var repos: RepoManager!
    private var controller: HistoryWindowController!

    @MainActor
    private func makeWindow() async throws {
        base = TestSupport.makeTempDir("histfull")
        try? FileManager.default.createDirectory(atPath: base + "/vault1/alpha", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: base + "/vault1/beta", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: base + "/vault2/gamma", withIntermediateDirectories: true)
        service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        repos = service.repoManager!
        try await service.addRoot(path: base + "/vault1")
        try await service.addRoot(path: base + "/vault2")
        TestSupport.write("g", to: base + "/vault2/gamma/g.md")
        _ = try await repos.commitAll(path: base + "/vault2/gamma", message: "gamma change")
        controller = HistoryWindowController(service: service)
        controller.showWindow(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        try await Task.sleep(nanoseconds: 1_200_000_000)
    }

    private func waitCommitLoad() async {
        try? await Task.sleep(nanoseconds: 1_200_000_000)
    }

    @MainActor
    func test01TwoLevelPickerAndCommits() async throws {
        try await makeWindow()
        defer { try? FileManager.default.removeItem(atPath: base) }
        XCTAssertEqual(controller.rootPopup?.numberOfItems, 2)
        XCTAssertEqual(controller.currentRootPath(), base + "/vault1")
        XCTAssertEqual(controller.currentFolders.count, 2)
        XCTAssertEqual(controller.commits.count, 1)
        controller.repoPopup?.selectItem(at: 1)
        controller.repoChanged()
        await waitCommitLoad()
        XCTAssertEqual(controller.currentRepo(), base + "/vault1/beta")
        XCTAssertEqual(controller.commits.count, 1)
        controller.rootPopup?.selectItem(at: 1)
        controller.rootChanged()
        await waitCommitLoad()
        XCTAssertEqual(controller.currentRootPath(), base + "/vault2")
        XCTAssertEqual(controller.repoPopup?.numberOfItems, 1)
        XCTAssertEqual(controller.commits.count, 2)
        try? FileManager.default.removeItem(atPath: base)
    }

    @MainActor
    func test02InlineRestoreButtonsWired() async throws {
        try await makeWindow()
        defer { try? FileManager.default.removeItem(atPath: base) }
        TestSupport.write("x", to: base + "/vault1/alpha/x.md")
        _ = try await repos.commitAll(path: base + "/vault1/alpha", message: "alpha adds x")
        controller.repoPopup?.selectItem(at: 0)
        controller.repoChanged()
        await waitCommitLoad()
        controller.table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        // The changed-files table carries an inline restore button per row.
        XCTAssertEqual(controller.changedFiles.count, 1)
        XCTAssertEqual(controller.changedFiles.first?.path, "x.md")
        var found: NSButton?
        func walk(_ v: NSView) {
            if let b = v as? NSButton, b.title == "恢复", b.identifier?.rawValue == "x.md" { found = b }
            for sub in v.subviews { walk(sub) }
        }
        walk(controller.window?.contentView ?? NSView())
        XCTAssertNotNil(found, "inline restore button must exist for x.md")
        XCTAssertNotNil(found?.target, "restore button must be wired")
        try? FileManager.default.removeItem(atPath: base)
    }

    @MainActor
    func test03RestoreCorePathChangesContent() async throws {
        try await makeWindow()
        defer { try? FileManager.default.removeItem(atPath: base) }
        TestSupport.write("v1", to: base + "/vault2/gamma/g.md")
        _ = try await repos.commitAll(path: base + "/vault2/gamma", message: "gamma v2")
        let controller2 = HistoryWindowController(service: service)
        _ = controller2.window
        // Select gamma's oldest commit via the UI pickers.
        controller2.rootPopup?.selectItem(at: 1)
        controller2.rootChanged()
        await waitCommitLoad()
        let timeline = try await service.history.fileHistory(repoPath: base + "/vault2/gamma", file: "g.md")
        XCTAssertEqual(timeline.count, 2)
        let oldest = timeline.last!
        XCTAssertEqual(oldest.subject, "gamma change")
        try await service.history.restoreFile(repoPath: base + "/vault2/gamma", file: "g.md", to: oldest.hash)
        let content = try String(contentsOfFile: base + "/vault2/gamma/g.md", encoding: .utf8)
        XCTAssertEqual(content, "g", "restored to first-version content")
        try? FileManager.default.removeItem(atPath: base)
    }

    @MainActor
    func test04EmptyStates() async throws {
        try await makeWindow()
        defer { try? FileManager.default.removeItem(atPath: base) }
        try? FileManager.default.createDirectory(atPath: base + "/empty", withIntermediateDirectories: true)
        try await service.addRoot(path: base + "/empty")
        controller.rootChanged()
        await waitCommitLoad()
        XCTAssertEqual(controller.rootPopup?.numberOfItems, 3, "stale root list refreshed")
        controller.rootPopup?.selectItem(at: 2)
        controller.rootChanged()
        await waitCommitLoad()
        XCTAssertTrue(controller.currentFolders.isEmpty)
        XCTAssertEqual(controller.repoPopup?.numberOfItems, 0, "no folders in an empty root")
        try? FileManager.default.removeItem(atPath: base)
    }
}

/// File-centric core: fileHistory filters to the file's own commits.
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
        XCTAssertFalse(timeline.contains { $0.subject == "b only" })
        try? FileManager.default.removeItem(atPath: base)
    }
}


/// The 添加根目录 button must be wired (the "click no response" report).
final class AddRootButtonTests: XCTestCase {
    @MainActor
    func testAddRootButtonWired() throws {
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: TestSupport.makeTempDir("addbtn")))
        let controller = SettingsWindowController(service: service)
        defer { controller.window?.close() }
        var found: NSButton?
        func walk(_ v: NSView) {
            if let b = v as? NSButton, b.title.contains("添加根目录") { found = b }
            for sub in v.subviews { walk(sub) }
        }
        walk(controller.window?.contentView ?? NSView())
        let btn = try XCTUnwrap(found, "添加根目录 button must exist")
        XCTAssertNotNil(btn.target, "target must be wired")
        XCTAssertNotNil(btn.action, "action must be wired")
        XCTAssertEqual(btn.action?.description.contains("addRootAction"), true)
    }

    /// v2.6.3 single-entry invariant: the dashboard must NOT carry its own
    /// add-root button — root management lives only in 设置. The duplicated
    /// implementation had already drifted (it swallowed add failures).
    @MainActor
    func testDashboardHasNoAddRootButton() throws {
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: TestSupport.makeTempDir("dashbtn")))
        let controller = DashboardWindowController(service: service)
        defer { controller.window?.close() }
        var found: NSButton?
        func walk(_ v: NSView) {
            if let b = v as? NSButton, b.title.contains("添加根目录") { found = b }
            for sub in v.subviews { walk(sub) }
        }
        walk(controller.window?.contentView ?? NSView())
        XCTAssertNil(found, "dashboard must not duplicate the 添加根目录 entry (single entry = 设置)")
    }
}


/// v2.6.0: content adapts to manual window resize (width AND height).
final class ResizeAdaptationTests: XCTestCase {
    @MainActor
    func testHistoryTableFlexesWithWindow() async throws {
        let base = TestSupport.makeTempDir("resize")
        try? FileManager.default.createDirectory(atPath: base + "/vault/work", withIntermediateDirectories: true)
        TestSupport.write("s", to: base + "/vault/work/s.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: base + "/vault")
        let controller = HistoryWindowController(service: service)
        controller.showWindow(nil)
        controller.window?.setContentSize(NSSize(width: 660, height: 560))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        guard let tableScroll = firstScrollView(controller.window?.contentView) else {
            return XCTFail("table scroll missing")
        }
        let w1 = tableScroll.frame.width
        let h1 = tableScroll.frame.height
        // Grow the window; the table must absorb BOTH dimensions.
        controller.window?.setContentSize(NSSize(width: 900, height: 760))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let w2 = tableScroll.frame.width
        let h2 = tableScroll.frame.height
        XCTAssertGreaterThan(w2, w1 + 100, "table width grows with window (\(w1) -> \(w2))")
        XCTAssertGreaterThan(h2, h1 + 80, "table height grows with window (\(h1) -> \(h2))")
        try? FileManager.default.removeItem(atPath: base)
    }

    private func firstScrollView(_ v: NSView?) -> NSScrollView? {
        guard let v else { return nil }
        if let s = v as? NSScrollView { return s }
        for sub in v.subviews {
            if let s = firstScrollView(sub) { return s }
        }
        return nil
    }
}
