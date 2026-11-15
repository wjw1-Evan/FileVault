import XCTest
@testable import FileVaultCore

/// Regression tests for the v2.6.6 full-code audit.
final class AuditRegressionTests: XCTestCase {
    // MARK: - Log parsing (subjects containing "|")

    private func makeRepo() throws -> (root: String, repo: String, repos: RepoManager, history: HistoryService) {
        let root = TestSupport.makeTempDir("auditlog")
        try? FileManager.default.createDirectory(atPath: root + "/repo", withIntermediateDirectories: true)
        TestSupport.write("seed", to: root + "/repo/seed.txt")
        let repos = RepoManager(runner: TestSupport.newRunner())
        return (root, root + "/repo", repos, HistoryService(repoManager: repos))
    }

    func testLogSurvivesPipeInSubject() async throws {
        let (root, repo, repos, history) = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await repos.ensureRepos(root: root)
        TestSupport.write("v2", to: repo + "/f.md")
        let subject = "auto: 修复 a|b 问题 | second pipe"
        _ = try await repos.commitAll(path: repo, message: subject)
        let commits = try await history.commits(repoPath: repo)
        XCTAssertEqual(commits.first?.subject, subject, "subject must survive NUL-based parsing verbatim")
        XCTAssertGreaterThan(commits.first!.date.timeIntervalSince1970, 1_600_000_000,
                             "date parsed from ISO8601, not the 1970 fallback")
    }

    func testFileHistorySurvivesPipeInSubject() async throws {
        let (root, repo, repos, history) = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await repos.ensureRepos(root: root)
        TestSupport.write("v1", to: repo + "/f.md")
        _ = try await repos.commitAll(path: repo, message: "v1 | 初始")
        let timeline = try await history.fileHistory(repoPath: repo, file: "f.md")
        XCTAssertEqual(timeline.first?.subject, "v1 | 初始")
        XCTAssertGreaterThan(timeline.first!.date.timeIntervalSince1970, 1_600_000_000)
    }

    // MARK: - ConfigStore: corrupt file must not poison the cache

    func testCorruptConfigFileDoesNotPoisonCache() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("cfgstore"))
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let store = ConfigStore(directory: dir)
        try? Data("not-json".utf8).write(to: dir.appendingPathComponent("config.json"))
        XCTAssertEqual(store.load().roots.count, 0, "corrupt file decodes to the default")
        // The real config reappears on disk (e.g. user repaired it); the SAME
        // store instance must read it back instead of serving the cached empty.
        let healed = AppConfig(roots: [ManagedRoot(path: "/tmp/healed-root")])
        let data = try JSONEncoder().encode(healed)
        try data.write(to: dir.appendingPathComponent("config.json"))
        XCTAssertTrue(store.load().roots.first?.path.hasSuffix("/healed-root") == true,
                      "no poisoned cache: healed disk config is picked up")
    }

    // MARK: - GhRepoCreator: login resolution + failure surfacing

    private func writeFakeGh(_ body: String) throws -> String {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("fakegh"))
        let path = dir.appendingPathComponent("gh")
        try body.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path.path
    }

    func testSuccessfulCreationResolvesLogin() async throws {
        let gh = try writeFakeGh("#!/bin/sh\nif [ \"$1\" = \"api\" ]; then echo octocat; fi\nexit 0\n")
        let url = try await GhRepoCreator().createPrivate(name: "my-repo", ghPath: gh)
        XCTAssertEqual(url, "https://github.com/octocat/my-repo.git")
    }

    func testUnresolvableLoginThrowsInsteadOfGarbageURL() async throws {
        let gh = try writeFakeGh("#!/bin/sh\nexit 0\n")
        do {
            _ = try await GhRepoCreator().createPrivate(name: "my-repo", ghPath: gh)
            XCTFail("empty login must throw instead of building a broken URL")
        } catch {
            XCTAssertTrue(String(describing: error).contains("gh 账号"),
                          "error must explain the missing login, not build a broken URL")
        }
    }

    func testFailingCreateSurfacesStderr() async throws {
        let gh = try writeFakeGh("#!/bin/sh\necho boom >&2\nexit 3\n")
        do {
            _ = try await GhRepoCreator().createPrivate(name: "my-repo", ghPath: gh)
            XCTFail("non-zero gh exit must throw")
        } catch {
            XCTAssertTrue(String(describing: error).contains("boom"), "gh stderr must reach the error")
        }
    }

    func testMissingGhBinaryThrowsImmediately() async throws {
        do {
            _ = try await GhRepoCreator().createPrivate(name: "my-repo", ghPath: "/nonexistent/gh")
            XCTFail("missing gh binary must throw")
        } catch { /* expected */ }
    }

    // MARK: - Shell quoting for the relaunch helper

    func testShellQuoting() {
        XCTAssertEqual(SelfUpdater.shellQuoted("/Applications/FileVault.app"), "'/Applications/FileVault.app'")
        XCTAssertEqual(SelfUpdater.shellQuoted("/tmp/my 'vault'"), "'/tmp/my '\\''vault'\\'''")
    }
}
