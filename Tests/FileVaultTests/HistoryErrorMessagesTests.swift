import XCTest
@testable import FileVaultCore

/// HistoryError messages are the readable-failure contract (README 核心功能 7:
/// 「不存在的文件/版本会明确报错而不是静默失败」). Every case must produce a
/// specific message carrying its argument; the stderr cases fall back to a
/// readable unknown instead of an empty string; the multi-file cases cap at
/// three names plus a count.
final class HistoryErrorMessagesTests: XCTestCase {

    func testSingleArgumentCasesCarryTheirArgument() {
        let cases: [(HistoryError, String)] = [
            (.invalidPath("../evil.txt"), "../evil.txt"),
            (.commitNotFound("abc123"), "abc123"),
            (.exportFailed(file: "设计稿.psd"), "设计稿.psd"),
            (.invalidTagName("bad tag"), "bad tag"),
            (.restoreTargetIsDirectory(file: "b.txt"), "b.txt"),
            (.restoreWouldOverwriteIgnored(file: ".env"), ".env"),
            (.repositoryBusy, ""),
        ]
        for (error, argument) in cases {
            let message = error.errorDescription
            XCTAssertNotNil(message, "\(error) must describe itself")
            XCTAssertFalse(message!.isEmpty, "\(error) message must not be empty")
            if !argument.isEmpty {
                XCTAssertTrue(message!.contains(argument),
                               "\(error) message must carry its argument: \(message!)")
            }
        }
    }

    func testFileAndDirectoryCasesCarryBothArguments() {
        let notInCommit = HistoryError.fileNotInCommit(file: "notes/第3章.md", hash: "def999")
        XCTAssertTrue(notInCommit.errorDescription?.contains("notes/第3章.md") == true)
        XCTAssertTrue(notInCommit.errorDescription?.contains("def999") == true)

        let dirNotInCommit = HistoryError.directoryNotInCommit(directory: "附录", hash: "def999")
        XCTAssertTrue(dirNotInCommit.errorDescription?.contains("附录") == true)
        XCTAssertTrue(dirNotInCommit.errorDescription?.contains("def999") == true)
    }

    /// v3.3.1: an empty stderr must not render as a blank line.
    func testStderrCasesFallBackToReadableUnknown() {
        XCTAssertEqual(HistoryError.resetFailed(stderr: "").errorDescription, "未知错误")
        XCTAssertEqual(HistoryError.restoreFailed(stderr: "").errorDescription, "未知错误")
        XCTAssertEqual(HistoryError.restoreFailed(stderr: "  \n \t ").errorDescription,
                       "未知错误", "whitespace-only stderr is no reason")
        XCTAssertEqual(HistoryError.resetFailed(stderr: "real cause").errorDescription, "real cause")
        XCTAssertEqual(HistoryError.restoreFailed(stderr: "boom\n").errorDescription, "boom")
    }

    /// The danger lists cap at three names plus a total count, so a big
    /// folder cannot blow up the dialog.
    func testDangerListsCapAtThreeNames() {
        let two = HistoryError.rollbackWouldOverwriteIgnored(files: ["a.env", "b.env"])
        let msg2 = two.errorDescription!
        XCTAssertTrue(msg2.contains("a.env、b.env"), msg2)
        XCTAssertFalse(msg2.contains("等 "), "no count suffix under four files")

        let five = HistoryError.rollbackWouldOverwriteIgnored(
            files: ["1.env", "2.env", "3.env", "4.env", "5.env"])
        let msg5 = five.errorDescription!
        XCTAssertTrue(msg5.contains("1.env、2.env、3.env"), "only the first three names: \(msg5)")
        XCTAssertTrue(msg5.contains("等 5 个文件"), msg5)
        XCTAssertFalse(msg5.contains("4.env"), "the tail names stay out of the line")

        let deleted = HistoryError.rollbackWouldDeleteUntracked(
            directory: "工作", files: ["1.log", "2.log", "3.log", "4.log"])
        let msgD = deleted.errorDescription!
        XCTAssertTrue(msgD.contains("工作"), msgD)
        XCTAssertTrue(msgD.contains("等 4 个文件"), msgD)
    }

    /// The enum is Equatable so UI model tests can assert the exact failure.
    func testEqualityIsValueBased() {
        XCTAssertEqual(HistoryError.commitNotFound("a"), HistoryError.commitNotFound("a"))
        XCTAssertNotEqual(HistoryError.commitNotFound("a"), HistoryError.commitNotFound("b"))
        XCTAssertNotEqual(HistoryError.repositoryBusy, HistoryError.commitNotFound("a"))
        XCTAssertEqual(HistoryError.rollbackWouldDeleteUntracked(directory: "x", files: ["a", "b"]),
                       HistoryError.rollbackWouldDeleteUntracked(directory: "x", files: ["a", "b"]))
    }
}
