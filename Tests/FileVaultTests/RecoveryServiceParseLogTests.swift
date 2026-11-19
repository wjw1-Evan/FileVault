import XCTest
@testable import FileVaultCore

/// RecoveryService.parseLog contract: the -z --name-status record stream with
/// a %x01 pretty header. Pinned directly because the scan's correctness rests
/// entirely on this tokenizer, and a subject carrying a literal \u{1} (git
/// passes control bytes through %s — verified against real git 2.56) used to
/// drop the first file's record entirely (v4.2.31 fix: split only the three
/// structural separators).
final class RecoveryServiceParseLogTests: XCTestCase {
    private let x = "\u{1}"
    private let n = "\u{0}"

    func testNormalHeaderParsesSubjectStatusAndPath() {
        let raw = x + "HASH001" + x + "abc0001" + x + "2026-11-19T12:00:00+08:00" + x + "auto: 1 处变更" + "\nM" + n + "a.txt" + n
        let parsed = RecoveryService.parseLog(raw)
        XCTAssertEqual(parsed.commitCount, 1)
        XCTAssertEqual(parsed.records.count, 1)
        let r = parsed.records[0]
        XCTAssertEqual(r.commit, "HASH001")
        XCTAssertEqual(r.short, "abc0001")
        XCTAssertEqual(r.subject, "auto: 1 处变更")
        XCTAssertEqual(r.status, "M")
        XCTAssertEqual(r.path, "a.txt")
        XCTAssertNil(r.originalPath)
        XCTAssertNotNil(r.date, "ISO date must parse")
    }

    /// The regression: a subject containing a literal \u{1} must not eat the
    /// first file's status. Before the fix the status landed in a phantom
    /// part and the record vanished from the scan.
    func testSubjectWithLiteralSeparatorKeepsRecordIntact() {
        let raw = x + "HASH002" + x + "abc0002" + x + "2026-11-19T12:00:00+08:00"
            + x + "subject-with" + x + "byte" + "\nM" + n + "a.txt" + n
        let parsed = RecoveryService.parseLog(raw)
        XCTAssertEqual(parsed.commitCount, 1)
        XCTAssertEqual(parsed.records.count, 1,
                       "the first file record must survive a control byte in the subject")
        XCTAssertEqual(parsed.records[0].status, "M")
        XCTAssertEqual(parsed.records[0].path, "a.txt")
        XCTAssertEqual(parsed.records[0].subject, "subject-with" + x + "byte",
                       "the subject keeps its literal byte instead of being truncated")
    }

    func testRenameRecordConsumesOldAndNewPath() {
        let raw = x + "H" + x + "s" + x + "2026-11-19T12:00:00+08:00" + x + "sub" + "\nR100"
            + n + "old.txt" + n + "new.txt" + n
        let parsed = RecoveryService.parseLog(raw)
        XCTAssertEqual(parsed.records.count, 1)
        XCTAssertEqual(parsed.records[0].status, "R100")
        XCTAssertEqual(parsed.records[0].originalPath, "old.txt")
        XCTAssertEqual(parsed.records[0].path, "new.txt")
    }

    func testEmptyTokenSeparatesCommits() {
        let raw = x + "H1" + x + "s1" + x + "2026-11-19T12:00:00+08:00" + x + "one" + "\nA" + n + "f1" + n + n
            + x + "H2" + x + "s2" + x + "2026-11-19T12:01:00+08:00" + x + "two" + "\nD" + n + "f2" + n + n
        let parsed = RecoveryService.parseLog(raw)
        XCTAssertEqual(parsed.commitCount, 2)
        XCTAssertEqual(parsed.records.count, 2)
        XCTAssertEqual(parsed.records.map(\.path), ["f1", "f2"])
        XCTAssertEqual(parsed.records.map(\.status), ["A", "D"])
        XCTAssertFalse(parsed.truncated, "truncation is decided by the caller")
    }

    func testMalformedHeaderAndOrphanTokensAreSkipped() {
        let raw = x + "only" + x + "two" + n + "a.txt" + n
        let parsed = RecoveryService.parseLog(raw)
        XCTAssertEqual(parsed.commitCount, 0)
        XCTAssertTrue(parsed.records.isEmpty, "a path token without a parsed commit is dropped")
    }

    func testUnbornErrorDetection() {
        XCTAssertTrue(RecoveryService.isUnbornError("fatal: your current branch 'main' does not have any commits yet"))
        XCTAssertTrue(RecoveryService.isUnbornError("fatal: Not a valid object name HEAD"))
        XCTAssertTrue(RecoveryService.isUnbornError("fatal: unknown revision"))
        XCTAssertTrue(RecoveryService.isUnbornError("fatal: bad revision 'abc'"))
        XCTAssertFalse(RecoveryService.isUnbornError("fatal: unable to access remote"))
    }
}
