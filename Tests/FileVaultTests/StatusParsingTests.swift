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
