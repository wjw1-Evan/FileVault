import XCTest
@testable import FileVaultCore

/// Update safety: crash-loop marker + code-signature gate (v3.3.0).
final class UpdateGuardTests: XCTestCase {
    var configDir: URL!

    override func setUp() {
        configDir = URL(fileURLWithPath: TestSupport.makeTempDir("updguard"))
            .appendingPathComponent("cfg")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: configDir.deletingLastPathComponent())
    }

    func testMarkerLifecycle() {
        XCTAssertNil(UpdateGuard.read(configDirectory: configDir), "no marker before an update")

        UpdateGuard.beginUpdate(configDirectory: configDir, previousVersion: "3.2.1", newVersion: "3.3.0")
        let stored = UpdateGuard.read(configDirectory: configDir)
        XCTAssertEqual(stored?.attempts, 0)
        XCTAssertEqual(stored?.previousVersion, "3.2.1")

        let first = UpdateGuard.consumeLaunch(configDirectory: configDir)
        XCTAssertEqual(first?.attempts, 1)
        XCTAssertFalse(UpdateGuard.shouldRollback(first!, currentVersion: "3.3.0"))

        _ = UpdateGuard.consumeLaunch(configDirectory: configDir)
        let third = UpdateGuard.consumeLaunch(configDirectory: configDir)
        XCTAssertEqual(third?.attempts, UpdateGuard.maxLaunchAttempts)
        XCTAssertTrue(UpdateGuard.shouldRollback(third!, currentVersion: "3.3.0"))

        UpdateGuard.markHealthy(configDirectory: configDir)
        XCTAssertNil(UpdateGuard.read(configDirectory: configDir))
    }

    func testMarkerSurvivesDateRoundTrip() throws {
        UpdateGuard.beginUpdate(configDirectory: configDir, previousVersion: "1.0", newVersion: "2.0")
        let read = try XCTUnwrap(UpdateGuard.read(configDirectory: configDir))
        XCTAssertEqual(read.newVersion, "2.0")
        XCTAssertLessThan(abs(read.startedAt.timeIntervalSinceNow), 60)
    }

    func testConsumeWithoutMarkerIsNoOp() {
        XCTAssertNil(UpdateGuard.consumeLaunch(configDirectory: configDir))
    }

    func testRollbackSourceOnlyWhenOldBundleExists() {
        let parent = URL(fileURLWithPath: TestSupport.makeTempDir("updrollback"))
        let app = parent.appendingPathComponent("FileVault.app")
        try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertNil(UpdateGuard.rollbackSource(for: app))

        let old = parent.appendingPathComponent("FileVault.app.old")
        try? FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        XCTAssertEqual(UpdateGuard.rollbackSource(for: app)?.lastPathComponent, "FileVault.app.old")
        try? FileManager.default.removeItem(at: parent)
    }

    /// Pinning rules: never downgrade from a signed release to unsigned/ad-hoc.
    func testTeamAcceptanceMatrix() {
        XCTAssertTrue(UpdateSignature.acceptTeam(current: nil, new: nil), "dev → dev")
        XCTAssertTrue(UpdateSignature.acceptTeam(current: nil, new: "TEAM123"), "ad-hoc → Developer ID migration")
        XCTAssertTrue(UpdateSignature.acceptTeam(current: "TEAM123", new: "TEAM123"), "same team")
        XCTAssertFalse(UpdateSignature.acceptTeam(current: "TEAM123", new: "EVIL999"), "different team")
        XCTAssertFalse(UpdateSignature.acceptTeam(current: "TEAM123", new: nil), "signed → unsigned downgrade")
    }

    func testSignatureInspectAndVerifyOnSignedBundle() throws {
        let bundle = try makeSignedBundle(identifier: "com.example.update")
        let info = UpdateSignature.inspect(bundle)
        XCTAssertEqual(info.identifier, "com.example.update")
        XCTAssertTrue(info.signatureValid)
        XCTAssertNil(info.teamIdentifier, "ad-hoc bundles have no team id")

        XCTAssertNoThrow(try UpdateSignature.verify(newBundle: bundle, expectedIdentifier: "com.example.update"))
        XCTAssertThrowsError(try UpdateSignature.verify(newBundle: bundle, expectedIdentifier: "com.filevault.FileVault")) { error in
            guard let failure = error as? UpdateSignature.Failure else {
                return XCTFail("expected UpdateSignature.Failure, got \(error)")
            }
            guard case .wrongIdentifier = failure else {
                return XCTFail("expected wrongIdentifier, got \(failure)")
            }
        }
    }

    func testTamperedBundleFailsVerification() throws {
        let bundle = try makeSignedBundle(identifier: "com.example.tampered")
        // Append bytes to the binary after signing → signature no longer valid.
        let binary = bundle.appendingPathComponent("Contents/MacOS/FakeApp")
        let handle = try FileHandle(forWritingTo: binary)
        handle.seekToEndOfFile()
        handle.write(Data("tamper".utf8))
        try handle.close()

        let info = UpdateSignature.inspect(bundle)
        XCTAssertFalse(info.signatureValid)
        XCTAssertThrowsError(try UpdateSignature.verify(newBundle: bundle, expectedIdentifier: "com.example.tampered"))
    }

    // MARK: - Helpers

    /// Build a minimal, ad-hoc signed .app bundle (codesign -s -).
    private func makeSignedBundle(identifier: String) throws -> URL {
        let root = URL(fileURLWithPath: TestSupport.makeTempDir("sigbundle"))
        let app = root.appendingPathComponent("Fake.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/echo", toPath: macos.appendingPathComponent("FakeApp").path)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "FakeApp",
            "CFBundlePackageType": "APPL",
            "CFBundleName": "Fake",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--deep", "-s", "-", app.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        XCTAssertEqual(codesign.terminationStatus, 0, "ad-hoc signing must succeed for the fixture")
        return app
    }
}
