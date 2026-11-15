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
        try? FileManager.default.createDirectory(atPath: root + "/vault", withIntermediateDirectories: true)
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        try await service.addRoot(path: root + "/vault")
        let repoPath = root + "/vault"
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
        let vault = base + "/vault"
        try? FileManager.default.createDirectory(atPath: vault + "/nested", withIntermediateDirectories: true)
        TestSupport.write("seed", to: vault + "/s.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: vault)
        let repos = service.repoManager!
        // The root repo versions loose files and nested ones together.
        TestSupport.write("v1", to: vault + "/a.md")
        _ = try await repos.commitAll(path: vault, message: "a v1")
        TestSupport.write("v2", to: vault + "/nested/a.md")
        TestSupport.write("v2", to: vault + "/a.md")
        _ = try await repos.commitAll(path: vault, message: "a v2")
        TestSupport.write("other", to: vault + "/b.md")
        _ = try await repos.commitAll(path: vault, message: "b only")
        let history = HistoryService(repoManager: repos)
        let timeline = try await history.fileHistory(repoPath: vault, file: "a.md")
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
        // v4.0: the root folder is the one repository (loose file + nested file).
        try? FileManager.default.createDirectory(atPath: base + "/vault/nested", withIntermediateDirectories: true)
        TestSupport.write("s", to: base + "/vault/s.md")
        TestSupport.write("n", to: base + "/vault/nested/n.md")
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
        XCTAssertEqual(model.statusText, "尚未添加任何文件夹——先在设置中添加文件夹")
        XCTAssertTrue(model.roots.isEmpty)
        try? FileManager.default.removeItem(atPath: base)
    }

    @MainActor
    func testRootSwitchReloadsCommits() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        XCTAssertEqual(model.selectedRoot, base + "/vault")
        XCTAssertEqual(model.selectedRepo, base + "/vault", "the root IS the repo")
        XCTAssertEqual(model.roots.count, 1)
        // Async commit load: poll until it lands.
        for _ in 0..<40 where model.commits.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(model.commits.count, 1)
        XCTAssertEqual(model.selectedCommitHash, model.commits.first?.hash,
                       "first commit auto-selected")
        XCTAssertFalse(model.files.isEmpty)
        XCTAssertTrue(model.statusText.contains("包含"))

        // Add a second managed root and switch to it — selection reloads commits.
        let second = base + "/vault2"
        try? FileManager.default.createDirectory(atPath: second, withIntermediateDirectories: true)
        TestSupport.write("x", to: second + "/x.md")
        try await service.addRoot(path: second)
        model.reloadRepos()
        XCTAssertEqual(model.roots.count, 2)
        let target = try XCTUnwrap(model.roots.first { $0 != base + "/vault" })
        model.rootChanged(target)
        XCTAssertEqual(model.selectedRoot, target)
        XCTAssertEqual(model.selectedRepo, target)
        for _ in 0..<40 where model.commits.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(model.commits.count, 1)
    }


    /// While the History window is open, background auto-commits must refresh
    /// the timeline without any manual action (v2.6.5 state listener).
    @MainActor
    func testAutoCommitRefreshesOpenHistory() async throws {
        let (model, _, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        for _ in 0..<40 where model.commits.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(model.commits.count, 1, "initial history loaded")
        TestSupport.write("v2", to: base + "/vault/s.md")
        for _ in 0..<120 where model.commits.count < 2 {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertGreaterThanOrEqual(model.commits.count, 2,
                                    "open history must refresh after an auto-commit")
    }


    /// Adding or removing a protected folder while History is open must update
    /// the folder picker without reopening the window.
    @MainActor
    func testOpenHistoryTracksFolderListChanges() async throws {
        let base = TestSupport.makeTempDir("histroots")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let vault = base + "/vault"
        try? FileManager.default.createDirectory(atPath: vault, withIntermediateDirectories: true)
        TestSupport.write("s", to: vault + "/s.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        let model = HistoryModel()
        model.bind(AppState(service: service))
        XCTAssertTrue(model.roots.isEmpty)

        try await service.addRoot(path: vault)
        for _ in 0..<50 where model.roots.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(model.roots, [vault], "new folder shows up without reopening")
        XCTAssertEqual(model.selectedRepo, vault)

        await service.removeRoot(path: vault)
        for _ in 0..<50 where !model.roots.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(model.roots.isEmpty, "removed folder disappears without reopening")
        XCTAssertNil(model.selectedRepo)
        XCTAssertEqual(model.statusText, "尚未添加任何文件夹——先在设置中添加文件夹")
    }


    /// Commits made outside FileVault (terminal, fetch/pull) fire no app event;
    /// the fallback poll must pick them up without reopening the window.
    @MainActor
    func testPeriodicRefreshCatchesExternalCommits() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repo = base + "/vault"
        for _ in 0..<40 where model.commits.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(model.commits.count, 1)

        // Direct git commit: same effect as a manual terminal commit, no event.
        TestSupport.write("manual", to: repo + "/s.md")
        _ = try await service.repoManager.commitAll(path: repo, message: "manual commit")
        XCTAssertEqual(model.commits.count, 1, "no state event -> model still stale")

        model.periodicRefresh()
        for _ in 0..<40 where model.commits.count < 2 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThanOrEqual(model.commits.count, 2, "fallback poll refreshes history")
        XCTAssertEqual(model.commits.first?.subject, "manual commit")
    }

    @MainActor
    func testRestoreFeedbackAndCommitCount() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault"
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
        try? FileManager.default.createDirectory(atPath: base + "/vault/nested", withIntermediateDirectories: true)
        TestSupport.write("s", to: base + "/vault/s.md")
        TestSupport.write("n", to: base + "/vault/nested/n.md")
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
        let card = try XCTUnwrap(model.rootCards.first)
        XCTAssertEqual(card.repo.name, "vault", "one repo per root, named after the root")
        XCTAssertEqual(card.repo.id, card.path, "the repo id is the root path")
        XCTAssertNotNil(model.indexOf(card.path), "indexOf maps the root path")
        XCTAssertEqual(model.debounceSeconds, 5)
    }

    /// v3.1.3: no local threshold knob — the UI mirrors the remote's value.
    @MainActor
    func testRemoteLimitMirrorsGitHub() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault"
        _ = try await service.repoManager.runner.run(
            ["remote", "add", "origin", "https://github.com/acme/notes.git"], cwd: repoPath)
        model.reload()
        var limit = ""
        for _ in 0..<40 {
            limit = model.rootCards.first?.repo.remoteLimit ?? ""
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
        let repoPath = base + "/vault"
        let bare = URL(fileURLWithPath: base).appendingPathComponent("remote.git")
        _ = try? await service.repoManager.runner.run(["init", "--bare", bare.path])
        _ = try await service.repoManager.runner.run(["remote", "add", "origin", bare.path], cwd: repoPath)
        model.reload()
        var limit = ""
        for _ in 0..<40 {
            limit = model.rootCards.first?.repo.remoteLimit ?? ""
            if limit.contains("不限制") { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(limit.contains("不限制"), "expected no remote limit, got: \(limit)")
    }

    @MainActor
    func testSaveRepoPersistsRemoteAndReportsFeedback() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault"
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


/// Opening settings before the service finishes starting (login launch,
    /// --open-ui) must not leave an empty page: the model self-heals.
    @MainActor
    func testBindRecoversWhenServiceAppearsLater() async throws {
        let base = TestSupport.makeTempDir("setlater")
        try? FileManager.default.createDirectory(atPath: base + "/vault", withIntermediateDirectories: true)
        TestSupport.write("s", to: base + "/vault/s.md")
        let app = AppState()          // service intentionally nil at bind time
        let model = SettingsModel()
        model.bind(app)
        XCTAssertTrue(model.rootCards.isEmpty, "nothing to show before the service exists")

        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: base + "/vault")
        app.service = service

        var cards = 0
        for _ in 0..<40 {
            cards = model.rootCards.count
            if cards == 1 { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertEqual(cards, 1, "settings must recover once the service is up")
        XCTAssertEqual(model.rootCards.first?.repo.name, "vault")
        try? FileManager.default.removeItem(atPath: base)
    }

    /// Regression: the auth-mode picker used to be purely cosmetic — the chosen
    /// mode was never written to git config. Saving must persist it.
    @MainActor
    func testSaveRepoPersistsSelectedAuthMode() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault"
        let bare = URL(fileURLWithPath: base).appendingPathComponent("remote.git")
        _ = try? await service.repoManager.runner.run(["init", "--bare", bare.path])
        model.urlBinding(repoPath).wrappedValue = bare.path
        model.authModeBinding(repoPath).wrappedValue = .ssh
        let before = await service.repoManager.authMode(path: repoPath)
        XCTAssertEqual(before, .auto, "nothing saved yet")
        model.saveRepo(repoPath)
        var message = ""
        for _ in 0..<20 {
            message = model.message(repoPath)?.0 ?? ""
            if !message.contains("正在保存") && !message.isEmpty { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let after = await service.repoManager.authMode(path: repoPath)
        XCTAssertEqual(after, .ssh, "picker selection must reach git config, message: \(message)")
    }

    /// "用户名 + 访问令牌": the token field must be writable, the token must end up
    /// in the credential store (never in git config) and the mode must persist.
    @MainActor
    func testPATCredentialsAreStoredAndModePersists() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault"
        let url = "https://fv-settings-pat.example/" + UUID().uuidString.prefix(8) + ".git"
        defer { Task { try? await CredentialStore.erase(runner: service.repoManager.runner, url: url) } }

        model.authModeBinding(repoPath).wrappedValue = .pat
        XCTAssertEqual(model.authModeBinding(repoPath).wrappedValue, .pat)
        model.authUserBinding(repoPath).wrappedValue = "ci-user"
        model.authTokenBinding(repoPath).wrappedValue = "pat-secret-123"
        XCTAssertEqual(model.authTokenBinding(repoPath).wrappedValue, "pat-secret-123",
                       "the token field must be editable from the UI binding")

        model.urlBinding(repoPath).wrappedValue = url
        model.saveRepo(repoPath)
        var message = ""
        for _ in 0..<60 {
            message = model.message(repoPath)?.0 ?? ""
            if message.contains("连通") || message.contains("失败") { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        let mode = await service.repoManager.authMode(path: repoPath)
        XCTAssertEqual(mode, .pat)
        let stored = await CredentialStore.fill(runner: service.repoManager.runner, url: url)
        XCTAssertEqual(stored?.username, "ci-user", "username must be stored, message: \(message)")
        XCTAssertEqual(stored?.password, "pat-secret-123", "token must be stored, message: \(message)")

        let card = try XCTUnwrap(model.rootCards.first?.repo)
        XCTAssertTrue(card.authToken.isEmpty, "the field must be cleared once the token is stored")
        XCTAssertTrue(card.authTokenSaved, "the UI should show that a token is stored")
        // The fake host cannot connect, so the inline message reports the failure —
        // what matters is that saving itself succeeded (mode + credentials above).
        XCTAssertTrue(message.contains("已保存"), message)

        // The token must never be written into git config.
        let cfg = try? await service.repoManager.runner.run(["config", "--local", "--list"], cwd: repoPath)
        XCTAssertFalse((cfg?.stdout ?? "").contains("pat-secret-123"), "token leaked into git config")
    }

    /// Selecting PAT without a token must say so instead of silently "saving".
    @MainActor
    func testPATWithoutTokenWarnsInsteadOfSilentlySucceeding() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault"
        let bare = URL(fileURLWithPath: base).appendingPathComponent("remote.git")
        _ = try? await service.repoManager.runner.run(["init", "--bare", bare.path])
        model.urlBinding(repoPath).wrappedValue = bare.path
        model.authModeBinding(repoPath).wrappedValue = .pat
        model.authTokenBinding(repoPath).wrappedValue = ""
        model.saveRepo(repoPath)
        var message = ""
        for _ in 0..<30 {
            message = model.message(repoPath)?.0 ?? ""
            if message.contains("访问令牌") || message.contains("失败") || message.contains("已保存并连通") { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTAssertTrue(message.contains("还需要填写访问令牌"), "expected an explicit hint, got: \(message)")
        let mode = await service.repoManager.authMode(path: repoPath)
        XCTAssertEqual(mode, .pat, "mode is still persisted even when the token is missing")
    }

    @MainActor
    func testEmptyURLSaveClearsRemote() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault"
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
        let repoPath = base + "/vault"
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