import Foundation
import XCTest
@testable import FileVaultCore

/// Remote-aware threshold resolution (FR-12, v3.1.3).
///
/// There is no local threshold setting anymore: the value always comes from the
/// remote (github.com → 100 MiB, everything else → no known limit).
final class GitHubLimitsTests: XCTestCase {
    func testRemoteHostParsing() {
        let cases: [(String?, String?)] = [
            ("https://github.com/wjw1-Evan/FileVault.git", "github.com"),
            ("http://github.com/a/b", "github.com"),
            ("https://www.github.com/a/b.git", "www.github.com"),
            ("https://user:token@github.com/a/b.git", "github.com"),
            ("ssh://git@github.com/a/b.git", "github.com"),
            ("ssh://git@github.com:22/a/b.git", "github.com"),
            ("git@github.com:a/b.git", "github.com"),
            ("GitHub.com:a/b.git", "github.com"),
            ("https://gitlab.com/a/b.git", "gitlab.com"),
            ("/tmp/bare-remote.git", nil),
            ("file:///tmp/bare-remote.git", nil),
            ("", nil),
            (nil, nil)
        ]
        for (input, expected) in cases {
            XCTAssertEqual(GitHubLimits.remoteHost(input), expected,
                           "remoteHost(\(String(describing: input)))")
        }
    }

    func testIsGitHubRemote() {
        XCTAssertTrue(GitHubLimits.isGitHubRemote("https://github.com/a/b.git"))
        XCTAssertTrue(GitHubLimits.isGitHubRemote("git@github.com:a/b.git"))
        XCTAssertTrue(GitHubLimits.isGitHubRemote("ssh://git@www.github.com:22/a/b.git"))
        XCTAssertFalse(GitHubLimits.isGitHubRemote("https://github.com.evil.example/a/b.git"))
        XCTAssertFalse(GitHubLimits.isGitHubRemote("https://github.company.com/a/b"))
        XCTAssertFalse(GitHubLimits.isGitHubRemote("https://gitlab.com/a/b"))
        XCTAssertFalse(GitHubLimits.isGitHubRemote("/tmp/bare.git"))
        XCTAssertFalse(GitHubLimits.isGitHubRemote(nil))
    }

    func testEffectiveThresholdFollowsGitHubHardLimit() {
        XCTAssertEqual(
            GitHubLimits.effectiveThreshold(remoteURL: "https://github.com/a/b.git"),
            GitHubLimits.blockBytes)
        XCTAssertEqual(
            GitHubLimits.effectiveThreshold(remoteURL: "git@github.com:a/b.git"),
            GitHubLimits.blockBytes)
        XCTAssertEqual(
            GitHubLimits.effectiveThreshold(remoteURL: "ssh://git@github.com:22/a/b.git"),
            GitHubLimits.blockBytes)
    }

    func testEffectiveThresholdIsUnlimitedForOtherRemotes() {
        // 0 == "the remote publishes no single-file limit, exclude nothing".
        XCTAssertEqual(GitHubLimits.effectiveThreshold(remoteURL: "https://gitlab.com/a/b.git"), 0)
        XCTAssertEqual(GitHubLimits.effectiveThreshold(remoteURL: "https://self-hosted.example/a"), 0)
        XCTAssertEqual(GitHubLimits.effectiveThreshold(remoteURL: "/tmp/bare.git"), 0)
        XCTAssertEqual(GitHubLimits.effectiveThreshold(remoteURL: nil), 0)
    }

    func testConstantsMatchGitHubLimits() {
        let warn: UInt64 = 50 * 1024 * 1024
        let block: UInt64 = 100 * 1024 * 1024
        XCTAssertEqual(GitHubLimits.warnBytes, warn)
        XCTAssertEqual(GitHubLimits.blockBytes, block)
        XCTAssertLessThan(GitHubLimits.warnBytes, GitHubLimits.blockBytes)
        XCTAssertLessThan(GitHubLimits.blockBytes, GitHubLimits.lfsMaxBytes)
    }
}

/// End-to-end: the commit pipeline takes the threshold from the repo's remote.
final class CommitEngineRemoteThresholdTests: XCTestCase {
    var root: String!
    var repos: RepoManager!
    var engine: CommitEngine!

    override func setUp() async throws {
        root = TestSupport.makeTempDir("remotethreshold")
        try? FileManager.default.createDirectory(atPath: root + "/vault/work", withIntermediateDirectories: true)
        TestSupport.write("hello", to: root + "/vault/work/note.md")
        repos = RepoManager(runner: TestSupport.newRunner())
        try await repos.ensureRepos(root: root + "/vault")
        let debouncer = Debouncer(quietInterval: 5, maxWait: 30, onFired: { _ in })
        engine = CommitEngine(repoManager: repos, debouncer: debouncer, pause: PauseController())
    }

    override func tearDown() {
        if let root {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: root + "-remote.git")
        }
    }

    private func repoPath() -> String { root + "/vault/work" }

    private func attachBareRemote() async throws -> String {
        let remote = root + "-remote.git"
        _ = try await repos.runner.run(["init", "--bare", remote])
        return remote
    }

    func testEffectiveThresholdFollowsRemote() async throws {
        try await repos.setRemote(path: repoPath(), url: "https://github.com/acme/notes.git")
        let github = await engine.effectiveThreshold(for: repoPath())
        XCTAssertEqual(github, GitHubLimits.blockBytes, "github.com must yield its 100 MiB limit")

        let bare = try await attachBareRemote()
        try await repos.setRemote(path: repoPath(), url: bare)
        let plain = await engine.effectiveThreshold(for: repoPath())
        XCTAssertEqual(plain, 0, "other remotes publish no limit, so nothing may be excluded")

        try await repos.clearRemote(path: repoPath())
        let noRemote = await engine.effectiveThreshold(for: repoPath())
        XCTAssertEqual(noRemote, 0)
    }

    func testGitHubRemoteExcludesFileAbove100MiB() async throws {
        try await repos.setRemote(path: repoPath(), url: "https://github.com/acme/notes.git")
        XCTAssertTrue(TestSupport.writeSparse(repoPath() + "/big.bin", bytes: 120 * 1024 * 1024))

        await engine.runCommitPipeline(repoPath: repoPath())

        let tracked = await repos.listFiles(path: repoPath())
        XCTAssertFalse(tracked.contains("big.bin"), "a 120 MiB file can never be pushed to GitHub")
        let exclude = try String(contentsOfFile: repoPath() + "/.git/info/exclude", encoding: .utf8)
        XCTAssertTrue(exclude.contains("big.bin"))
        let log = try await repos.log(path: repoPath())
        XCTAssertEqual(log.count, 1, "nothing but the initial commit should exist")
    }

    func testOtherRemotesAreNotLimited() async throws {
        let bare = try await attachBareRemote()
        try await repos.setRemote(path: repoPath(), url: bare)
        XCTAssertTrue(TestSupport.writeSparse(repoPath() + "/big.bin", bytes: 120 * 1024 * 1024))

        await engine.runCommitPipeline(repoPath: repoPath())

        let tracked = await repos.listFiles(path: repoPath())
        XCTAssertTrue(tracked.contains("big.bin"), "only the remote can impose a limit; a bare repo has none")
    }
}
