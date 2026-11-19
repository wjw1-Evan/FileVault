import XCTest
@testable import FileVaultCore

/// SelfUpdater failure/rotation edges not covered by the happy-path suite:
/// fail-closed verify, extract failures with detail, the staging-dir sweeper
/// and the shell quoting the relaunch helper relies on.
final class SelfUpdaterEdgeCasesTests: XCTestCase {

    func testVerifyPassesWithCorrectDigest() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("upd-ok"))
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let zip = dir.appendingPathComponent("f.zip")
        let payload = Data("genuine-update".utf8)
        try payload.write(to: zip)
        let digest = SelfUpdater.sha256(payload)
        XCTAssertNoThrow(try SelfUpdater.verify(zipURL: zip, expectedSHA256: digest))
        // whitespace around the digest must be tolerated (API payloads)
        XCTAssertNoThrow(try SelfUpdater.verify(zipURL: zip, expectedSHA256: "  \(digest) \n"))
        XCTAssertThrowsError(try SelfUpdater.verify(zipURL: zip, expectedSHA256: "  ")) { e in
            XCTAssertEqual(e as? UpdateError, .missingChecksum, "whitespace-only digest is no digest")
        }
    }

    func testReplaceRefusesNonAppBundle() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("upd-notbundled"))
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let fake = dir.appendingPathComponent("FileVault.txt")
        try Data("x".utf8).write(to: fake)
        XCTAssertThrowsError(try SelfUpdater.replace(bundleURL: fake, newZipURL: fake,
                                                          relaunch: false, verifySignature: false)) { e in
            XCTAssertEqual(e as? UpdateError, .notBundled)
        }
    }

    /// v4.2.26: a corrupt archive is an EXTRACT failure with the real reason,
    /// not "download failed" — the old message sent users to retry the network.
    func testReplaceWithCorruptZipThrowsExtractFailed() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("upd-corrupt"))
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let app = dir.appendingPathComponent("FileVault.app")
        try FileManager.default.createDirectory(atPath: app.appendingPathComponent("Contents/MacOS").path,
                                                withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("broken.zip")
        try Data("definitely not a zip".utf8).write(to: zip)
        XCTAssertThrowsError(try SelfUpdater.replace(bundleURL: app, newZipURL: zip,
                                                          relaunch: false, verifySignature: false)) { e in
            guard case UpdateError.extractFailed(let detail) = e else {
                return XCTFail("expected extractFailed, got \(e)")
            }
            XCTAssertTrue(detail.contains("ditto exited with status"), "carries the real reason: \(detail)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("FileVault.app.old").path),
                       "a failed extract must not rotate the running bundle")
    }

    func testReplaceWithNoAppInsideThrowsExtractFailed() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("upd-noapp"))
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let app = dir.appendingPathComponent("FileVault.app")
        try FileManager.default.createDirectory(atPath: app.appendingPathComponent("Contents/MacOS").path,
                                                withIntermediateDirectories: true)
        // A zip that unzips fine but contains only loose files.
        let stage = dir.appendingPathComponent("stage")
        try FileManager.default.createDirectory(atPath: stage.path, withIntermediateDirectories: true)
        try Data("loose".utf8).write(to: stage.appendingPathComponent("loose.txt"))
        let zip = dir.appendingPathComponent("noapp.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", stage.path, zip.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run(); ditto.waitUntilExit()
        XCTAssertThrowsError(try SelfUpdater.replace(bundleURL: app, newZipURL: zip,
                                                          relaunch: false, verifySignature: false)) { e in
            guard case UpdateError.extractFailed(let detail) = e else {
                return XCTFail("expected extractFailed, got \(e)")
            }
            XCTAssertTrue(detail.contains("no runnable .app"), detail)
        }
    }

    func testSweepOnlyRemovesStaleStagingDirs() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("upd-sweep"))
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let fm = FileManager.default
        let fresh = dir.appendingPathComponent("fv-update-fresh")
        let stale = dir.appendingPathComponent("fv-update-stale")
        let unrelated = dir.appendingPathComponent("unrelated-dir")
        for d in [fresh, stale, unrelated] {
            try fm.createDirectory(atPath: d.path, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)],
                             ofItemAtPath: stale.path)
        SelfUpdater.sweepOrphanStagingDirs(in: dir)
        XCTAssertTrue(fm.fileExists(atPath: fresh.path), "a current staging dir may still be in use")
        XCTAssertFalse(fm.fileExists(atPath: stale.path), "a day-old orphan is removed")
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path), "sweep only touches fv-update-* dirs")
    }

    func testShellQuotedSurvivesSingleQuotes() {
        XCTAssertEqual(SelfUpdater.shellQuoted("/Applications/FileVault.app"),
                       "'/Applications/FileVault.app'")
        XCTAssertEqual(SelfUpdater.shellQuoted("/tmp/it's here.app"),
                       "'/tmp/it'\\''s here.app'",
                       "an embedded quote must be re-escaped for /bin/sh")
    }
}
