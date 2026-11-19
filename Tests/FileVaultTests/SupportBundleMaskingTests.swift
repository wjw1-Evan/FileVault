import XCTest
@testable import FileVaultCore

/// masked() is the privacy promise of the diagnostics report (PRIVACY.md:
/// shareable publicly). The edges here are the ones that historically leaked
/// paths: JSON-escaped slashes (v4.2.26), the home-boundary rule, and other
/// accounts on the same Mac.
final class SupportBundleMaskingTests: XCTestCase {

    func testEscapedSlashJSONIsNormalizedAndMasked() {
        // The exact shape JSONEncoder produced before .withoutEscapingSlashes:
        // the home replacement silently missed these (v4.2.26 regression).
        let raw = "\\/Users\\/someuser\\/project\\/file.txt"
        XCTAssertEqual(SupportBundle.masked(raw), "~/project/file.txt")
    }

    func testHomeBoundaryIsACompletePathComponent() {
        let home = NSHomeDirectory()
        XCTAssertEqual(SupportBundle.masked(home + "/docs"), "~/docs")
        // home + "2" is a DIFFERENT account directory: it must collapse to ~
        // (via the /Users rule), never survive as the raw home path nor as a
        // glued "~2".
        let neighbour = home + "2/docs"
        let masked = SupportBundle.masked(neighbour)
        XCTAssertFalse(masked.contains(home + "2"), "the neighbour account must not survive: \(masked)")
        XCTAssertTrue(masked.contains("~/docs"), masked)
    }

    func testOtherAccountsAreCollapsedToo() {
        XCTAssertEqual(SupportBundle.masked("/Users/somebody-else/x"), "~/x")
        XCTAssertEqual(SupportBundle.masked("/private/tmp/plain.txt"), "/private/tmp/plain.txt")
    }

    func testMaskingIsIdempotent() {
        let sample = NSHomeDirectory() + "/工作/重要文件.md"
        let once = SupportBundle.masked(sample)
        XCTAssertEqual(SupportBundle.masked(once), once, "already-shortened text must not change again")
    }

    func testReportBranchesWithoutConfigOrRoots() {
        let report = SupportBundle.report(appVersion: "4.2.31", config: nil,
                                           gitDescription: "git version 2.56.1")
        XCTAssertTrue(report.contains("4.2.31"), "version line")
        XCTAssertTrue(report.contains("（未加载配置）"), "nil config is stated, not blank")
        XCTAssertTrue(report.contains("（无）"), "empty roots are stated")
        XCTAssertTrue(report.contains("永久免费"), "the pricing note ships in every report")
        XCTAssertFalse(report.contains(NSHomeDirectory()), "no raw home path anywhere")

        let withRoots = SupportBundle.report(appVersion: "4.2.31", config: nil,
                                              gitDescription: nil,
                                              roots: [NSHomeDirectory() + "/工作"])
        XCTAssertTrue(withRoots.contains("未检测到"), "a nil git description is stated")
        XCTAssertFalse(withRoots.contains(NSHomeDirectory() + "/工作"), "root paths are masked")
    }

    /// An undecodable config.json must still export a REDACTED raw copy, not
    /// the raw bytes: the raw text path exists for exactly this case
    /// (v4.2.26) and had to mask too.
    func testExportRedactsEvenUndecodableConfig() throws {
        let base = TestSupport.makeTempDir("sbmask")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let cfgDir = URL(fileURLWithPath: base + "/cfg")
        try FileManager.default.createDirectory(atPath: cfgDir.path, withIntermediateDirectories: true)
        let raw = "{\"roots\":[{\"path\":\"" + NSHomeDirectory() + "/秘密/\"}]}"
        try Data(raw.utf8).write(to: cfgDir.appendingPathComponent("config.json"))

        let dest = URL(fileURLWithPath: base + "/diag.zip")
        _ = try SupportBundle.export(report: "report body", configDirectory: cfgDir, destination: dest)

        let out = URL(fileURLWithPath: base + "/out")
        try FileManager.default.createDirectory(atPath: out.path, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", dest.path, out.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run(); unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        // ditto flattens the staging dir name; find the redacted copy wherever it landed.
        let found = try FileManager.default.subpathsOfDirectory(atPath: out.path)
            .first { $0.hasSuffix("config.redacted.json") }
        XCTAssertNotNil(found, "the raw-text fallback writes the redacted copy")
        let redacted = try String(contentsOf: URL(fileURLWithPath: out.path + "/" + found!),
                                   encoding: .utf8)
        XCTAssertFalse(redacted.contains(NSHomeDirectory()), "raw copy masked: \(redacted)")
        XCTAssertTrue(redacted.contains("~/秘密/"), redacted)
    }
}
