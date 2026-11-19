import XCTest
@testable import FileVaultCore

/// RepoHealth's pure presentation: byte formatting at its unit boundaries and
/// the summary line every folder card renders (readable, capped, with the
/// warning suffixes the README documents).
final class RepoHealthFormattingTests: XCTestCase {

    private func health(commitCount: Int = 3,
                        sizeBytes: UInt64 = 512 * 1024,
                        lastCommitDate: Date? = nil,
                        excludedLargeFileCount: Int = 0,
                        available: Bool = true,
                        readError: String? = nil) -> RepoHealth {
        RepoHealth(commitCount: commitCount, sizeBytes: sizeBytes,
                   lastCommitDate: lastCommitDate, excludedLargeFileCount: excludedLargeFileCount,
                   available: available, readError: readError)
    }

    func testSizeTextUnitBoundaries() {
        XCTAssertEqual(health(sizeBytes: 0).sizeText, "0KB")
        XCTAssertEqual(health(sizeBytes: 512 * 1024).sizeText, "512KB")
        XCTAssertEqual(health(sizeBytes: 1024 * 1024).sizeText, "1MB")
        XCTAssertEqual(health(sizeBytes: 200 * 1024 * 1024).sizeText, "200MB")
        // 1 GiB is shown in GB with one decimal.
        XCTAssertEqual(health(sizeBytes: 1024 * 1024 * 1024).sizeText, "1.0GB")
    }

    func testSummaryStatesUnavailabilityAndReadErrors() {
        XCTAssertFalse(health(available: false).summary.isEmpty)
        XCTAssertTrue(health(available: false).summary.contains("不可用"))

        // v4.2.30 audit item 5: the raw exit code is gone, the readable
        // reason with a proper format string is in.
        let failed = health(readError: "仓库暂时读不到（可能正忙或磁盘不可用），稍后重试。")
        XCTAssertTrue(failed.summary.contains("⚠️ 仓库读取失败"), failed.summary)
        XCTAssertTrue(failed.summary.contains("仓库暂时读不到"), failed.summary)
        XCTAssertFalse(failed.summary.contains("128"), "no raw exit codes in the summary")
    }

    func testSummaryCountsDatesAndWarnings() {
        XCTAssertFalse(health(commitCount: 0).summary.contains("1 次提交"),
                       "zero is a plural count, not the singular line")
        XCTAssertTrue(health(commitCount: 1).summary.contains("1 次提交"))
        XCTAssertTrue(health(commitCount: 42).summary.contains("42 次提交"))

        let dated = health(lastCommitDate: Date(timeIntervalSince1970: 1_763_000_000))
        XCTAssertTrue(dated.summary.contains(" · 最近 "), "the date suffix renders")

        let big = health(sizeBytes: UInt64(RepoManager.repoSizeWarningThreshold) + 1)
        XCTAssertTrue(big.summary.contains("超过 2GB"), "the README-documented warning")

        let excluded = health(excludedLargeFileCount: 4)
        XCTAssertTrue(excluded.summary.contains("4 个大文件未同步"),
                      "unbacked large files are called out")
    }
}
