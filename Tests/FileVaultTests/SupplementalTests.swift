import XCTest
import AppKit
@testable import FileVaultCore
@testable import FileVaultApp

/// Supplemental coverage for fixes that shipped in v2.6.5–v2.6.7 whose
/// regression surfaces were only covered indirectly (or not at all).
final class SupplementalTests: XCTestCase {
    // MARK: - History: statusText guidance (v2.6.5 filesLabel regression —
    // asserted through the HistoryModel that drives the SwiftUI label)

    @MainActor
    func testFilesLabelGuidanceActuallyDisplays() async throws {
        let base = TestSupport.makeTempDir("supp-label")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        let model = HistoryModel()
        model.bind(AppState(service: service))
        // Before v2.6.5 the label was never assigned, so every message write
        // was a silent no-op — this guard fails if that class of bug regresses.
        XCTAssertEqual(model.statusText, "尚未添加任何根目录——先在设置中添加根目录")
        try? FileManager.default.removeItem(atPath: base)
    }

    // MARK: - 登录时启动 toggle: intent must persist even where SMAppService
    // is unavailable (test bundles) — the config write must not depend on it.

    @MainActor
    func testLaunchAtLoginTogglePersistsIntent() async throws {
        let base = TestSupport.makeTempDir("supp-login")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        let model = SettingsModel()
        model.bind(AppState(service: service))

        model.toggleLoginIntent(true)
        try await Task.sleep(nanoseconds: 800_000_000)
        var cfg = service.configStore.load()
        XCTAssertTrue(cfg.general.launchAtLoginRequested, "ON intent must persist")

        model.toggleLoginIntent(false)
        try await Task.sleep(nanoseconds: 800_000_000)
        cfg = service.configStore.load()
        XCTAssertFalse(cfg.general.launchAtLoginRequested, "OFF intent must persist")
        try? FileManager.default.removeItem(atPath: base)
    }

    // MARK: - GitRunner: core.quotepath=false must apply to EVERY command,
    // not only the ones asserted via HistoryService.

    func testRunnerForcesRawUnicodePathsOnAllCommands() async throws {
        let base = TestSupport.makeTempDir("supp-quotepath")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repo = base + "/repo"
        try FileManager.default.createDirectory(atPath: repo + "/中文目录", withIntermediateDirectories: true)
        TestSupport.write("x", to: repo + "/中文目录/文件.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        try await repos.ensureRepos(root: base)
        let r = try await repos.runner.run(["ls-files"], cwd: repo)
        XCTAssertTrue(r.succeeded)
        XCTAssertTrue(r.stdout.contains("中文目录/文件.md"), "raw UTF-8 expected, got: \(r.stdout)")
        XCTAssertFalse(r.stdout.contains("\\"), "no octal escaping expected")
    }

    // MARK: - GitRunner: spawn failure must throw promptly (v2.6.6 fix — the
    // pipe readers must not leak threads that starve GCD).

    func testSpawnFailureThrowsPromptly() async throws {
        let runner = GitRunner(gitExecutable: "/nonexistent/git-binary")
        let start = Date()
        do {
            _ = try await runner.run(["status"], cwd: NSTemporaryDirectory())
            XCTFail("spawn failure must throw")
        } catch {
            // expected
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "must fail fast, not block")
    }

    // MARK: - UpdateDownloader (v2.6.4 rewrite): direct assetURL streaming.

    func testUpdateDownloaderStreamsFileAssetWithProgress() async throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("supp-dl"))
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let payload = Data("fv-update-payload-0123456789".utf8)
        let source = dir.appendingPathComponent("asset.zip")
        try payload.write(to: source)

        let info = ReleaseInfo(version: "9.9.9", tagName: "v9.9.9", notes: "",
                               assetName: "asset.zip", sha256: nil,
                               assetSize: Int64(payload.count),
                               assetURL: source.absoluteString)  // file:// URL
        var fractions: [Double] = []
        let dest = try await UpdateDownloader.download(info: info, progress: { f, _, _ in
            fractions.append(f)
        })
        let downloaded = try Data(contentsOf: dest)
        XCTAssertEqual(downloaded, payload, "streamed bytes must match the asset")
        XCTAssertEqual(dest.lastPathComponent, "fv-update-asset.zip",
                       "temp download carries the fv-update- prefix")
        XCTAssertTrue(fractions.contains(1.0), "final progress must be reported")
        if let first = fractions.first {
            XCTAssertLessThanOrEqual(first, 1.0)
        }
    }

    // MARK: - FR-13: per-root pause persists; resuming flushes dirty repos.

    func testRootPausePersistsAndResumeFlushesDirty() async throws {
        let base = TestSupport.makeTempDir("supp-pause")
        defer { try? FileManager.default.removeItem(atPath: base) }
        try? FileManager.default.createDirectory(atPath: base + "/vault/work", withIntermediateDirectories: true)
        TestSupport.write("s", to: base + "/vault/work/s.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: base + "/vault")
        let repoPath = base + "/vault/work"

        try await service.setRootPaused(true, root: base + "/vault")
        XCTAssertEqual(service.configStore.load().roots.first?.paused, true, "pause persists")

        // While paused, the commit pipeline must skip the repo entirely.
        TestSupport.write("paused-change", to: repoPath + "/p.md")
        await service.commitEngine.runCommitPipeline(repoPath: repoPath)
        let pausedLog = try await service.repoManager.log(path: repoPath)
        XCTAssertEqual(pausedLog.count, 1, "no commit while paused (initial commit only)")

        // Resuming must flush the dirty repo.
        try await service.setRootPaused(false, root: base + "/vault")
        XCTAssertEqual(service.configStore.load().roots.first?.paused, false)
        await service.commitEngine.commitAllDirty(root: base + "/vault")
        let resumedLog = try await service.repoManager.log(path: repoPath)
        XCTAssertEqual(resumedLog.count, 2, "resumed repo commits its pending change")
        XCTAssertEqual(resumedLog.first?.subject, "auto: 1 处变更 (+1 -0)，新增 p.md")
    }

    // MARK: - Dashboard empty state points at 设置 (single-entry invariant UX).

    @MainActor
    func testDashboardEmptyStatePointsToSettings() async throws {
        let base = TestSupport.makeTempDir("supp-dash")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        let app = AppState(service: service)
        let model = DashboardModel()
        model.bind(app)
        await model.refresh()
        XCTAssertTrue(model.rootsEmpty, "no roots configured → empty state")
        XCTAssertFalse(model.stateLine.contains("📂"))
        XCTAssertTrue(model.stateLine.contains("0 个仓库受守护"))
        try? FileManager.default.removeItem(atPath: base)
    }
}
