import XCTest
@testable import FileVaultCore

/// Connectivity probes (v4.2.30 item 1 + the dual-track failure contract):
/// the test button probes the address IN THE FIELD, a no-remote guard answers
/// in plain words, detail keeps the raw git output (the AuthMonitor contract)
/// and failureMessage carries the classified readable reason.
final class ConnectivityProbeContractTests: XCTestCase {

    /// Real repo + real local bare remote: the success path both probes take.
    func testSuccessPathsAgainstALocalBareRemote() async throws {
        let base = TestSupport.makeTempDir("conn-ok")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/repo"
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        TestSupport.write("seed", to: repoPath + "/seed.txt")
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: repoPath)

        let bare = base + "/remote.git"
        let initBare = try await repos.runner.run(["init", "--bare", bare])
        XCTAssertEqual(initBare.exitCode, 0)
        try await SyncManager(repoManager: repos).configureRemote(repoPath: repoPath, url: bare,
                                                                   autoPush: true)

        let sync = SyncManager(repoManager: repos)
        let stored = await sync.testConnectivity(repoPath: repoPath)
        XCTAssertTrue(stored.ok, stored.detail)
        XCTAssertEqual(stored.detail, "连接成功")
        XCTAssertNil(stored.failureMessage, "success has no failure line")

        // The settings probe tests the address in the field, unsaved.
        let probed = await sync.testRemote(url: bare, repoPath: repoPath)
        XCTAssertTrue(probed.ok)
        XCTAssertNil(probed.failureMessage)
    }

    func testNoRemoteAndEmptyTargetGuards() async throws {
        let base = TestSupport.makeTempDir("conn-guard")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/repo"
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: repoPath)
        let sync = SyncManager(repoManager: repos)

        let noRemote = await sync.testConnectivity(repoPath: repoPath)
        XCTAssertFalse(noRemote.ok)
        XCTAssertEqual(noRemote.detail, "未配置远程仓库")
        XCTAssertNil(noRemote.failureMessage)

        for empty in ["", "   "] {
            let guardResult = await sync.testRemote(url: empty, repoPath: repoPath)
            XCTAssertFalse(guardResult.ok, "an empty field is a guard, not a git call")
            XCTAssertEqual(guardResult.detail, "未配置远程仓库")
        }
    }

    /// Unreachable address: readable classified line for the UI, raw git text
    /// kept in detail — two different strings, neither empty.
    func testUnreachableTargetIsClassifiedWithRawDetailIntact() async throws {
        let base = TestSupport.makeTempDir("conn-raw")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/repo"
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: repoPath)
        let sync = SyncManager(repoManager: repos)

        let result = await sync.testRemote(url: base + "/no-such-remote.git", repoPath: repoPath)
        XCTAssertFalse(result.ok)
        XCTAssertFalse(result.detail.isEmpty, "raw git output is kept for AuthMonitor")
        XCTAssertNotNil(result.failureMessage, "the UI gets a classified readable line")
        XCTAssertNotEqual(result.failureMessage, result.detail,
                          "classified copy is not the raw dump")
    }

    /// Auth-shaped stderr: AuthClassifier must be able to match its English
    /// phrases against detail (the v4.2.30 failureResult contract).
    func testAuthShapedFailureKeepsRawEnglishForAuthMonitor() async throws {
        let base = TestSupport.makeTempDir("conn-auth")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let script = base + "/fake-git"
        let ctrl = base + "/auth"
        // GitRunner prepends --literal-pathspecs/-c flags, so match ANY argument
        // (the same for-over-args shape as the slow-git wrapper).
        let body = "#!/bin/sh\n" +
            "for a in \"$@\"; do\n" +
            "if [ \"$a\" = \"ls-remote\" ] && [ -f \"" + ctrl + "\" ]; then\n" +
            "printf 'ERROR: Permission to user/x.git denied to otheruser.\\n" +
            "fatal: Could not read from remote repository.\\n' >&2\n" +
            "exit 1\nfi\ndone\nexit 0\n"
        TestSupport.write(body, to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        TestSupport.write("on", to: ctrl)

        let repos = RepoManager(runner: GitRunner(gitExecutable: script, defaultTimeout: 10))
        let sync = SyncManager(repoManager: repos)
        let result = await sync.testRemote(url: "https://github.com/user/x.git", repoPath: "/tmp")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.detail.contains("Permission to"), result.detail)
        XCTAssertTrue(AuthClassifier.isAuthRelated(result.detail),
                      "AuthMonitor's phrase match works on the raw detail")
        XCTAssertNotNil(result.failureMessage)
    }

    /// Empty stderr is an unknown, not a blank failure line.
    func testEmptyStderrFallsBackToReadableUnknown() async throws {
        let base = TestSupport.makeTempDir("conn-unknown")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let script = base + "/fake-git"
        // GitRunner prepends --literal-pathspecs/-c flags, so match ANY argument
        // (the same for-over-args shape as the slow-git wrapper).
        let body = "#!/bin/sh\nfor a in \"$@\"; do\n" +
            "if [ \"$a\" = \"ls-remote\" ]; then exit 1; fi\ndone\nexit 0\n"
        TestSupport.write(body, to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let repos = RepoManager(runner: GitRunner(gitExecutable: script, defaultTimeout: 10))
        let sync = SyncManager(repoManager: repos)
        let result = await sync.testRemote(url: "https://example.com/x.git", repoPath: "/tmp")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.detail, "未知错误", result.detail)
        XCTAssertNotNil(result.failureMessage)
    }
}
