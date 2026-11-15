import XCTest
import CryptoKit
@testable import FileVaultCore

/// Licensing / trial behaviour (v3.2.0).
final class LicenseTests: XCTestCase {
    /// Test-only keypair — never the production signing key.
    static let testPrivateKey = "jBL5ytMomgdhRg0Msq7zr9mN94qgEc9X4pZHj2Fs18E="
    static let testPublicKey = "v1QeWvJdAJ6d/o8bGbSOW1yTOnYznQkQB9Z+ar/28gs="

    static func day(_ iso: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)!
    }

    static func manager(storage: LicenseStorage,
                        now: @escaping @Sendable () -> Date) -> LicenseManager {
        LicenseManager(storage: storage, now: now, publicKeyBase64: testPublicKey)
    }

    func testFreshInstallStartsTrial() {
        let mgr = Self.manager(storage: InMemoryLicenseStorage(), now: { Self.day("2026-11-15") })
        XCTAssertEqual(mgr.state, .trial(daysRemaining: AppBrand.trialDays))
        XCTAssertTrue(mgr.state.allowsAutomation)
    }

    func testTrialCountsDownByDay() {
        let storage = InMemoryLicenseStorage()
        _ = Self.manager(storage: storage, now: { Self.day("2026-11-15") }).state   // start
        let day13 = Self.manager(storage: storage, now: { Self.day("2026-11-28") })
        XCTAssertEqual(day13.state, .trial(daysRemaining: 1))
        XCTAssertTrue(day13.state.allowsAutomation)
    }

    func testTrialExpiresAndDisablesAutomation() {
        let storage = InMemoryLicenseStorage()
        _ = Self.manager(storage: storage, now: { Self.day("2026-11-15") }).state
        let day14 = Self.manager(storage: storage, now: { Self.day("2026-11-29") })
        XCTAssertEqual(day14.state, .expired)
        XCTAssertFalse(day14.state.allowsAutomation, "expired trial must stop automatic commits")
    }

    func testValidTokenActivates() throws {
        let storage = InMemoryLicenseStorage()
        let mgr = Self.manager(storage: storage, now: { Self.day("2026-11-15") })
        let license = License(id: "lic_1", email: "a@example.com", plan: "pro", issuedAt: "2026-11-15")
        let token = try LicenseToken.sign(license, privateKeyBase64: Self.testPrivateKey)
        let state = try mgr.activate(token)
        XCTAssertTrue(state.isLicensed)
        XCTAssertTrue(state.allowsAutomation)
        // Survives a fresh manager instance (storage round-trip).
        let again = Self.manager(storage: storage, now: { Self.day("2027-06-01") })
        XCTAssertTrue(again.state.isLicensed, "a licence must win over the expired trial")
    }

    func testTamperedTokenRejected() throws {
        let mgr = Self.manager(storage: InMemoryLicenseStorage(), now: { Self.day("2026-11-15") })
        let license = License(id: "lic_1", email: "a@example.com", issuedAt: "2026-11-15")
        var token = try LicenseToken.sign(license, privateKeyBase64: Self.testPrivateKey)
        // Flip one character in the payload segment.
        var chars = Array(token)
        let payloadStart = 4
        chars[payloadStart] = chars[payloadStart] == "A" ? "B" : "A"
        token = String(chars)
        XCTAssertThrowsError(try mgr.activate(token)) { error in
            XCTAssertEqual(error as? LicenseError, .badSignature)
        }
    }

    func testMalformedTokenRejected() {
        let mgr = Self.manager(storage: InMemoryLicenseStorage(), now: { Self.day("2026-11-15") })
        XCTAssertThrowsError(try mgr.activate("not-a-token")) { error in
            XCTAssertEqual(error as? LicenseError, .malformed)
        }
        XCTAssertThrowsError(try mgr.activate("fv1.abc")) { error in
            XCTAssertEqual(error as? LicenseError, .malformed)
        }
    }

    func testTokenSignedByWrongKeyRejected() throws {
        let foreign = Curve25519.Signing.PrivateKey()
        let token = try LicenseToken.sign(
            License(id: "x", email: "x@y.z", issuedAt: "2026-11-15"),
            privateKeyBase64: foreign.rawRepresentation.base64EncodedString())
        let mgr = Self.manager(storage: InMemoryLicenseStorage(), now: { Self.day("2026-11-15") })
        XCTAssertThrowsError(try mgr.activate(token))
    }

    func testExpiredLicenceCannotBeActivated() throws {
        let storage = InMemoryLicenseStorage()
        let mgr = Self.manager(storage: storage, now: { Self.day("2026-11-15") })
        let license = License(id: "lic_old", email: "a@example.com",
                              issuedAt: "2025-01-01", expiresAt: "2026-01-01")
        let token = try LicenseToken.sign(license, privateKeyBase64: Self.testPrivateKey)
        XCTAssertThrowsError(try mgr.activate(token))
    }

    func testDeactivateFallsBackToTrialClock() throws {
        let storage = InMemoryLicenseStorage()
        let mgr = Self.manager(storage: storage, now: { Self.day("2026-11-15") })
        XCTAssertEqual(mgr.state, .trial(daysRemaining: AppBrand.trialDays))
        let token = try LicenseToken.sign(
            License(id: "lic_1", email: "a@example.com", issuedAt: "2026-11-15"),
            privateKeyBase64: Self.testPrivateKey)
        _ = try mgr.activate(token)
        XCTAssertTrue(mgr.deactivate().isLicensed == false)
        XCTAssertEqual(mgr.state, .trial(daysRemaining: AppBrand.trialDays))
    }

    func testPerpetualVsDatedLicence() {
        let perpetual = License(id: "p", email: "a@b.c", issuedAt: "2020-01-01")
        XCTAssertFalse(perpetual.isExpired(now: Self.day("2035-01-01")))
        let dated = License(id: "d", email: "a@b.c", issuedAt: "2020-01-01", expiresAt: "2026-11-15")
        XCTAssertFalse(dated.isExpired(now: Self.day("2026-11-15")), "expires at end of the day")
        XCTAssertTrue(dated.isExpired(now: Self.day("2026-11-16")))
    }

    func testDiagnosticsReportMasksHomeAndDescribesLicence() {
        let storage = InMemoryLicenseStorage()
        let mgr = Self.manager(storage: storage, now: { Self.day("2026-11-15") })
        let root = NSHomeDirectory() + "/Documents/写作"
        let report = SupportBundle.report(appVersion: "3.2.0", license: mgr,
                                          config: AppConfig(roots: []),
                                          gitDescription: "/usr/bin/git (2.50.0)",
                                          roots: [(root, 3)])
        XCTAssertTrue(report.contains("3.2.0"))
        XCTAssertTrue(report.contains("~/Documents/写作"), "home paths must be masked")
        XCTAssertFalse(report.contains(NSHomeDirectory()), "raw home path must not leak")
        XCTAssertTrue(report.contains("试用中"))
    }

    func testDiagnosticsExportCreatesZip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fv-diag-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dest = tmp.appendingPathComponent("report.zip")
        try SupportBundle.export(report: "hello", configDirectory: nil, destination: dest)
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size ?? 0, 0)
    }
}

/// The commit pipeline must respect the licence gate.
final class LicenseGateTests: XCTestCase {
    var root: String!
    var repos: RepoManager!
    var engine: CommitEngine!

    override func setUp() async throws {
        root = TestSupport.makeTempDir("licensegate")
        try? FileManager.default.createDirectory(atPath: root + "/vault/work", withIntermediateDirectories: true)
        TestSupport.write("hello", to: root + "/vault/work/note.md")
        repos = RepoManager(runner: TestSupport.newRunner())
        try await repos.ensureRepos(root: root + "/vault")
        let debouncer = Debouncer(quietInterval: 5, maxWait: 30, onFired: { _ in })
        engine = CommitEngine(repoManager: repos, debouncer: debouncer, pause: PauseController())
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }

    func testExpiredGateBlocksAutomaticCommit() async throws {
        let repo = root + "/vault/work"
        TestSupport.write("changed", to: repo + "/note.md")
        engine.isAutomationAllowed = { false }
        await engine.runCommitPipeline(repoPath: repo)
        let log = try await repos.log(path: repo)
        XCTAssertEqual(log.count, 1, "only the initial commit may exist while unlicensed")
    }

    func testLicensedGateAllowsCommit() async throws {
        let repo = root + "/vault/work"
        TestSupport.write("changed", to: repo + "/note.md")
        engine.isAutomationAllowed = { true }
        await engine.runCommitPipeline(repoPath: repo)
        let log = try await repos.log(path: repo)
        XCTAssertGreaterThan(log.count, 1)
    }
}
