import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// v4.2.31 latent-bug round (fix-settings-ui). Every test pins a defect with
/// its trigger scenario, against real git through the same service/AppState
/// scaffolding SettingsModelTests uses.
@MainActor
final class SettingsLatentBugTests: XCTestCase {

    private func makeModel() async throws -> (SettingsModel, FileVaultService, String) {
        let base = TestSupport.makeTempDir("setlatent")
        try? FileManager.default.createDirectory(atPath: base + "/vault", withIntermediateDirectories: true)
        TestSupport.write("s", to: base + "/vault/s.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: base + "/vault")
        let app = AppState()
        app.service = service
        let model = SettingsModel()
        model.bind(app)
        return (model, service, base)
    }

    // MARK: - Created-repo URL vs background refills

    /// The URL gh just created must behave like typed text. It used to be
    /// written into the field WITHOUT the typed-mark, so the next background
    /// refill (auto-commit → state change → reload → fillRepoDetails) snapped
    /// the field back to the previously stored remote — silently discarding
    /// the address of the repo that had just been created, and a later
    /// 创建并绑定 retry then hit gh's duplicate-name error.
    func testCreatedRepoURLSurvivesBackgroundRefill() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault"
        // A stored remote that differs from the "created" one.
        let bare = URL(fileURLWithPath: base).appendingPathComponent("remote.git")
        _ = try? await service.repoManager.runner.run(["init", "--bare", bare.path])
        _ = try await service.repoManager.runner.run(["remote", "add", "origin", bare.path], cwd: repoPath)

        // Let the first fill land (remoteNames populated).
        for _ in 0..<40 where (model.rootCards.first?.repo.remoteNames.isEmpty ?? true) {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let created = "https://github.com/user/" + UUID().uuidString.prefix(6) + ".git"
        model.adoptCreatedRepoURL(created, target: repoPath)

        // A full reload + refill round: the fill completes when remoteNames
        // populates again — its urlText write must have been skipped by the
        // typed-mark (the write happens before remoteNames in the same block).
        model.reload()
        for _ in 0..<40 where (model.rootCards.first?.repo.remoteNames.isEmpty ?? true) {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertEqual(model.rootCards.first?.repo.urlText, created,
                       "a background refill must not snap the created URL back to the stored remote")
    }

    // MARK: - gh create vs in-flight saves

    /// gh must not create the repo while a save is already running for the
    /// same folder: the bind step would block on the busy lock, leaving an
    /// orphan repo that only produces a duplicate-name error on retry.
    func testCreateRepoRefusesWhileSaveIsInFlight() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault"
        let bare = URL(fileURLWithPath: base).appendingPathComponent("remote.git")
        _ = try? await service.repoManager.runner.run(["init", "--bare", bare.path])

        // saveRepo takes its busy lock synchronously before spawning its Task.
        model.urlBinding(repoPath).wrappedValue = bare.path
        model.saveRepo(repoPath)
        // Immediately asking for a repo creation must be refused BEFORE gh
        // runs (the guard is what keeps this test network-free).
        model.createRepoAndBind(target: repoPath, name: "ci-latent-check")
        XCTAssertFalse(model.createRepoBusy, "the dialog must not enter its busy state")
        XCTAssertTrue(model.createRepoError.contains("正在处理上一个操作"), model.createRepoError)

        // Let the in-flight save settle before teardown.
        for _ in 0..<40 {
            let message = model.message(repoPath)?.0 ?? ""
            if message.contains("已保存") || message.contains("失败") { break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    // MARK: - Silent no-ops during the startup window

    /// The diagnostics button before the service exists (settings opened at
    /// login launch / --open-ui) used to do nothing at all.
    func testExportDiagnosticsReportsNotReadyWithoutService() {
        let app = AppState()              // service intentionally nil
        let model = SettingsModel()
        model.bind(app)
        model.exportDiagnostics()
        XCTAssertTrue(model.supportMessage?.contains("尚未就绪") ?? false,
                      String(describing: model.supportMessage))
        XCTAssertTrue(model.supportMessageIsError)
    }

    /// During the git-setup window cards render as available («正在加载…»),
    /// so the 更多 → 编辑忽略规则… menu is clickable; the click used to be a
    /// silent no-op instead of saying why.
    func testGitignoreEditorRefusesWhenGitNotReady() async throws {
        let base = TestSupport.makeTempDir("setgitignore-notready")
        defer { try? FileManager.default.removeItem(atPath: base) }
        try? FileManager.default.createDirectory(atPath: base + "/vault", withIntermediateDirectories: true)
        TestSupport.write("s", to: base + "/vault/s.md")
        // A real service writes the root into the config…
        let started = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await started.start()
        try await started.addRoot(path: base + "/vault")
        // …then a second, not-yet-started service reads the same config:
        // the card exists but git is not ready on this instance.
        let cold = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        let app = AppState()
        app.service = cold
        let model = SettingsModel()
        model.bind(app)
        XCTAssertEqual(model.rootCards.count, 1)
        let id = try XCTUnwrap(model.rootCards.first?.repo.id)
        model.openGitignoreEditor(id)
        XCTAssertTrue(model.message(id)?.0.contains("尚未就绪") ?? false,
                      String(describing: model.message(id)?.0))
        XCTAssertNil(model.gitignoreEditor, "the editor must not open while git is not ready")
    }
}
