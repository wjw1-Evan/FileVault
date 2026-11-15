import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// Update-check cadence rules (v3.1.4 regression: the chain used to stop dead
/// when a tick observed auto-checking disabled).
final class UpdateCheckScheduleTests: XCTestCase {
    func testLaunchDelayIsShortButNotInstant() {
        XCTAssertEqual(UpdateCheckSchedule.launchDelay, 20)
    }

    func testSuccessCadenceIsDaily() {
        XCTAssertEqual(UpdateCheckSchedule.nextDelay(afterFailed: false, autoCheckEnabled: true),
                       24 * 3600)
    }

    func testFailureCadenceRetriesInTenMinutes() {
        XCTAssertEqual(UpdateCheckSchedule.nextDelay(afterFailed: true, autoCheckEnabled: true), 600)
        XCTAssertLessThan(UpdateCheckSchedule.failureInterval, UpdateCheckSchedule.successInterval,
                          "a failed check must retry sooner than a healthy one")
    }

    /// THE regression: with checking disabled the chain must NOT end — it keeps
    /// polling so re-enabling the toggle recovers without a relaunch.
    func testDisabledStillReschedulesInsteadOfStopping() {
        let delay = UpdateCheckSchedule.nextDelay(afterFailed: false, autoCheckEnabled: false)
        XCTAssertGreaterThan(delay, 0, "chain must stay alive while auto-check is off")
        XCTAssertEqual(delay, UpdateCheckSchedule.disabledInterval)
        // A previous failure must not shorten the idle poll.
        XCTAssertEqual(UpdateCheckSchedule.nextDelay(afterFailed: true, autoCheckEnabled: false),
                       UpdateCheckSchedule.disabledInterval)
    }

    func testTickOnlyChecksWhenEnabled() {
        XCTAssertFalse(UpdateCheckSchedule.shouldCheck(autoCheckEnabled: false))
        XCTAssertTrue(UpdateCheckSchedule.shouldCheck(autoCheckEnabled: true))
    }

    /// Every combination must yield a positive delay (never 0/negative, which
    /// would either stop the chain or spin the CPU).
    func testAllCombinationsArePositiveAndBounded() {
        for failed in [true, false] {
            for enabled in [true, false] {
                let delay = UpdateCheckSchedule.nextDelay(afterFailed: failed, autoCheckEnabled: enabled)
                XCTAssertGreaterThanOrEqual(delay, 60, "failed=\(failed) enabled=\(enabled)")
                XCTAssertLessThanOrEqual(delay, 24 * 3600, "failed=\(failed) enabled=\(enabled)")
            }
        }
    }
}

/// Toggle round-trip: turning auto-check off and back on must keep the app
/// checking (SettingsModel-level, no timers involved).
final class AutoCheckToggleTests: XCTestCase {
    @MainActor
    func testTogglingAutoCheckBackOnPersistsAndResumes() async throws {
        let base = TestSupport.makeTempDir("autocheck")
        defer { try? FileManager.default.removeItem(atPath: base) }
        try? FileManager.default.createDirectory(atPath: base + "/vault/alpha", withIntermediateDirectories: true)
        TestSupport.write("s", to: base + "/vault/alpha/s.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: base + "/vault")

        let app = AppState()
        app.service = service
        let model = SettingsModel()
        model.bind(app)
        XCTAssertTrue(model.autoCheckUpdates, "auto-check defaults to on")

        model.setAutoCheckUpdates(false)
        XCTAssertFalse(model.autoCheckUpdates)
        XCTAssertFalse(service.configStore.load().general.autoCheckUpdates)

        model.setAutoCheckUpdates(true)
        XCTAssertTrue(model.autoCheckUpdates)
        XCTAssertTrue(service.configStore.load().general.autoCheckUpdates,
                      "re-enabling must persist, otherwise the timer chain reads the stale value")
    }
}
