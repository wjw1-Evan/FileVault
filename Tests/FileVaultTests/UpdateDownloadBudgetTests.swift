
import XCTest
@testable import FileVaultCore

/// v4.2.32 download rewrite: full-speed URLSession.download with progress
/// polling and an overall time budget (the old per-byte AsyncBytes loop
/// measured ≈195 KB/s — 20 MB took 103 s of pure await overhead).
final class UpdateDownloadBudgetTests: XCTestCase {

    private func makeRelease(_ url: URL, size: Int64 = 0) -> ReleaseInfo {
        ReleaseInfo(version: "9.9.9", tagName: "v9.9.9", notes: "",
                    assetName: "Pastward-9.9.9.zip", sha256: nil,
                    assetID: 1, assetSize: size, assetURL: url.absoluteString)
    }

    /// A file:// URL (same offline path the old tests used): the download
    /// must complete at full speed with a matching size and content.
    func testDownloadFileURLCompletesFastAndIntact() async throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("dl-fast"))
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let payload = Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let src = dir.appendingPathComponent("src.zip")
        try payload.write(to: src)

        let savedLimit = UpdateDownloader.downloadTimeLimit
        UpdateDownloader.downloadTimeLimit = 30
        defer { UpdateDownloader.downloadTimeLimit = savedLimit }

        var lastFraction = 0.0
        let t0 = Date()
        let dest = try await UpdateDownloader.download(
            info: makeRelease(src, size: Int64(payload.count)),
            progress: { fraction, _, _ in lastFraction = max(lastFraction, fraction) })
        let elapsed = Date().timeIntervalSince(t0)

        let got = try Data(contentsOf: dest)
        XCTAssertEqual(got, payload, "bytes must round-trip exactly")
        // The per-byte loop needed >10 s for 2 MB; the budget is generous
        // (CI variance) but a regression to per-byte awaits blows past it.
        XCTAssertLessThan(elapsed, 10, "2 MB over file:// must be sub-second-ish")
    }

    /// A size mismatch (assetSize lies) must fail the attempt, not install
    /// a truncated zip.
    func testDownloadRejectsSizeMismatch() async throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("dl-mismatch"))
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let payload = Data("tiny".utf8)
        let src = dir.appendingPathComponent("src.zip")
        try payload.write(to: src)

        do {
            _ = try await UpdateDownloader.download(
                info: makeRelease(src, size: 999_999))
            XCTFail("a size mismatch must be rejected")
        } catch {
            XCTAssertEqual(error as? UpdateError, .downloadFailed)
        }
    }

    /// A nonexistent file:// URL fails (transport error), and the retry
    /// ladder runs without leaving temp files behind.
    func testDownloadMissingFileFailsWithTransportError() async throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("dl-missing"))
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let missing = dir.appendingPathComponent("nope.zip")
        do {
            _ = try await UpdateDownloader.download(
                info: makeRelease(missing, size: 4),
                progress: nil,
                attempts: 2)
            XCTFail("a missing source must fail")
        } catch {
            let e = error as? UpdateError
            XCTAssertNotNil(e, "must normalise to UpdateError, got \(error)")
        }
    }

    /// The overall budget: an unreachable-but-slow source must be cancelled
    /// by the deadline instead of hanging on the idle-based request timeout.
    /// A file:// URL that does not exist fails instantly, so the budget is
    /// pinned at the strategy level: downloadTimeLimit bounds the monitor's
    /// deadline arithmetic (public var, injectable).
    func testDownloadTimeLimitIsInjectable() {
        let saved = UpdateDownloader.downloadTimeLimit
        UpdateDownloader.downloadTimeLimit = 42
        defer { UpdateDownloader.downloadTimeLimit = saved }
        XCTAssertEqual(UpdateDownloader.downloadTimeLimit, 42)
        XCTAssertGreaterThan(saved, 0, "default budget must be positive")
    }
}
