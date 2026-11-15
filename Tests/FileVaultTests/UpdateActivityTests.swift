import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// v3.1.5: update progress is rendered as menu text — no progress window and no
/// alert panel — so the wording and the clamped percentage are contract.
final class UpdateActivityTests: XCTestCase {
    func testDownloadTextCarriesPercentAndBytes() {
        let activity = UpdateActivity(phase: .downloading, fraction: 0.42,
                                      detail: "840 KB / 2 MB")
        XCTAssertEqual(activity.percent, 42)
        XCTAssertEqual(activity.menuText, "正在下载更新 42%… · 840 KB / 2 MB")
    }

    func testDownloadTextWithoutKnownTotal() {
        let activity = UpdateActivity(phase: .downloading)
        XCTAssertNil(activity.percent)
        XCTAssertEqual(activity.menuText, "正在下载更新…")
    }

    func testPercentRoundsDownAndClamps() {
        XCTAssertEqual(UpdateActivity(phase: .downloading, fraction: 0.999).percent, 99,
                       "must not claim 100% before the download finishes")
        XCTAssertEqual(UpdateActivity(phase: .downloading, fraction: 1.4).percent, 100)
        XCTAssertEqual(UpdateActivity(phase: .downloading, fraction: -0.2).percent, 0)
        XCTAssertEqual(UpdateActivity(phase: .downloading, fraction: 0).percent, 0)
    }

    func testStageTexts() {
        XCTAssertEqual(UpdateActivity(phase: .checking).menuText, "正在检查更新…")
        XCTAssertEqual(UpdateActivity(phase: .verifying).menuText, "正在校验更新…")
        XCTAssertEqual(UpdateActivity(phase: .installing).menuText, "正在安装更新…")
        XCTAssertEqual(UpdateActivity(phase: .restarting).menuText, "更新完成，正在重启…")
    }

    func testEveryStageHasNonEmptyMenuText() {
        for phase in [UpdateActivity.Phase.checking, .downloading, .verifying, .installing, .restarting] {
            XCTAssertFalse(UpdateActivity(phase: phase).menuText.isEmpty)
        }
    }

    /// The finished-update line replaces the former modal alerts.
    func testStatusLines() {
        XCTAssertEqual(UpdateStatus.upToDate("3.1.5"), "已是最新版本（v3.1.5）")
        XCTAssertEqual(UpdateStatus.failed("网络超时"), "更新失败：网络超时")
        XCTAssertEqual(UpdateStatus.failed(nil), "更新失败，将自动重试")
        XCTAssertEqual(UpdateStatus.failed(""), "更新失败，将自动重试")
        XCTAssertFalse(UpdateStatus.developmentBuild.isEmpty)
    }

    /// A menu update row must never be so long that it truncates in the menu.
    @MainActor
    func testMenuRowStaysCompact() {
        let activity = UpdateActivity(phase: .downloading, fraction: 0.5, detail: "1.1 MB / 2.2 MB")
        XCTAssertLessThan(activity.menuText.count, 60)
        XCTAssertTrue(UpdateStatus.upToDate("3.1.5").count < 30)
    }

    /// The menu's update row and the "检查更新…" item both read this flag.
    @MainActor
    func testIsUpdatingTracksActivity() async throws {
        let root = TestSupport.makeTempDir("updmenu")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        let state = AppState(service: service)
        XCTAssertFalse(state.isUpdating)
        state.updateActivity = UpdateActivity(phase: .checking)
        XCTAssertTrue(state.isUpdating)
        state.updateActivity = nil
        XCTAssertFalse(state.isUpdating)
    }

    /// End of the flow: a manual check writes its result to the MENU instead of
    /// opening "已是最新版本" as a modal alert (v3.1.5).
    @MainActor
    func testManualCheckWritesMenuNoticeWhenUpToDate() async throws {
        let root = TestSupport.makeTempDir("updnotice")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        let state = AppState(service: service)
        // Same version as the running bundle -> checker returns nil.
        let same = ReleaseInfo(version: AppState.bundleVersion, tagName: "v" + AppState.bundleVersion,
                               notes: "", assetName: "FileVault.zip", sha256: nil)
        state.updateChecker = UpdateChecker(currentVersion: AppState.bundleVersion,
                                            fetcher: FakeReleaseFetcher(.success(same)))
        XCTAssertNil(state.updateNotice)
        await state.checkForUpdate(silent: false)
        XCTAssertEqual(state.updateNotice, UpdateStatus.upToDate(AppState.bundleVersion))
        XCTAssertNil(state.updateActivity, "progress row clears when the flow ends")
        XCTAssertFalse(state.isUpdating)
    }

    /// A failing manual check also stays in the menu — no alert panel.
    @MainActor
    func testManualCheckFailureStaysInMenu() async throws {
        let root = TestSupport.makeTempDir("updfail")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        let state = AppState(service: service)
        state.updateChecker = UpdateChecker(currentVersion: "0.0.1",
                                            fetcher: FakeReleaseFetcher(.failure(UpdateError.noRelease)))
        await state.checkForUpdate(silent: false)
        XCTAssertTrue(state.lastUpdateCheckFailed)
        XCTAssertEqual(state.updateNotice, UpdateStatus.failed(UpdateError.noRelease.localizedDescription))
        XCTAssertNil(state.updateActivity)
    }

    /// Tests run unbundled, so a real offer must NOT try to replace the
    /// executable — the menu says "开发模式" instead.
    @MainActor
    func testDevelopmentBuildSkipsInstallWithMenuNotice() async throws {
        let root = TestSupport.makeTempDir("upddev")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        let state = AppState(service: service)
        let newer = ReleaseInfo(version: "999.0.0", tagName: "v999.0.0", notes: "",
                                assetName: "FileVault-999.0.0.zip", sha256: nil)
        state.updateChecker = UpdateChecker(currentVersion: "0.0.1",
                                            fetcher: FakeReleaseFetcher(.success(newer)))
        await state.checkForUpdate(silent: false)
        XCTAssertEqual(state.updateNotice, UpdateStatus.developmentBuild)
        XCTAssertNil(state.updateActivity)
    }
}
