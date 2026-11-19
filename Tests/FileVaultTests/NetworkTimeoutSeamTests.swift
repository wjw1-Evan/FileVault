import XCTest
@testable import FileVaultCore

/// v4.2.32 watchlist item 1: the network budget must be injectable so the
/// timeout branch is testable without waiting two real minutes, and a
/// timed-out network command must surface as the classified readable
/// network error (not a raw exit code).
final class NetworkTimeoutSeamTests: XCTestCase {

    /// A fake git whose network commands stall. Argument scanning is
    /// positional-agnostic — GitRunner prepends its own flags, so `$1`
    /// never holds the subcommand (the documented fixture pitfall).
    private func makeSleepingGit(_ base: String, seconds: Int) -> String {
        let path = base + "/slow-git.sh"
        let script = """
        #!/bin/bash
        for a in "$@"; do
          case "$a" in
            fetch|push|pull) sleep \(seconds); exit 0;;
          esac
        done
        exit 0
        """
        FileManager.default.createFile(atPath: path, contents: script.data(using: .utf8),
                                       attributes: [.posixPermissions: 0o755])
        return path
    }

    func testNetworkTimeoutIsInjectableAndDefaultsTo120() async throws {
        let base = TestSupport.makeTempDir("net-seam")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/repo"
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: repoPath)

        XCTAssertEqual(RepoManager.defaultNetworkTimeout, 120, "the production budget is unchanged")
        XCTAssertEqual(repos.networkTimeout, 120)

        let fake = GitRunner(gitExecutable: makeSleepingGit(base, seconds: 10))
        let fakeRepos = RepoManager(runner: fake)
        fakeRepos.networkTimeout = 0.5

        do {
            _ = try await fakeRepos.runNetwork(["fetch"], cwd: repoPath)
            XCTFail("the sleeping git must time out")
        } catch let error as PullError {
            guard case .networkFailed(let detail) = error else {
                return XCTFail("expected networkFailed, got \(error)")
            }
            XCTAssertFalse(detail.isEmpty, "the classified message is readable copy")
            XCTAssertTrue(detail.contains("超时"), "the message names the timeout, got: \(detail)")
        }
    }

    /// The same fake git under a NORMAL budget proves the seam itself is not
    /// what cuts commands short: with a budget above the stall the call
    /// completes (the fake exits 0 after sleeping).
    func testSeamDoesNotAffectCallsThatFinishInBudget() async throws {
        let base = TestSupport.makeTempDir("net-seam-ok")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/repo"
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        let fake = GitRunner(gitExecutable: makeSleepingGit(base, seconds: 0))
        let repos = RepoManager(runner: fake)
        repos.networkTimeout = 5
        let result = try await repos.runNetwork(["fetch"], cwd: repoPath)
        XCTAssertEqual(result.exitCode, 0)
    }
}
