import XCTest
@testable import FileVaultCore

final class FakeReleaseFetcher: ReleaseFetching {
    var result: Result<ReleaseInfo, Error>
    init(_ result: Result<ReleaseInfo, Error>) { self.result = result }
    func latest() async throws -> ReleaseInfo { try result.get() }
}

final class UpdateCheckTests: XCTestCase {
    func testSemverCompare() {
        XCTAssertEqual(HttpReleaseFetcher.compare("1.0.0", "1.0.0"), 0)
        XCTAssertEqual(HttpReleaseFetcher.compare("1.0.1", "1.0.0"), 1)
        XCTAssertEqual(HttpReleaseFetcher.compare("0.9.9", "1.0.0"), -1)
        XCTAssertEqual(HttpReleaseFetcher.compare("1.0", "1.0.0"), 0)
        XCTAssertEqual(HttpReleaseFetcher.compare("1.10.0", "1.9.9"), 1)
        XCTAssertEqual(HttpReleaseFetcher.compare("1.0.0.1", "1.0.0"), 1)
    }

    func testVersionFromTag() {
        XCTAssertEqual(HttpReleaseFetcher.version(fromTag: "v1.2.3"), "1.2.3")
        XCTAssertEqual(HttpReleaseFetcher.version(fromTag: "2.0.0"), "2.0.0")
    }

    func testCheckReturnsNewerOffer() async throws {
        let newer = ReleaseInfo(version: "1.1.0", tagName: "v1.1.0", notes: "n", assetName: "FileVault-1.1.0.zip", sha256: "abc")
        let checker = UpdateChecker(currentVersion: "1.0.0", fetcher: FakeReleaseFetcher(.success(newer)))
        let offer = try await checker.check()
        XCTAssertEqual(offer?.version, "1.1.0")
    }

    func testCheckNilWhenUpToDate() async throws {
        let same = ReleaseInfo(version: "1.0.0", tagName: "v1.0.0", notes: "n", assetName: "FileVault-1.0.0.zip", sha256: nil)
        let checker = UpdateChecker(currentVersion: "1.0.0", fetcher: FakeReleaseFetcher(.success(same)))
        let offer = try await checker.check()
        XCTAssertNil(offer)
    }

    func testParseReleasePayload() throws {
        let json = """
        {"tag_name": "v1.2.0", "body": "notes here",
         "assets": [{"name": "FileVault-1.2.0.zip", "digest": "sha256:deadbeef",
                     "id": 424242, "size": 659608,
                     "browser_download_url": "https://github.com/x/y/releases/download/v1.2.0/FileVault-1.2.0.zip"},
                    {"name": "other.tar.gz"}]}
        """
        let info = try HttpReleaseFetcher.parseRelease(Data(json.utf8))
        XCTAssertEqual(info.version, "1.2.0")
        XCTAssertEqual(info.assetName, "FileVault-1.2.0.zip")
        XCTAssertEqual(info.sha256, "deadbeef")
        XCTAssertEqual(info.notes, "notes here")
        XCTAssertEqual(info.assetID, 424242)
        XCTAssertEqual(info.assetSize, 659608, "asset size needed for progress")
        XCTAssertEqual(info.assetURL, "https://github.com/x/y/releases/download/v1.2.0/FileVault-1.2.0.zip",
                       "browser_download_url needed for direct HTTPS download (v2.6.4)")
    }

    func testParseReleaseWithoutZipAsset() {
        let json = Data(#"{"tag_name": "v1.0.0", "assets": [{"name": "x.tar.gz"}]}"#.utf8)
        XCTAssertThrowsError(try HttpReleaseFetcher.parseRelease(json)) { e in
            XCTAssertEqual(e as? UpdateError, .noAsset)
        }
    }
}

final class SelfUpdaterTests: XCTestCase {
    func testSha256KnownVector() {
        XCTAssertEqual(SelfUpdater.sha256(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testVerifyRejectsCorruptedZip() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("updverify"))
        let zip = dir.appendingPathComponent("f.zip")
        try Data("not-a-real-zip".utf8).write(to: zip)
        XCTAssertThrowsError(try SelfUpdater.verify(zipURL: zip, expectedSHA256: "0000")) { e in
            XCTAssertEqual(e as? UpdateError, .checksumMismatch)
        }
        // v4.2.26: no digest is FAIL-CLOSED. GitHub's API always sends a digest
        // for published assets; a missing one means we cannot prove the download
        // matches the release, so installing it silently was a security hole.
        XCTAssertThrowsError(try SelfUpdater.verify(zipURL: zip, expectedSHA256: nil)) { e in
            XCTAssertEqual(e as? UpdateError, .missingChecksum)
        }
        try? FileManager.default.removeItem(atPath: dir.path)
    }

    /// Full replace simulation: fake bundle + fake update zip in temp dirs.
    func testReplaceSwapsBundleAndKeepsOld() throws {
        let work = URL(fileURLWithPath: TestSupport.makeTempDir("updreplace"))
        let parent = work.appendingPathComponent("Applications")
        let oldApp = parent.appendingPathComponent("FileVault.app")
        try FileManager.default.createDirectory(at: oldApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("old-binary".utf8).write(to: oldApp.appendingPathComponent("Contents/MacOS/FileVaultApp"))
        // Build the "update" zip containing a newer bundle.
        let stage = work.appendingPathComponent("stage/FileVault.app")
        try FileManager.default.createDirectory(at: stage.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("new-binary".utf8).write(to: stage.appendingPathComponent("Contents/MacOS/FileVaultApp"))
        let zip = work.appendingPathComponent("update.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", stage.path, zip.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)
        // Replace without relaunch (relaunch would open the real app in tests).
        // These fabricated bundles are unsigned, so skip the signature gate.
        try SelfUpdater.replace(bundleURL: oldApp, newZipURL: zip, relaunch: false, verifySignature: false)
        let installed = try String(contentsOf: oldApp.appendingPathComponent("Contents/MacOS/FileVaultApp"), encoding: .utf8)
        XCTAssertEqual(installed, "new-binary")
        let backup = try String(contentsOf: parent.appendingPathComponent("FileVault.app.old/Contents/MacOS/FileVaultApp"), encoding: .utf8)
        XCTAssertEqual(backup, "old-binary", "previous version kept for rollback")
        try? FileManager.default.removeItem(atPath: work.path)
    }
}
