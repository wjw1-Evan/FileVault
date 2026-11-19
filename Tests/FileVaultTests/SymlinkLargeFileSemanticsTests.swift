import XCTest
@testable import FileVaultCore

/// v4.2.32 watchlist item 3 — FALSIFIED, and this file pins the evidence:
/// git records a symlink as a tiny blob holding the LINK TEXT (mode 120000,
/// 20 bytes in the probe experiment), and FileManager.attributesOfItem uses
/// lstat semantics — it also answers the link-text size (NSFileTypeSymbolicLink,
/// 20 bytes), NOT the target's 120 MB. The large-file guard therefore already
/// measures exactly what git stores: a symlink to an oversized file must NOT
/// be excluded. This test exists so nobody "fixes" the guard into a
/// stat-following API that would break that contract.
final class SymlinkLargeFileSemanticsTests: XCTestCase {

    func testSymlinkToOversizedFileIsNotExcluded() async throws {
        let base = TestSupport.makeTempDir("symlink-size")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/repo"
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: repoPath)

        // 120 MB sparse target — no disk cost, instant.
        let target = base + "/big.bin"
        XCTAssertTrue(TestSupport.writeSparse(target, bytes: 120 * 1024 * 1024))
        let link = repoPath + "/link.bin"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        // Foundation semantics pinned: lstat, not stat.
        let attrs = try FileManager.default.attributesOfItem(atPath: link)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
        let linkSize = attrs[.size] as? UInt64 ?? 0
        XCTAssertLessThan(linkSize, 1024, "the link text is what git stores, never the target bytes")

        // The guard must not treat the symlink as an oversized file.
        let entries = try await repos.status(path: repoPath)
        XCTAssertTrue(entries.contains { $0.path == "link.bin" }, "the symlink is a change git sees")
        let excluded = await repos.excludeLargeFiles(path: repoPath,
                                                     threshold: 100 * 1024 * 1024,
                                                     entries: entries)
        XCTAssertTrue(excluded.isEmpty,
                       "a symlink blob is link-text-sized; excluding it would misreport it as unbacked")
    }

    /// What git ACTUALLY commits for the symlink: a 20-ish byte blob. If this
    /// ever changes (it should not), the exclusion contract above changes too.
    func testGitStoresOnlyTheLinkTextForSymlinks() async throws {
        let base = TestSupport.makeTempDir("symlink-blob")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/repo"
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: repoPath)

        let target = base + "/big.bin"
        XCTAssertTrue(TestSupport.writeSparse(target, bytes: 120 * 1024 * 1024))
        try FileManager.default.createSymbolicLink(atPath: repoPath + "/link.bin", withDestinationPath: target)

        _ = try await repos.commitAll(path: repoPath, message: "add symlink")

        let mode = try await repos.runner.run(["ls-files", "-s", "--", "link.bin"], cwd: repoPath)
        XCTAssertTrue(mode.stdout.hasPrefix("120000"), "git records symlinks with the 120000 mode, got: \(mode.stdout)")

        let blob = try await repos.runner.run(["cat-file", "-s", "HEAD:link.bin"], cwd: repoPath)
        XCTAssertEqual(blob.exitCode, 0)
        let stored = Int(blob.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        XCTAssertLessThan(stored, 1024, "the committed blob is the link text, not the target")
    }
}
