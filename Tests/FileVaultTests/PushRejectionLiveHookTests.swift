import XCTest
@testable import FileVaultCore

/// v4.2.32 watchlist item 4 — VERDICT: both paths classify correctly, and
/// this file makes the evidence permanent.
///
/// (a) LIVE experiment: GitHub enforces branch protection through a
///     pre-receive hook in the BARE remote — a local hook reproduces the
///     real wording end-to-end, and the classifier must answer with the
///     branch-protection guidance.
/// (b) Archived repos refuse at the HTTP layer with the wording captured
///     verbatim from a real GitHub push (Wikimedia Phabricator T388647):
///     "remote: This repository was archived so it is read-only." — it
///     carries NO "pre-receive hook declined" / "remote rejected" line, so
///     the protection block CANNOT shadow it, and "read-only" routes it to
///     the 只读/已归档 guidance. No code change was needed.
final class PushRejectionLiveHookTests: XCTestCase {

    /// A bare remote whose pre-receive hook declines with GitHub's exact
    /// protection phrasing (hook stderr arrives as "remote: ..." lines).
    private func makeProtectedBare(_ base: String) throws -> String {
        let bare = base + "/protected.git"
        var ok = ShellRunner.run("/usr/bin/git", ["init", "--bare", bare])
        XCTAssertTrue(ok, "bare remote must initialise")
        let hook = bare + "/hooks/pre-receive"
        let script = """
        #!/bin/sh
        echo "error: GH006: Protected branch update failed for refs/heads/main." >&2
        echo "Cannot force-push to a protected branch." >&2
        exit 1
        """
        FileManager.default.createFile(atPath: hook, contents: script.data(using: .utf8),
                                       attributes: [.posixPermissions: 0o755])
        return bare
    }

    /// Live end-to-end: real git, real hook, real stderr → the classifier
    /// must produce the branch-protection guidance (NOT the read-only one).
    func testLivePreReceiveHookRejectionClassifiesAsProtection() async throws {
        let base = TestSupport.makeTempDir("hook-live")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/repo"
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: repoPath)
        TestSupport.write("content", to: repoPath + "/note.md")
        _ = try await repos.commitAll(path: repoPath)

        let bare = try makeProtectedBare(base)
        let sync = SyncManager(repoManager: repos)
        // autoPush: false — configure the remote WITHOUT firing a push; the
        // direct pushOnce below owns the failure we want to classify.
        try await sync.configureRemote(repoPath: repoPath, url: bare, autoPush: false)

        do {
            try await sync.pushOnce(repoPath: repoPath)
            XCTFail("the hook must reject the push")
        } catch {
            let message = try XCTUnwrap(SyncManager.deterministicPushRejection(error),
                                        "a hook refusal is deterministic, raw error: \(error)")
            XCTAssertTrue(message.contains("分支保护"),
                          "the hook rejection must explain branch protection, got: \(message)")
            XCTAssertFalse(message.contains("只读"),
                           "it must not be misrouted to the read-only guidance")
        }
    }

    /// Verbatim stderr of a real push to an ARCHIVED GitHub repository
    /// (Wikimedia Phabricator T388647). It must land in the read-only bucket.
    func testRealArchivedRepositoryWordingClassifiesAsReadOnly() throws {
        let archivedStderr = """
        remote: This repository was archived so it is read-only.
        fatal: unable to access 'https://github.com/wikimedia/ores/': The requested URL returned error: 403
        """
        let message = SyncManager.deterministicPushRejection(
            GitCommandError(command: "push origin", exitCode: 128, stderr: archivedStderr))
        let text = try XCTUnwrap(message)
        XCTAssertTrue(text.contains("只读") || text.contains("归档"),
                      "the archived wording must reach the read-only guidance, got: \(text)")
        XCTAssertFalse(text.contains("分支保护"),
                       "an HTTP-level refusal never carries the hook phrases; protection must not shadow it")
    }
}

/// Tiny synchronous shell helper for the one-off bare-init in these tests.
private enum ShellRunner {
    static func run(_ executable: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }
}
