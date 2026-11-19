import XCTest
@testable import FileVaultCore

/// Regression tests for the v4.2.27 audit round (18 modules re-audited on top
/// of v4.2.26). Naming follows AuditV426*Tests.
final class AuditV427Tests: XCTestCase {
    // MARK: - Helpers

    private func makeRepo(_ name: String) -> (root: String, repo: RepoManager, git: GitRunner) {
        let root = TestSupport.makeTempDir(name)
        let runner = TestSupport.newRunner()
        let repos = RepoManager(runner: runner)
        return (root, repos, runner)
    }

    private func git(_ runner: GitRunner, _ args: [String], cwd: String) -> GitResult {
        (try? runner.runSync(args, cwd: cwd, timeout: 30))
            ?? GitResult(exitCode: -1, stdout: "", stderr: "spawn failed")
    }

    /// Whether the temp volume is case-insensitive (APFS default): a case probe
    /// written twice under different case resolves to ONE file.
    private func volumeIsCaseInsensitive(_ dir: String) -> Bool {
        let probe = dir + "/fv-case-probe"
        TestSupport.write("x", to: probe)
        TestSupport.write("x", to: dir + "/FV-CASE-PROBE")
        let same = FileManager.default.contentsEqual(atPath: probe, andPath: dir + "/FV-CASE-PROBE") &&
            (try? FileManager.default.removeItem(atPath: dir + "/FV-CASE-PROBE")) != nil
        try? FileManager.default.removeItem(atPath: probe)
        return same
    }

    // MARK: - P1: ignored-file guardrails (case variants + directory restore)

    /// Case variant: target tree has `notes.txt`, disk has ignored `Notes.txt`
    /// (same file on case-insensitive volumes). The exact-match guardrails let
    /// `reset --hard` destroy content that exists in no commit (v4.2.27).
    func testResetRepoRefusesIgnoredCaseVariant() async throws {
        let (root, repos, runner) = makeRepo("v427-case-variant")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: repo)

        TestSupport.write("tracked v1", to: repo + "/notes.txt")
        _ = try await repos.commitAll(path: repo, message: "C1")
        let c1 = try await repos.resolveHead(path: repo)
        _ = git(runner, ["rm", "--cached", "--", "notes.txt"], cwd: repo)
        // Delete the tracked name so the case variant can be a separate file on
        // case-sensitive volumes too; then ignore the OTHER case.
        try? FileManager.default.removeItem(atPath: repo + "/notes.txt")
        TestSupport.write("Notes.txt\n", to: repo + "/.gitignore")
        _ = try await repos.commitAll(path: repo, message: "C2 ignore")
        // Create the case-variant file (same disk file on case-insensitive APFS).
        TestSupport.write("PRECIOUS", to: repo + "/Notes.txt")

        guard volumeIsCaseInsensitive(repo) else {
            throw XCTSkip("case-sensitive volume: case-variant overwrite is impossible here")
        }

        do {
            try await repos.resetRepo(path: repo, to: c1)
            XCTFail("reset must refuse when an ignored case variant holds uncommitted content")
        } catch let error as HistoryError {
            guard case .rollbackWouldOverwriteIgnored = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOfFile: repo + "/Notes.txt", encoding: .utf8),
                       "PRECIOUS", "the ignored case variant must be untouched")
    }

    /// restoreDirectory's "folder exists at that version" branch had NO
    /// ignored-file guardrail: checkout rewrote an ignored .env-style file
    /// whose content is in no commit (v4.2.27).
    func testRestoreDirectoryRefusesOverwriteIgnoredFile() async throws {
        let (root, repos, runner) = makeRepo("v427-dir-ignored")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: repo)

        try FileManager.default.createDirectory(atPath: repo + "/d", withIntermediateDirectories: true)
        TestSupport.write("old", to: repo + "/d/f.txt")
        _ = try await repos.commitAll(path: repo, message: "C1")
        let c1 = try await repos.resolveHead(path: repo)
        // C2 deletes the tracked file (folder stays via this history).
        _ = git(runner, ["rm", "-q", "--", "d/f.txt"], cwd: repo)
        _ = try await repos.commitAll(path: repo, message: "C2 delete")
        // User recreates it as an IGNORED file with precious content.
        // (git rm removed the now-empty d/ directory from disk.)
        TestSupport.write("d/f.txt\n", to: repo + "/.gitignore")
        _ = try await repos.commitAll(path: repo, message: "C3 ignore")
        try FileManager.default.createDirectory(atPath: repo + "/d", withIntermediateDirectories: true)
        TestSupport.write("SECRET-NEW", to: repo + "/d/f.txt")

        let extras = HistoryService(repoManager: repos)
        do {
            _ = try await extras.restoreDirectory(repoPath: repo, directory: "d", to: c1)
            XCTFail("directory restore must refuse to overwrite the ignored file")
        } catch let error as HistoryError {
            guard case .rollbackWouldOverwriteIgnored(let files) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(files, ["d/f.txt"])
        }
        XCTAssertEqual(try String(contentsOfFile: repo + "/d/f.txt", encoding: .utf8), "SECRET-NEW")
    }

    /// restoreDirectory was the one restore entry that did not verify the hash:
    /// a well-formed but nonexistent hash fell into the "folder absent" branch
    /// and DELETED the folder (v4.2.27).
    func testRestoreDirectoryRejectsUnknownHash() async throws {
        let (root, repos, _) = makeRepo("v427-dir-hash")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: repo)
        try FileManager.default.createDirectory(atPath: repo + "/d", withIntermediateDirectories: true)
        TestSupport.write("x", to: repo + "/d/f.txt")
        _ = try await repos.commitAll(path: repo, message: "C1")

        let extras = HistoryService(repoManager: repos)
        do {
            _ = try await extras.restoreDirectory(repoPath: repo, directory: "d", to: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
            XCTFail("unknown hash must be rejected")
        } catch let error as HistoryError {
            guard case .commitNotFound = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/d/f.txt"),
                      "a rejected restore must not delete the folder")
    }

    /// A rename used to hide the old path from the 已删除 scan (R100 was
    /// filtered out by --diff-filter=D), so renamed-away files could not be
    /// recovered (v4.2.27).
    func testRenamedAwayFileAppearsInDeletedScan() async throws {
        let (root, repos, runner) = makeRepo("v427-rename-scan")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("content", to: repo + "/a.txt")
        _ = try await repos.commitAll(path: repo, message: "C1")
        _ = git(runner, ["mv", "a.txt", "b.txt"], cwd: repo)
        _ = try await repos.commitAll(path: repo, message: "C2 rename")

        let recovery = RecoveryService(repoManager: repos, history: HistoryService(repoManager: repos))
        let snap = try await recovery.snapshot(repoPath: repo)
        XCTAssertTrue(snap.deleted.contains(where: { $0.path == "a.txt" }),
                      "rename must surface the old path in the deleted scan; got \(snap.deleted.map(\.path))")
    }

    // MARK: - P2: hooks, nested repos, oversized tracked files, credentials

    /// Auto-commit used to run user hooks: a failing pre-commit vetoed the
    /// background snapshot commit forever (auto-commit cannot be disabled by
    /// design) (v4.2.27).
    func testAutoCommitSkipsUserHooks() async throws {
        let (root, repos, _) = makeRepo("v427-no-verify")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: repo)

        let hook = repo + "/.git/hooks/pre-commit"
        try FileManager.default.createDirectory(atPath: repo + "/.git/hooks", withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 1\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)

        TestSupport.write("data", to: repo + "/f.txt")
        let hash = try await repos.commitAll(path: repo, message: "C1")
        XCTAssertFalse(hash.isEmpty, "commitAll must succeed despite a failing pre-commit hook")
    }

    /// A nested repo with NO commits cannot be staged as a gitlink: `add -A`
    /// exited 128 and auto-commit stopped for the whole outer repo (v4.2.27).
    func testUnbornNestedRepoIsExcludedAndCommitProceeds() async throws {
        let (root, repos, runner) = makeRepo("v427-nested-unborn")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: repo)

        // Nested repo: git init but no commits.
        try FileManager.default.createDirectory(atPath: repo + "/sub", withIntermediateDirectories: true)
        _ = git(runner, ["init", "-q", "-b", "main", repo + "/sub"], cwd: repo)
        TestSupport.write("data", to: repo + "/f.txt")

        var notified: (String, String)?
        repos.onNestedRepoExcluded = { path, dir in notified = (path, dir) }
        let hash = try await repos.commitAll(path: repo, message: "C1")
        XCTAssertFalse(hash.isEmpty, "outer auto-commit must proceed once the nested repo is excluded")
        XCTAssertEqual(notified?.1, "sub/", "the user must be told the nested repo was skipped")
        // The rule is recorded and the file list stays clean afterwards.
        let exclude = try String(contentsOfFile: repo + "/.git/info/exclude", encoding: .utf8)
        XCTAssertTrue(exclude.contains(RepoManager.nestedRepoMarkerComment))
        let tracked = git(runner, ["ls-files", "-z"], cwd: repo).stdout
        XCTAssertTrue(tracked.contains("f.txt"))
        XCTAssertFalse(tracked.contains("sub/"))
    }

    /// A TRACKED file that grew past the remote ceiling used to be committed —
    /// the blob could never be pushed again. It must be unstaged instead
    /// (working tree untouched) (v4.2.27).
    func testOversizedTrackedFileIsUnstagedNotCommitted() async throws {
        let (root, repos, runner) = makeRepo("v427-oversized-tracked")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: repo)
        // Bind a github.com remote directly (no network: just config).
        _ = git(runner, ["remote", "add", "origin", "https://github.com/example/oversize.git"], cwd: repo)

        TestSupport.write("small", to: repo + "/small.txt")
        _ = try await repos.commitAll(path: repo, message: "C1")
        // The tracked file grows past the 100 MiB ceiling.
        XCTAssertTrue(TestSupport.writeSparse(repo + "/big.bin", bytes: 101 * 1024 * 1024))
        _ = try await repos.commitAll(path: repo, message: "C2 add big")

        let tree = git(runner, ["ls-tree", "-r", "--name-only", "HEAD"], cwd: repo).stdout
        XCTAssertFalse(tree.contains("big.bin"), "oversized blob must not enter history")
        // The file stays on disk untouched and is recorded for the UI warning.
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/big.bin"))
        let tracked = git(runner, ["ls-files", "-z"], cwd: repo).stdout
        XCTAssertFalse(tracked.contains("big.bin"), "an oversized NEW file must not be tracked")
        XCTAssertEqual(repos.excludedLargeFiles(path: repo), ["big.bin"])
        // Clean up the sparse file promptly.
        try? FileManager.default.removeItem(atPath: repo + "/big.bin")
    }

    /// With `echo` askpass, credential fill returned the PROMPT TEXT as
    /// username/password, so the "请填令牌" prompt never showed (v4.2.27).
    func testCredentialFillReturnsNilWithoutStoredCredential() async throws {
        let runner = TestSupport.newRunner()
        let filled = await CredentialStore.fill(runner: runner, url: "https://fill-v427.invalid/x")
        XCTAssertNil(filled, "no stored credential must yield nil, not prompt-echo garbage")
    }

    // MARK: - P3: locator, remote selection, config perms, guard behaviors

    /// Lexicographic sorting picked "2.9.0" over "2.10.0" forever (v4.2.27).
    func testFindInstalledGitPrefersHigherSemver() throws {
        let root = TestSupport.makeTempDir("v427-locator")
        defer { try? FileManager.default.removeItem(atPath: root) }
        for (dir, ver) in [("2.9.0-arm64", "2.9.0"), ("2.10.0-arm64", "2.10.0")] {
            try FileManager.default.createDirectory(atPath: root + "/\(dir)/bin", withIntermediateDirectories: true)
            let exe = root + "/\(dir)/bin/git"
            try "#!/bin/sh\necho \"git version \\(ver)\"\n".write(toFile: exe, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe)
        }
        let found = GitBinaryProvisioner.findInstalledGit(in: URL(fileURLWithPath: root))
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let expected = URL(fileURLWithPath: root + "/2.10.0-arm64/bin/git").resolvingSymlinksInPath().path
        XCTAssertEqual(found, expected)
    }

    /// App-side sync stop must hide the remote from probing (v4.2.27).
    func testDefaultRemoteNameRespectsDisabledFlag() async throws {
        let (root, repos, runner) = makeRepo("v427-remote-name")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: repo)
        _ = git(runner, ["remote", "add", "origin", "https://github.com/example/x.git"], cwd: repo)

        let before = await repos.defaultRemoteName(path: repo)
        XCTAssertEqual(before, "origin")
        _ = git(runner, ["config", "--local", "filevault.remotedisabled", "true"], cwd: repo)
        let after = await repos.defaultRemoteName(path: repo)
        XCTAssertNil(after, "a disabled remote must not be probed or reported")
    }

    /// config.backup.json held every folder path too but stayed 0644 (v4.2.27).
    func testConfigBackupGetsTightPermissions() throws {
        let base = TestSupport.makeTempDir("v427-backup-perm")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let dir = URL(fileURLWithPath: base).appendingPathComponent("config")
        let store = ConfigStore(directory: dir)
        var cfg = AppConfig()
        cfg.roots = [ManagedRoot(path: base)]
        XCTAssertTrue(store.save(cfg))
        XCTAssertTrue(store.save(cfg)) // second save writes the backup
        let backup = dir.appendingPathComponent("config.backup.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: backup.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(perms, 0o600, "backup must be owner-only")
    }

    /// The multi-file unstage step needs an existence-filtered marker reader;
    /// deleted files also kept the "N 个大文件未同步" warning alive forever
    /// (v4.2.27).
    func testExcludedLargeFilesFiltersDeletedFiles() async throws {
        let (root, repos, runner) = makeRepo("v427-stale-marker")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("x", to: repo + "/gone.bin")
        let rule = RepoManager.escapedExcludeRule("gone.bin")
        let exclude = repo + "/.git/info/exclude"
        let current = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
        try (current + "\n# filevault-excluded-large-file\n" + rule + "\n")
            .write(toFile: exclude, atomically: true, encoding: .utf8)
        XCTAssertEqual(repos.excludedLargeFiles(path: repo), ["gone.bin"])
        try? FileManager.default.removeItem(atPath: repo + "/gone.bin")
        XCTAssertTrue(repos.excludedLargeFiles(path: repo).isEmpty,
                      "a deleted file must not keep the unsynced warning alive")
    }

    /// Debounce timers for a removed root must not fire afterwards (v4.2.27).
    func testDebouncerCancelKeyPreventsLateFire() async {
        let expectation = self.expectation(description: "other key fires")
        var firedKeys: [String] = []
        let lock = NSLock()
        let d = Debouncer(quietInterval: 0.2, maxWait: 1.0, onFired: { key in
            lock.lock(); firedKeys.append(key); lock.unlock()
            if key == "other" { expectation.fulfill() }
        })
        d.touch("removed")
        d.cancel(key: "removed")
        d.touch("other")
        await fulfillment(of: [expectation], timeout: 5)
        try? await Task.sleep(nanoseconds: 400_000_000)
        lock.lock()
        XCTAssertFalse(firedKeys.contains("removed"), "cancelled key must not fire")
        XCTAssertTrue(firedKeys.contains("other"))
        lock.unlock()
    }

    // MARK: - Update pipeline

    /// Old markers (pre-4.2.27, no `version` key) must still decode (v4.2.27).
    func testUpdateMarkerBackwardCompatibleDecoding() throws {
        let legacy = """
        {"previousVersion":"4.2.26","newVersion":"4.2.27","attempts":2,
         "startedAt":"2026-11-17T00:00:00Z"}
        """
        let config = TestSupport.makeTempDir("v427-marker")
        defer { try? FileManager.default.removeItem(atPath: config) }
        try legacy.write(toFile: config + "/update-attempt.json", atomically: true, encoding: .utf8)
        let marker = UpdateGuard.read(configDirectory: URL(fileURLWithPath: config))
        XCTAssertNotNil(marker, "a legacy marker must not fail to decode")
        XCTAssertEqual(marker?.newVersion, "4.2.27")
        XCTAssertEqual(marker?.attempts, 2)
    }

    /// Exact string equality silently disabled rollback when the zip's bundled
    /// version differed from the tag (v4.2.27): semantic equality decides.
    func testShouldRollbackUsesSemanticVersionEquality() {
        let marker = UpdateGuard.Marker(previousVersion: "4.2.25", newVersion: "4.2.27", attempts: 3)
        XCTAssertTrue(UpdateGuard.shouldRollback(marker, currentVersion: "4.2.27"))
        // 4-part / padded spellings of the SAME version must still match.
        XCTAssertTrue(UpdateGuard.shouldRollback(marker, currentVersion: "4.2.27.0"))
        XCTAssertFalse(UpdateGuard.shouldRollback(marker, currentVersion: "4.2.26"),
                       "a different (manually reinstalled) version must not roll back")
    }

    /// A stale re-uploaded zip used to win first-match and pass its own digest
    /// (v4.2.27): version-matched unique selection + ambiguous refusal.
    func testUpdateAssetSelection() throws {
        func payload(_ assets: [[String: Any]], tag: String) throws -> ReleaseInfo? {
            let obj: [String: Any] = ["tag_name": tag,
                                      "assets": assets]
            let data = try JSONSerialization.data(withJSONObject: obj)
            return try HttpReleaseFetcher.parseRelease(data)
        }
        func asset(_ name: String, id: Int) -> [String: Any] {
            ["name": name, "id": NSNumber(value: id),
             "digest": "sha256:" + String(repeating: "a", count: 64),
             "size": NSNumber(value: 1), "browser_download_url": "https://example/\(name)"]
        }
        // Stale + new: the version match wins.
        let info = try payload([asset("FileVault-4.2.26.zip", id: 1),
                                asset("FileVault-4.2.27.zip", id: 2)], tag: "v4.2.27")
        XCTAssertEqual(info?.assetName, "FileVault-4.2.27.zip")
        // Two matching → ambiguous → refuse.
        XCTAssertThrowsError(try payload([asset("FileVault-4.2.27.zip", id: 1),
                                          asset("FileVault-4.2.27 (1).zip", id: 2)], tag: "v4.2.27"))
        // Single zip without a version in the name (legacy naming) → accepted.
        let legacy = try payload([asset("FileVault.zip", id: 1)], tag: "v4.2.27")
        XCTAssertEqual(legacy?.assetName, "FileVault.zip")
    }

    // MARK: - Readability: failed reads are errors, not empty states

    /// log() used to swallow non-zero exits (v4.2.27): a broken repo must
    /// throw, not render "还没有提交历史".
    func testLogThrowsWhenRepoUnreadable() async throws {
        if geteuid() == 0 {
            throw XCTSkip("filesystem ignores file permissions (running as root?)")
        }
        let (root, repos, _) = makeRepo("v427-log-throw")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: repo)
        TestSupport.write("x", to: repo + "/f.txt")
        _ = try await repos.commitAll(path: repo, message: "C1")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: repo + "/.git")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo + "/.git")
        }
        do {
            _ = try await repos.log(path: repo)
            XCTFail("an unreadable repo must throw, not report an empty history")
        } catch is GitCommandError {
            // expected
        }
    }

    /// Timeline pagination (加载更多, v4.2.27 design round): skip/offset must
    /// return the NEXT page without overlap.
    func testLogSkipReturnsNextPage() async throws {
        let (root, repos, _) = makeRepo("v427-log-skip")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: repo)
        for i in 0..<12 {
            TestSupport.write("v\(i)", to: repo + "/f.txt")
            _ = try await repos.commitAll(path: repo, message: "C\(i)")
        }
        let first = try await repos.log(path: repo, max: 5)
        let second = try await repos.log(path: repo, max: 5, skip: 5)
        XCTAssertEqual(first.count, 5)
        XCTAssertEqual(second.count, 5)
        let firstHashes = Set(first.map(\.hash))
        for c in second where firstHashes.contains(c.hash) {
            XCTFail("page 2 must not overlap page 1: \(c.shortHash)")
        }
        // Newest-first ordering must be preserved across pages.
        XCTAssertEqual(first.first?.subject, "C11")
        XCTAssertEqual(second.first?.subject, "C6")
        let tail = try await repos.log(path: repo, max: 5, skip: 10)
        XCTAssertEqual(tail.count, 3, "short final page signals the end (12 commits + initial)")
    }

    /// The health line must distinguish "0 commits" from "cannot read" (v4.2.27).
    /// v4.2.30: `readError` is readable copy now — the raw exit code lives in
    /// `readErrorExitCode` (diagnostics only), never in the rendered line.
    func testRepoHealthSummaryShowsReadError() {
        let broken = RepoHealth(commitCount: 0, sizeBytes: 0, lastCommitDate: nil,
                                readError: "仓库暂时读不到（可能正忙或磁盘不可用），稍后重试。",
                                readErrorExitCode: 128)
        XCTAssertTrue(broken.summary.contains("读取失败"), broken.summary)
        XCTAssertTrue(broken.summary.contains("仓库暂时读不到"), broken.summary)
        XCTAssertFalse(broken.summary.contains("128"), "exit codes must not be glued into the health line: \(broken.summary)")
        XCTAssertEqual(broken.readErrorExitCode, 128, "diagnostics keep the exit code")
        let empty = RepoHealth(commitCount: 0, sizeBytes: 0, lastCommitDate: nil)
        XCTAssertFalse(empty.summary.contains("读取失败"))
        XCTAssertEqual(empty.commitCount, 0)
    }
}
