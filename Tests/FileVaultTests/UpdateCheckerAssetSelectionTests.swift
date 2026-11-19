import XCTest
@testable import FileVaultCore

/// UpdateChecker / parseRelease selection contract (coverage round, v4.2.31):
/// the version-in-filename guard that stops stale re-uploaded zips (the
/// v4.2.27 incident) must match versions at TOKEN boundaries — contains()
/// let a release looking for 4.2.3 falsely match FileVault-4.2.31.zip and
/// refuse the update as "ambiguous".
final class UpdateCheckerAssetSelectionTests: XCTestCase {

    private func payload(_ assets: [[String: Any]], tag: String) throws -> Data {
        let obj: [String: Any] = ["tag_name": tag, "body": "notes", "assets": assets]
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private func asset(_ name: String, digest: String? = "sha256:" + String(repeating: "a", count: 64)) -> [String: Any] {
        var entry: [String: Any] = ["name": name, "id": NSNumber(value: 1),
                                    "size": NSNumber(value: 21_000_000),
                                    "browser_download_url": "https://example/" + name]
        if let digest { entry["digest"] = digest }
        return entry
    }

    /// The regression (v4.2.31): a prefix-neighbour asset must not count as a
    /// version match. With contains(), the stale 4.2.31 zip matched a 4.2.3
    /// release too, the two "matches" read as ambiguous, and the legitimate
    /// update was refused with noAsset.
    func testPrefixNeighbourAssetDoesNotCreateFalseAmbiguity() throws {
        let data = try payload([asset("FileVault-4.2.3.zip"), asset("FileVault-4.2.31.zip")],
                               tag: "v4.2.3")
        let info = try HttpReleaseFetcher.parseRelease(data)
        XCTAssertEqual(info.assetName, "FileVault-4.2.3.zip",
                       "the version-exact zip wins; the prefix neighbour is not a match")
    }

    func testVersionBoundaryIsTokenBased() {
        XCTAssertTrue(HttpReleaseFetcher.assetName("FileVault-4.2.31.zip", pinsVersion: "4.2.31"))
        XCTAssertTrue(HttpReleaseFetcher.assetName("FileVault-4.2.3.zip", pinsVersion: "4.2.3"))
        // digits on either side mean a DIFFERENT version token
        XCTAssertFalse(HttpReleaseFetcher.assetName("FileVault-4.2.31.zip", pinsVersion: "4.2.3"))
        XCTAssertFalse(HttpReleaseFetcher.assetName("FileVault-42.31.zip", pinsVersion: "2.3"))
        // non-digit flanks still delimit the token
        XCTAssertTrue(HttpReleaseFetcher.assetName("FileVault-4.2.3(1).zip", pinsVersion: "4.2.3"))
        XCTAssertFalse(HttpReleaseFetcher.assetName("FileVault-latest.zip", pinsVersion: "4.2.3"))
        XCTAssertFalse(HttpReleaseFetcher.assetName("anything", pinsVersion: ""))
    }

    /// Documented tolerance (v4.2.27): a single zip without the version in its
    /// name is still accepted — future naming must not brick updates.
    func testSingleUnversionedZipFallsBack() throws {
        let data = try payload([asset("FileVault-latest.zip")], tag: "v4.2.31")
        let info = try HttpReleaseFetcher.parseRelease(data)
        XCTAssertEqual(info.assetName, "FileVault-latest.zip")
    }

    func testTwoUnversionedZipsAreRefused() {
        XCTAssertThrowsError(try HttpReleaseFetcher.parseRelease(
            try payload([asset("FileVault-latest.zip"), asset("FileVault.zip")], tag: "v4.2.31"))) { e in
            XCTAssertEqual(e as? UpdateError, .noAsset)
        }
    }

    /// v4.2.27: the previous bundle kept as .old never re-enters candidates.
    func testDotOldAssetIsNeverACandidate() {
        XCTAssertThrowsError(try HttpReleaseFetcher.parseRelease(
            try payload([asset("FileVault-4.2.31.zip.old")], tag: "v4.2.31"))) { e in
            XCTAssertEqual(e as? UpdateError, .noAsset)
        }
    }

    func testDigestForms() throws {
        let data = try payload([asset("FileVault-4.2.31.zip", digest: "sha256:cafebabe")],
                               tag: "v4.2.31")
        XCTAssertEqual(try HttpReleaseFetcher.parseRelease(data).sha256, "cafebabe")
        let bare = try payload([asset("FileVault-4.2.31.zip", digest: "cafebabe")], tag: "v4.2.31")
        XCTAssertEqual(try HttpReleaseFetcher.parseRelease(bare).sha256, "cafebabe",
                       "a digest without the sha256: prefix is kept as-is")
        let none = try payload([asset("FileVault-4.2.31.zip", digest: nil)], tag: "v4.2.31")
        XCTAssertNil(try HttpReleaseFetcher.parseRelease(none).sha256)
    }

    func testBrokenPayloadsThrowNoRelease() {
        XCTAssertThrowsError(try HttpReleaseFetcher.parseRelease(Data("not json".utf8))) { e in
            XCTAssertEqual(e as? UpdateError, .noRelease)
        }
        let noTag = try? JSONSerialization.data(withJSONObject: ["assets": []] as [String: Any])
        XCTAssertThrowsError(try HttpReleaseFetcher.parseRelease(noTag!)) { e in
            XCTAssertEqual(e as? UpdateError, .noRelease)
        }
    }

    func testVersionExtractionAndNumericComparison() {
        XCTAssertEqual(HttpReleaseFetcher.version(fromTag: "v1.2.3"), "1.2.3")
        XCTAssertEqual(HttpReleaseFetcher.version(fromTag: "4.2.31"), "4.2.31")
        // per-component numeric, not lexicographic: 9 < 31 as integers
        XCTAssertEqual(HttpReleaseFetcher.compare("4.2.31", "4.2.9"), 1)
        XCTAssertEqual(HttpReleaseFetcher.compare("4.2.9", "4.2.31"), -1)
        XCTAssertEqual(HttpReleaseFetcher.compare("1.0", "1.0.0"), 0, "missing components are zero")
        XCTAssertEqual(HttpReleaseFetcher.compare("1.0.0", "1.0.0"), 0)
        XCTAssertEqual(HttpReleaseFetcher.compare("x.y.2", "1.0.1"), -1, "garbage components count as 0")
    }

    func testCheckerReturnsOnlyNewerReleases() async throws {
        let newer = ReleaseInfo(version: "4.2.31", tagName: "v4.2.31", notes: "",
                                assetName: "FileVault-4.2.31.zip", sha256: nil)
        struct Stub: ReleaseFetching {
            let info: ReleaseInfo?
            func latest() async throws -> ReleaseInfo { info! }
        }
        let offer = try await UpdateChecker(currentVersion: "4.2.30", fetcher: Stub(info: newer)).check()
        XCTAssertEqual(offer?.version, "4.2.31")
        let stale = try await UpdateChecker(currentVersion: "4.2.31", fetcher: Stub(info: newer)).check()
        XCTAssertNil(stale, "equal version is up to date")
    }

    /// The hand-written == drives failure dedup: format cases must compare by
    /// payload, and different constructors must never collide.
    func testUpdateErrorEqualitySemantics() {
        XCTAssertEqual(UpdateError.httpStatus(500), UpdateError.httpStatus(500))
        XCTAssertNotEqual(UpdateError.httpStatus(500), UpdateError.httpStatus(503))
        XCTAssertEqual(UpdateError.downloadTransport("offline"), UpdateError.downloadTransport("offline"))
        XCTAssertNotEqual(UpdateError.downloadTransport("a"), UpdateError.downloadTransport("b"))
        XCTAssertNotEqual(UpdateError.extractFailed("x"), UpdateError.signatureRejected("x"))
        XCTAssertNotEqual(UpdateError.noRelease, UpdateError.noAsset)
        XCTAssertEqual(UpdateError.checksumMismatch, UpdateError.checksumMismatch)
        // message building stays specific (the menu shows these verbatim)
        XCTAssertTrue(UpdateError.httpStatus(500).errorDescription?.contains("500") == true)
        XCTAssertTrue(UpdateError.downloadTransport("offline").errorDescription?.contains("offline") == true)
    }
}
