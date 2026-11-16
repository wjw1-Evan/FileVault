import XCTest
@testable import FileVaultCore

/// Regression tests for the v4.2.26 full audit (data safety + parsing).
final class AuditV426CoreTests: XCTestCase {
    // MARK: - Helpers

    private func makeRepo(_ name: String) throws -> (root: String, repo: RepoManager, git: GitRunner) {
        let root = TestSupport.makeTempDir(name)
        let runner = TestSupport.newRunner()
        let repos = RepoManager(runner: runner)
        return (root, repos, runner)
    }

    private func sha(_ runner: GitRunner, _ args: [String], cwd: String) throws -> String {
        try runner.runSync(args, cwd: cwd, timeout: 30).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Ignored files must never be silently overwritten

    /// Scenario: a file tracked in the target version is currently IGNORED and
    /// holds newer user content. `git reset --hard` overwrites it and the backup
    /// ref cannot recover content that was never committed.
    func testResetRepoRefusesToOverwriteIgnoredFile() async throws {
        let (root, repos, runner) = try makeRepo("v426-reset-ignored")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: repo)

        TestSupport.write("tracked v1", to: repo + "/secret.txt")
        _ = try await repos.commitAll(path: repo, message: "C1")
        let c1 = try await repos.resolveHead(path: repo)

        // Untrack it and ignore it, then put new user content on disk.
        _ = try runner.runSync(["rm", "--cached", "--", "secret.txt"], cwd: repo, timeout: 10)
        TestSupport.write("secret.txt\n", to: repo + "/.gitignore")
        _ = try await repos.commitAll(path: repo, message: "C2 ignore")
        TestSupport.write("USER NEW CONTENT", to: repo + "/secret.txt")

        do {
            try await repos.resetRepo(path: repo, to: c1)
            XCTFail("rollback must refuse to overwrite an ignored file with tracked content")
        } catch let error as HistoryError {
            guard case .rollbackWouldOverwriteIgnored(let files) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(files, ["secret.txt"])
        }
        XCTAssertEqual(try String(contentsOfFile: repo + "/secret.txt", encoding: .utf8),
                       "USER NEW CONTENT", "the user's ignored file must be untouched")
    }

    func testRestoreFileRefusesToOverwriteIgnoredFile() async throws {
        let (root, repos, runner) = try makeRepo("v426-restore-ignored")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: repo)

        TestSupport.write("tracked v1", to: repo + "/.env")
        _ = try await repos.commitAll(path: repo, message: "C1")
        let c1 = try await repos.resolveHead(path: repo)
        _ = try runner.runSync(["rm", "--cached", "--", ".env"], cwd: repo, timeout: 10)
        TestSupport.write(".env\n", to: repo + "/.gitignore")
        _ = try await repos.commitAll(path: repo, message: "C2 ignore")
        TestSupport.write("SECRET=NEW", to: repo + "/.env")

        do {
            _ = try await repos.restoreFile(path: repo, file: ".env", to: c1)
            XCTFail("restore must refuse to overwrite an ignored file")
        } catch let error as HistoryError {
            guard case .restoreWouldOverwriteIgnored(let file) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(file, ".env")
        }
        XCTAssertEqual(try String(contentsOfFile: repo + "/.env", encoding: .utf8), "SECRET=NEW")
    }

    /// Pathspec globbing: restoring "a[1].txt" used to also rewrite "a1.txt".
    func testRestoreFileUsesLiteralPathspec() async throws {
        let (root, repos, _) = try makeRepo("v426-literal")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: repo)

        TestSupport.write("one", to: repo + "/a[1].txt")
        TestSupport.write("one", to: repo + "/a1.txt")
        _ = try await repos.commitAll(path: repo, message: "C1")
        let c1 = try await repos.resolveHead(path: repo)
        TestSupport.write("two", to: repo + "/a[1].txt")
        TestSupport.write("two", to: repo + "/a1.txt")
        _ = try await repos.commitAll(path: repo, message: "C2")

        _ = try await repos.restoreFile(path: repo, file: "a[1].txt", to: c1)
        XCTAssertEqual(try String(contentsOfFile: repo + "/a[1].txt", encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOfFile: repo + "/a1.txt", encoding: .utf8), "two",
                       "the sibling file must not be touched by a pathspec glob")
    }

    // MARK: - History parsing

    func testChangedFilesKeepsNewlineFilename() async throws {
        let (root, repos, _) = try makeRepo("v426-changed-nl")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await repos.ensureRepo(at: repo)
        let name = "line\nbreak.txt"
        TestSupport.write("x", to: repo + "/" + name)
        _ = try await repos.commitAll(path: repo, message: "nl")
        let history = HistoryService(repoManager: repos)
        let head = try await repos.resolveHead(path: repo)
        let lines = try await history.changedFiles(repoPath: repo, hash: head)
        XCTAssertEqual(lines.count, 1, "one file, not a C-quoted pseudo line: \(lines)")
        XCTAssertTrue(lines[0].hasSuffix(name), "raw NUL-parsed path expected: \(lines[0])")
        XCTAssertFalse(lines[0].contains("\\" + "n"), "no escape sequences in the path")
    }

    // MARK: - First commit must respect the remote's file ceiling

    func testCreateRepoExcludesOversizeFileBeforeFirstCommit() async throws {
        let (root, repos, _) = try makeRepo("v426-first-commit")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        XCTAssertTrue(TestSupport.writeSparse(repo + "/huge.bin", bytes: 101 * 1024 * 1024))
        TestSupport.write("small", to: repo + "/note.md")

        _ = try await repos.ensureRepo(at: repo, remoteURL: "https://github.com/example/example.git")
        let tracked = try await repos.listFiles(path: repo)
        XCTAssertFalse(tracked.contains("huge.bin"),
                       "an oversize file must not enter the very first commit")
        XCTAssertTrue(tracked.contains("note.md"))
        XCTAssertEqual(repos.excludedLargeFiles(path: repo), ["huge.bin"])
    }

    // MARK: - Folder removal must forget runtime state

    func testRemoveRootClearsPauseSoReAddingResumesCommits() async throws {
        let base = TestSupport.makeTempDir("v426-pause-reset")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let vault = base + "/vault"
        try FileManager.default.createDirectory(atPath: vault, withIntermediateDirectories: true)
        TestSupport.write("seed", to: vault + "/a.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: vault)
        await service.setRootPaused(true, root: vault)
        XCTAssertTrue(service.pause.isPaused(root: vault))

        await service.removeRoot(path: vault)
        XCTAssertFalse(service.pause.isPaused(root: vault),
                       "removing a folder must not leave its pause flag behind")
        try await service.addRoot(path: vault)
        XCTAssertFalse(service.pause.isPaused(root: vault),
                       "re-adding the same folder must resume auto-commits")
        XCTAssertFalse(service.configStore.load().roots.first?.paused ?? true)
    }

    // MARK: - Diagnostics redaction

    func testSupportBundleRedactionHandlesEscapedJSONSlashes() {
        // JSONEncoder escapes "/" as "\/" by default; the masked() helper must
        // normalise that or the "redacted" report leaks /Users/<name>.
        let config = AppConfig(roots: [ManagedRoot(path: NSHomeDirectory() + "/SecretNotes")])
        let report = SupportBundle.report(appVersion: "4.2.26", config: config,
                                          gitDescription: "/usr/bin/git")
        XCTAssertFalse(report.contains("/Users/"), "no account path may survive redaction")
        XCTAssertTrue(report.contains("~"), "home must be collapsed to ~")
        XCTAssertEqual(SupportBundle.masked("\\/Users\\/someone\\/notes"), "~/notes",
                       "escaped JSON slashes must be unescaped before masking")
        XCTAssertEqual(SupportBundle.masked(NSHomeDirectory() + "/notes"), "~/notes")
        // Another account on the same Mac is masked too (login name hidden).
        XCTAssertEqual(SupportBundle.masked("/Users/alice2/x"), "~/x")
    }

    // MARK: - Config cache freshness (two instances)

    func testConfigStoreReloadsWhenAnotherWriterChangesTheFile() {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("v426-cfg-fresh"))
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let first = ConfigStore(directory: dir)
        var cfg = first.load()
        cfg.roots = [ManagedRoot(path: "/tmp/one")]
        XCTAssertTrue(first.save(cfg))
        XCTAssertEqual(first.load().roots.map(\.path), ["/tmp/one"])

        // Another FileVault instance adds a folder behind our back.
        let second = ConfigStore(directory: dir)
        var other = second.load()
        other.roots.append(ManagedRoot(path: "/tmp/two"))
        XCTAssertTrue(second.save(other))

        XCTAssertEqual(Set(first.load().roots.map(\.path)), ["/tmp/one", "/tmp/two"],
                       "a stale cache must not hide the other instance's change")
    }

    // MARK: - .gitignore read failures are not "empty file"

    func testGitignoreReadFailsOnNonUTF8InsteadOfReturningEmpty() throws {
        let base = TestSupport.makeTempDir("v426-gitignore")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repos = RepoManager(runner: TestSupport.newRunner())
        try FileManager.default.createDirectory(atPath: base + "/repo", withIntermediateDirectories: true)
        XCTAssertNoThrow(try repos.readGitignore(path: base + "/repo"))

        try Data([0xFF, 0xFE, 0x00]).write(to: URL(fileURLWithPath: base + "/repo/.gitignore"))
        XCTAssertThrowsError(try repos.readGitignore(path: base + "/repo")) { error in
            guard case RepoManager.GitignoreError.notUTF8 = error else {
                return XCTFail("expected notUTF8, got \(error)")
            }
        }
    }
}
