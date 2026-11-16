import XCTest
@testable import FileVaultCore

/// v4.2.10: unusual file names (spaces, newlines, quotes, " -> " inside a
/// renamed name) must survive the porcelain parsing — otherwise the wrong path
/// is staged/labelled or a rename is reported as a different file.
final class StatusParsingTests: XCTestCase {
    func testStatusKeepsUnusualFilenames() async throws {
        let dir = TestSupport.makeTempDir("weirdnames")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        TestSupport.write("seed", to: dir + "/seed.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: dir)

        let names = ["weird name.txt", "new\nline.txt", "arrow -> name.txt", "quote\"name.txt"]
        for name in names {
            TestSupport.write("x", to: dir + "/" + name)
        }
        let status = try await repos.status(path: dir)
        let paths = Set(status.map(\.path))
        for name in names {
            XCTAssertTrue(paths.contains(name), "missing \(name) in \(paths)")
        }

        _ = try await repos.commitAll(path: dir)
        let tracked = await repos.listFiles(path: dir)
        for name in names {
            XCTAssertTrue(tracked.contains(name), "missing committed \(name)")
        }
    }


    func testCommitSubjectFlattensUnusualNames() {
        let entries = [StatusEntry(change: .added, path: "new\nline.txt", originalPath: nil),
                       StatusEntry(change: .modified,
                                   path: String(repeating: "x", count: 120) + ".md", originalPath: nil)]
        let message = RepoManager.buildCommitMessage(entries: entries, additions: 1, deletions: 0)
        XCTAssertFalse(message.contains("\n"), "the subject must stay one line: \(message)")
        XCTAssertTrue(message.contains("new line.txt"), message)
        XCTAssertTrue(message.count < 200, "very long names must be shortened: \(message)")
        XCTAssertEqual(RepoManager.subjectLabel("a\tb\nc"), "a b c")
        XCTAssertEqual(RepoManager.subjectLabel(String(repeating: "y", count: 80)).count, 61)
    }
    func testStatusRenameKeepsNameWithArrow() async throws {
        let dir = TestSupport.makeTempDir("weirdrename")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        TestSupport.write("seed", to: dir + "/seed.md")
        TestSupport.write("x", to: dir + "/before.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: dir)
        _ = try await repos.commitAll(path: dir)

        _ = try await repos.runner.run(["mv", "before.md", "after -> weird.md"], cwd: dir)
        let status = try await repos.status(path: dir)
        XCTAssertEqual(status.count, 1, "\(status)")
        XCTAssertEqual(status[0].change, .renamed)
        XCTAssertEqual(status[0].path, "after -> weird.md")
        XCTAssertEqual(status[0].originalPath, "before.md")
    }
}
