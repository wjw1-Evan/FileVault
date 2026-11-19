import XCTest
@testable import FileVaultCore

/// The pure parsers behind the history windows: LFS pointer detection, diff
/// summarising (added/removed/binary/truncation) and git date parsing.
final class HistoryExtrasPureParsersTests: XCTestCase {

    func testLFSPointerDetection() {
        let pointer = GitLFSPointer.header + "\noid sha256:abc\nsize 123\n"
        XCTAssertTrue(GitLFSPointer.isPointer(pointer))
        XCTAssertFalse(GitLFSPointer.isPointer("version https://git-lfs.github.com/spec/v2\n"),
                       "only the v1 spec header counts")
        XCTAssertFalse(GitLFSPointer.isPointer("plain text file"))
        XCTAssertFalse(GitLFSPointer.isPointer(""))
    }

    func testMakeDiffCountsAddedAndRemoved() {
        let raw = """
diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -1,2 +1,3 @@
 context line
-old line
+new line
+another line
"""
        let diff = HistoryService.makeDiff(raw, maxBytes: 10_000)
        XCTAssertEqual(diff.added, 2)
        XCTAssertEqual(diff.removed, 1, "the --- header must not count as removal")
        XCTAssertFalse(diff.isBinary)
        XCTAssertFalse(diff.truncated)
        XCTAssertEqual(diff.text, raw)
    }

    func testMakeDiffDetectsBinaryAndTruncatesOnBytes() {
        let binary = "diff --git a/img.png b/img.png\nBinary files differ\n"
        XCTAssertTrue(HistoryService.makeDiff(binary, maxBytes: 1000).isBinary)

        // The byte cap cuts on UTF-8 bytes, never mid-character.
        let text = "你好你好你好你好" + String(repeating: "x", count: 40)
        let truncated = HistoryService.makeDiff(text, maxBytes: 10)
        XCTAssertTrue(truncated.truncated)
        XCTAssertLessThanOrEqual(truncated.text.utf8.count, 10,
                                 "never more than maxBytes")
        XCTAssertFalse(truncated.text.contains("\u{FFFD}"), "no replacement-character debris")

        let exact = HistoryService.makeDiff("abcdefghij", maxBytes: 10)
        XCTAssertFalse(exact.truncated, "exactly maxBytes is not truncated")
    }

    func testParseGitDateHandlesISOAndFallbackFormats() {
        XCTAssertNotNil(HistoryService.parseGitDate("2026-11-19T12:34:56+08:00"))
        XCTAssertNotNil(HistoryService.parseGitDate("2026-11-19 12:34:56 +0800"),
                        "git's raw log date format")
        XCTAssertNil(HistoryService.parseGitDate("not a date"))
        XCTAssertNil(HistoryService.parseGitDate(""))
    }
}
