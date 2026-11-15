import XCTest
@testable import FileVaultCore

/// Support diagnostics (v3.2.1: free app — diagnostics, no licensing).
final class SupportBundleTests: XCTestCase {
    func testReportMasksHomePathsAndLeaksNoHome() {
        let root = NSHomeDirectory() + "/Documents/写作"
        let report = SupportBundle.report(appVersion: "3.2.1",
                                          config: AppConfig(roots: []),
                                          gitDescription: "/usr/bin/git (2.50.0)",
                                          roots: [root])
        XCTAssertTrue(report.contains("3.2.1"))
        XCTAssertTrue(report.contains("~/Documents/写作"), "home must be collapsed to ~")
        // v4.0: a root is exactly one repository.
        XCTAssertTrue(report.contains("- ~/Documents/写作（1 个仓库）"),
                      "one repository per protected folder")
        XCTAssertFalse(report.contains(NSHomeDirectory()), "raw home path must not leak")
    }

    func testReportListsEveryRoot() {
        let a = NSHomeDirectory() + "/Documents/alpha"
        let b = NSHomeDirectory() + "/Documents/beta"
        let report = SupportBundle.report(appVersion: "4.0.0", config: nil, gitDescription: nil,
                                          roots: [a, b])
        XCTAssertTrue(report.contains("- ~/Documents/alpha（1 个仓库）"))
        XCTAssertTrue(report.contains("- ~/Documents/beta（1 个仓库）"))
    }

    func testReportStatesFreePricing() {
        let report = SupportBundle.report(appVersion: "3.2.1", config: nil, gitDescription: nil)
        XCTAssertTrue(report.contains("永久免费"))
        XCTAssertFalse(report.contains("试用"))
        XCTAssertFalse(report.contains("激活"))
    }

    func testReportContainsNoCredentials() {
        let report = SupportBundle.report(appVersion: "3.2.1",
                                          config: AppConfig(roots: [ManagedRoot(path: "/tmp/notes")]),
                                          gitDescription: nil)
        // If credentials ever leak into config/report this guard fails.
        XCTAssertFalse(report.lowercased().contains("password"))
        XCTAssertFalse(report.lowercased().contains("token"))
    }

    func testExportWritesZip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fv-support-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dest = tmp.appendingPathComponent("diagnostics.zip")
        try SupportBundle.export(report: "hello", configDirectory: nil, destination: dest)
        let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
        let size = (attrs[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0)
    }

    func testMaskedKeepsTextWithoutHomePrefix() {
        XCTAssertEqual(SupportBundle.masked("/opt/homebrew/bin/git"), "/opt/homebrew/bin/git")
        XCTAssertEqual(SupportBundle.masked(NSHomeDirectory() + "/a"), "~/a")
    }
}
