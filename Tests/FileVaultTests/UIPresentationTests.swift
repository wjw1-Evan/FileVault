import XCTest
@testable import FileVaultApp

/// Display-layer formatting shared by the dashboard and history windows.
final class UIPresentationTests: XCTestCase {
    func testDecodesGitOctalEscapedFilename() {
        let raw = "auto: 1 处变更 (+1 -0)，修改 \"file20_\\345\\211\\257\\346\\234\\254.md\""
        XCTAssertEqual(raw.fvDecodingGitEscapes,
                       "auto: 1 处变更 (+1 -0)，修改 file20_副本.md")
    }

    func testDecodesSeveralEscapedSegments() {
        let raw = "\"a_\\344\\270\\255.md\"、\"b_\\346\\226\\207.txt\""
        XCTAssertEqual(raw.fvDecodingGitEscapes, "a_中.md、b_文.txt")
    }

    func testPlainSubjectsAreUntouched() {
        let plain = "auto: 初始版本"
        XCTAssertEqual(plain.fvDecodingGitEscapes, plain)
        let withQuotes = "rollback: 恢复 第一章.md 到 e64d4e1"
        XCTAssertEqual(withQuotes.fvDecodingGitEscapes, withQuotes)
    }

    func testIncompleteEscapeIsKeptLiterally() {
        let raw = "note \\34"
        XCTAssertEqual(raw.fvDecodingGitEscapes, raw)
    }
}
