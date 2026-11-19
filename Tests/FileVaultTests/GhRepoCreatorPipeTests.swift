import XCTest
@testable import FileVaultCore

/// v4.2.32 watchlist item 2: runGh used to wait for exit BEFORE reading the
/// pipes, so a gh writing more than the 64 KB pipe buffer blocked forever
/// and the whole call died on the timeout. The concurrent-read shape must
/// survive arbitrarily large output, and the timeout must be injectable.
final class GhRepoCreatorPipeTests: XCTestCase {

    /// A fake gh: for `repo create` it emits a big payload then succeeds;
    /// for `api user` it answers a login. >64 KB on BOTH streams.
    private func makeBigOutputGh(_ base: String, bytes: Int) -> String {
        let path = base + "/big-gh.sh"
        let script = """
        #!/bin/bash
        for a in "$@"; do
          case "$a" in
            create)
              python3 -c "import sys; sys.stdout.write('x' * \(bytes)); sys.stderr.write('y' * \(bytes))"
              exit 0;;
          esac
        done
        for a in "$@"; do
          case "$a" in
            user) echo testuser; exit 0;;
          esac
        done
        exit 0
        """
        FileManager.default.createFile(atPath: path, contents: script.data(using: .utf8),
                                       attributes: [.posixPermissions: 0o755])
        return path
    }

    private func makeSleepingGh(_ base: String, seconds: Int) -> String {
        let path = base + "/sleep-gh.sh"
        let script = """
        #!/bin/bash
        for a in "$@"; do
          case "$a" in
            create) sleep \(seconds); exit 0;;
          esac
        done
        echo testuser; exit 0
        """
        FileManager.default.createFile(atPath: path, contents: script.data(using: .utf8),
                                       attributes: [.posixPermissions: 0o755])
        return path
    }

    /// 200 KB on stdout AND stderr: with the old wait-then-read shape this
    /// hung the full 60 s budget and failed; it must now complete fast.
    func testLargeGhOutputIsCapturedWithoutDeadlock() async throws {
        let base = TestSupport.makeTempDir("gh-pipe")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let gh = makeBigOutputGh(base, bytes: 200 * 1024)

        let started = Date()
        let url = try await GhRepoCreator().createPrivate(name: "big-output-repo", ghPath: gh,
                                                          createTimeout: 20)
        XCTAssertEqual(url, "https://github.com/testuser/big-output-repo.git")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "concurrent readers keep a >64 KB gh call from deadlocking")
    }

    /// The timeout branch (v2.6.6) with an injectable budget: a stalled
    /// repo-create surfaces the readable timeout error instead of hanging.
    func testStalledCreateTimesOutWithReadableError() async throws {
        let base = TestSupport.makeTempDir("gh-timeout")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let gh = makeSleepingGh(base, seconds: 30)

        do {
            _ = try await GhRepoCreator().createPrivate(name: "stalled-repo", ghPath: gh,
                                                        createTimeout: 0.5)
            XCTFail("a stalled gh must time out")
        } catch let error as GitCommandError {
            XCTAssertEqual(error.exitCode, -9, "the timeout kill keeps its contract with callers")
            XCTAssertTrue(error.stderr.contains("超时"), "readable timeout copy, got: \(error.stderr)")
        }
    }

}
