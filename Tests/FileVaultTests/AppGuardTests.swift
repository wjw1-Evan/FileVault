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
