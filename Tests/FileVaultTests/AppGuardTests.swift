import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// Regression guards for bundle-less execution (the launch-crash class).
final class AppGuardTests: XCTestCase {
    /// UNUserNotificationCenter.current() throws an uncatchable ObjC exception
    /// without an app bundle; setup/notify must degrade instead of crashing.
    func testNotificationServiceDegradesWithoutBundle() {
        let svc = NotificationService()
        svc.setup()                 // must not throw/crash
        svc.notifyFailure("t", "b") // must be a no-op when not authorized
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
        let s1 = AppState.menuSignature(service: service, statuses: [repoPath: .synced])
        let s2 = AppState.menuSignature(service: service, statuses: [repoPath: .failed])
        XCTAssertNotEqual(s1, s2, "failed vs synced must produce different signatures")
        try? FileManager.default.removeItem(atPath: root)
    }
}

/// Menu bar icon state mapping (FR-08, v1.1.3 — fixes invisible glyph).
final class StatusSymbolTests: XCTestCase {
    func testSymbolMapping() {
        let all: [SyncStatus] = [.noRemote, .synced, .pendingPush, .pushing, .failed]
        XCTAssertEqual(AppState.statusSymbol(paused: false, envReady: true, statuses: []), "clock.arrow.circlepath")
        XCTAssertEqual(AppState.statusSymbol(paused: false, envReady: true, statuses: [.noRemote]), "clock.arrow.circlepath")
        XCTAssertEqual(AppState.statusSymbol(paused: false, envReady: true, statuses: [.synced]), "clock.arrow.circlepath")
        // Pending / pushing.
        XCTAssertEqual(AppState.statusSymbol(paused: false, envReady: true, statuses: [.pendingPush]), "arrow.up.arrow.down.circle")
        XCTAssertEqual(AppState.statusSymbol(paused: false, envReady: true, statuses: [.pushing]), "arrow.up.arrow.down.circle")
        // Paused / env failure / push failure.
        XCTAssertEqual(AppState.statusSymbol(paused: true, envReady: true, statuses: all), "pause.circle")
        XCTAssertEqual(AppState.statusSymbol(paused: false, envReady: false, statuses: []), "exclamationmark.triangle")
        XCTAssertEqual(AppState.statusSymbol(paused: false, envReady: true, statuses: [.failed]), "exclamationmark.triangle")
    }

    func testSymbolsExistInSystem() {
        for name in ["clock.arrow.circlepath", "arrow.up.arrow.down.circle",
                     "pause.circle", "exclamationmark.triangle", "folder",
                     "gearshape", "arrow.up.forward.app"] {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil),
                            "SF Symbol \(name) must exist")
        }
    }
}

/// v2.6.5: multicast state listeners (window auto-refresh foundation).
final class StateListenerTests: XCTestCase {
    private final class Counter {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testAddFireRemove() {
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: TestSupport.makeTempDir("listeners")))
        let counter = Counter()
        let token = service.addStateListener { counter.increment() }
        service.fireStateChange()
        XCTAssertEqual(counter.current, 1, "listener receives the state change")
        service.removeStateListener(token)
        service.fireStateChange()
        XCTAssertEqual(counter.current, 1, "removed listener no longer fires")
        try? FileManager.default.removeItem(atPath: service.configStore.directory.path)
    }
}

/// FR-10 core: file history filters to the file's own commits.
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

/// v3.0.0 SwiftUI migration: history behavior lives in HistoryModel.
final class HistoryModelTests: XCTestCase {
    @MainActor
    private func makeModel() async throws -> (HistoryModel, FileVaultService, String) {
        let base = TestSupport.makeTempDir("histmodel")
        try? FileManager.default.createDirectory(atPath: base + "/vault/alpha", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: base + "/vault/beta", withIntermediateDirectories: true)
        TestSupport.write("s", to: base + "/vault/alpha/s.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: base + "/vault")
        let app = AppState()
        app.service = service
        let model = HistoryModel()
        model.bind(app)
        return (model, service, base)
    }

    @MainActor
    func testEmptyRootsShowsGuidance() async throws {
        let base = TestSupport.makeTempDir("histmodel-empty")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        let model = HistoryModel()
        model.bind(AppState(service: service))
        XCTAssertEqual(model.statusText, "尚未添加任何根目录——先在设置中添加根目录")
        XCTAssertTrue(model.roots.isEmpty)
        try? FileManager.default.removeItem(atPath: base)
    }

    @MainActor
    func testRepoSwitchReloadsCommits() async throws {
        let (model, _, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        XCTAssertEqual(model.selectedRoot, base + "/vault")
        XCTAssertEqual(model.folders.count, 2)
        // Async commit load: poll until it lands.
        for _ in 0..<40 where model.commits.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(model.commits.count, 1)
        XCTAssertEqual(model.selectedCommitHash, model.commits.first?.hash,
                       "first commit auto-selected")
        XCTAssertFalse(model.files.isEmpty)
        XCTAssertTrue(model.statusText.contains("包含"))

        // Switch to beta (also 1 commit after ensureRepos).
        let beta = model.folders.first { $0.name == "beta" }
        model.repoChanged(beta!.path)
        XCTAssertEqual(model.selectedRepo, beta?.path)
        for _ in 0..<40 where model.commits.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(model.commits.count, 1)
        try? FileManager.default.removeItem(atPath: base)
    }

    @MainActor
    func testRestoreFeedbackAndCommitCount() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault/alpha"
        // Create a distinct second commit so restoring the first differs.
        TestSupport.write("v2", to: repoPath + "/s.md")
        _ = try await service.repoManager.commitAll(path: repoPath, message: "alpha v2")
        await model.reloadCommits()
        for _ in 0..<40 where model.commits.count < 2 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(model.commits.count, 2)
        // Select the FIRST commit (alpha 初始版本) via the selection API.
        let firstHash = model.commits.last!.hash
        model.selectCommit(firstHash)
        // Restore the selected commit's file — forms a rollback commit.
        model.restoreFile("s.md")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let log = try await service.repoManager.log(path: repoPath)
        XCTAssertEqual(log.count, 3, "restore must form a new commit")
        XCTAssertTrue(log.first!.subject.contains("rollback: 恢复 s.md"),
                      "rollback commit message: \(log.first!.subject)")
        XCTAssertTrue(model.statusText.contains("已恢复") || model.statusText.contains("包含"),
                      "feedback after restore: \(model.statusText)")
        try? FileManager.default.removeItem(atPath: base)
    }
}

/// v3.0.0 SwiftUI migration: settings behavior lives in SettingsModel.
final class SettingsModelTests: XCTestCase {
    @MainActor
    private func makeModel() async throws -> (SettingsModel, FileVaultService, String) {
        let base = TestSupport.makeTempDir("setmodel")
        try? FileManager.default.createDirectory(atPath: base + "/vault/alpha", withIntermediateDirectories: true)
        TestSupport.write("s", to: base + "/vault/alpha/s.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: base + "/vault")
        let app = AppState()
        app.service = service
        let model = SettingsModel()
        model.bind(app)
        return (model, service, base)
    }

    @MainActor
    func testGeneralCardsAndRootCardsPopulate() async throws {
        let (model, _, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        XCTAssertEqual(model.rootCards.count, 1)
        XCTAssertEqual(model.rootCards.first?.repos.count, 1)
        XCTAssertEqual(model.rootCards.first?.repos.first?.name, "alpha")
        XCTAssertEqual(model.debounceSeconds, 5)
    }

    /// v3.1.3: no local threshold knob — the UI mirrors the remote's value.
    @MainActor
    func testRemoteLimitMirrorsGitHub() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault/alpha"
        _ = try await service.repoManager.runner.run(
            ["remote", "add", "origin", "https://github.com/acme/notes.git"], cwd: repoPath)
        model.reload()
        var limit = ""
        for _ in 0..<40 {
            limit = model.rootCards.first?.repos.first?.remoteLimit ?? ""
            if limit.contains("100 MB") { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(limit.contains("100 MB"), "settings must display the remote's threshold, got: \(limit)")
    }

    /// Non-GitHub remotes publish no single-file limit, so the UI says so.
    @MainActor
    func testRemoteLimitUnlimitedForLocalRemote() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault/alpha"
        let bare = URL(fileURLWithPath: base).appendingPathComponent("remote.git")
        _ = try? await service.repoManager.runner.run(["init", "--bare", bare.path])
        _ = try await service.repoManager.runner.run(["remote", "add", "origin", bare.path], cwd: repoPath)
        model.reload()
        var limit = ""
        for _ in 0..<40 {
            limit = model.rootCards.first?.repos.first?.remoteLimit ?? ""
            if limit.contains("不限制") { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(limit.contains("不限制"), "expected no remote limit, got: \(limit)")
    }

    @MainActor
    func testSaveRepoPersistsRemoteAndReportsFeedback() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault/alpha"
        let bare = URL(fileURLWithPath: base).appendingPathComponent("remote.git")
        _ = try? await service.repoManager.runner.run(["init", "--bare", bare.path])
        model.urlBinding(repoPath).wrappedValue = bare.path
        model.saveRepo(repoPath)
        var message = ""
        for _ in 0..<20 {
            message = model.message(repoPath)?.0 ?? ""
            if message.contains("已保存") || message.contains("失败") { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTAssertTrue(message.contains("已保存并连通"), "inline feedback expected, got: '\(message)'")
        let url = await service.repoManager.remoteURL(path: repoPath)
        XCTAssertEqual(url, bare.path, "saved url must reach git config")
    }

    @MainActor
    func testEmptyURLSaveClearsRemote() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault/alpha"
        let bare = URL(fileURLWithPath: base).appendingPathComponent("remote.git")
        _ = try? await service.repoManager.runner.run(["init", "--bare", bare.path])
        try await service.sync.configureRemote(repoPath: repoPath, url: bare.path, autoPush: false)
        model.saveRepo(repoPath)   // url binding is empty by default
        var message = ""
        for _ in 0..<20 {
            message = model.message(repoPath)?.0 ?? ""
            if message.contains("仅本地") || message.contains("失败") { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTAssertTrue(message.contains("仅本地"), "clear feedback expected, got: '\(message)'")
        let url = await service.repoManager.remoteURL(path: repoPath)
        XCTAssertNil(url, "remote must be removed")
        try? FileManager.default.removeItem(atPath: base)
    }

    @MainActor
    func testToggleLoginIntentPersists() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        model.toggleLoginIntent(true)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(service.configStore.load().general.launchAtLoginRequested)
        model.toggleLoginIntent(false)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertFalse(service.configStore.load().general.launchAtLoginRequested)
        try? FileManager.default.removeItem(atPath: base)
    }

    @MainActor
    func testGitignoreEditorSaveWritesFile() async throws {
        let (model, _, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault/alpha"
        model.openGitignoreEditor(repoPath)
        var editor = try XCTUnwrap(model.gitignoreEditor)
        XCTAssertTrue(editor.draft.contains("node_modules/"), "template must preload")
        editor.draft = ".DS_Store\n*.log\n"
        model.saveGitignore(editor)
        XCTAssertNil(model.gitignoreEditor, "editor closes after save")
        let content = try String(contentsOfFile: repoPath + "/.gitignore", encoding: .utf8)
        XCTAssertTrue(content.contains("*.log"))
        try? FileManager.default.removeItem(atPath: base)
    }
}
