import XCTest
@testable import FileVaultApp

/// v4.2.31 decoder hardening: git octal-escapes only inside C-quoted runs
/// (quote_c_style wraps an escaped path in double quotes). A valid-looking
/// octal OUTSIDE quotes is literal text from a hand-written commit subject
/// and must survive display untouched — the old branch decoded it into
/// U+FFFD replacement-character mojibake.
final class GitEscapeDecodingTests: XCTestCase {

    func testQuotedOctalRunsStillDecode() {
        // The legacy git C-quote form: escaped bytes inside a double-quoted
        // wrapper decode and the wrapper pair drops (v4.2.26 contract).
        let raw = "auto: 2 处变更，修改 \"report_\\346\\226\\207.md\" 和 \"data_\\350\\241\\250.txt\""
        XCTAssertEqual(raw.fvDecodingGitEscapes,
                       "auto: 2 处变更，修改 report_文.md 和 data_表.txt")
    }

    func testUnquotedOctalStaysLiteral() {
        // Regression (v4.2.31): a hand-written subject carrying the literal
        // text "修理 \\350 状态码" used to render the lone byte 0xE8 as U+FFFD.
        let raw = "修理 \\350 状态码"
        XCTAssertEqual(raw.fvDecodingGitEscapes, raw,
                       "octal outside a quoted run is literal text, not git escaping")
    }

    func testMixedQuotedDecodeAndUnquotedLiteral() {
        // One git-escaped path plus one literal backslash-octal in the same
        // subject: only the quoted run decodes.
        let raw = "见 \"\\350\\256\\260.md\" 与字面 \\350 示例"
        XCTAssertEqual(raw.fvDecodingGitEscapes, "见 记.md 与字面 \\350 示例")
    }

    func testIncompleteOctalOutsideQuotesIsLiteral() {
        // Pins the pre-existing behaviour (also in UIPresentationTests) under
        // the new inQuotes condition: nothing changes for short runs.
        let raw = "note \\34"
        XCTAssertEqual(raw.fvDecodingGitEscapes, raw)
    }
}
