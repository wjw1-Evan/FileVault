import XCTest
@testable import FileVaultCore

/// Table-driven porcelain XY parsing (regression for the " D" deletion bug).
final class PorcelainParsingTests: XCTestCase {
    func testChangeFromXY() {
        let cases: [(String, StatusEntry.Change)] = [
            ("??", .added), ("A ", .added), ("AM", .modified),
            ("M ", .modified), (" M", .modified), ("T ", .typeChanged),
            ("D ", .deleted), (" D", .deleted), ("RM", .renamed),
            ("R ", .renamed), ("UU", .modified), ("AA", .added),
        ]
        for (xy, expected) in cases {
            XCTAssertEqual(RepoManager.change(fromXY: xy), expected, "XY=\(xy)")
        }
    }
}

/// Commit message builder edges (FR-05).
final class CommitMessageTests: XCTestCase {
    private func entry(_ c: StatusEntry.Change, _ name: String) -> StatusEntry {
        StatusEntry(change: c, path: name)
    }

    func testCapsFileListAtFive() {
        let entries = (1...8).map { entry(.added, "f\($0).md") }
        let msg = RepoManager.buildCommitMessage(entries: entries, additions: 10, deletions: 0)
        XCTAssertTrue(msg.hasPrefix("auto: 8 处变更 (+10 -0)"))
        XCTAssertEqual(msg.components(separatedBy: "、").count, 5, "should list at most 5 names")
        XCTAssertFalse(msg.contains("f8.md"))
    }

    func testFallbackWithoutGroups() {
        let msg = RepoManager.buildCommitMessage(entries: [], additions: 3, deletions: 4)
        XCTAssertEqual(msg, "auto: 0 处变更 (+3 -4)")
    }

    func testMixedGroups() {
        let entries = [entry(.added, "new.md"), entry(.deleted, "old.log"), entry(.modified, "edit.md")]
        let msg = RepoManager.buildCommitMessage(entries: entries, additions: 5, deletions: 2)
        XCTAssertTrue(msg.contains("新增 new.md"))
        XCTAssertTrue(msg.contains("修改 edit.md"))
        XCTAssertTrue(msg.contains("删除 old.log"))
    }

    /// v4.0.1: a 5-second burst of edits must keep the subject bounded — at most
    /// five names IN TOTAL, remaining groups summarised by count.
    func testMixedGroupsNeverExceedFiveNames() {
        let entries = (1...5).map { entry(.added, "add" + String($0) + ".md") }
            + (1...4).map { entry(.modified, "mod" + String($0) + ".md") }
            + (1...2).map { entry(.deleted, "del" + String($0) + ".md") }
        let msg = RepoManager.buildCommitMessage(entries: entries, additions: 9, deletions: 3)
        XCTAssertTrue(msg.hasPrefix("auto: 11 处变更 (+9 -3)"), msg)
        XCTAssertEqual(msg.components(separatedBy: "、").count, 5, "exactly five names: \(msg)")
        XCTAssertTrue(msg.contains("修改 4 个文件"), msg)
        XCTAssertTrue(msg.contains("删除 2 个文件"), msg)
        XCTAssertFalse(msg.contains("mod1.md"), msg)
    }

    /// When the first group alone exceeds the budget, keep its total visible.
    func testOversizedGroupCarriesTotalCount() {
        let entries = (1...9).map { entry(.added, "f" + String($0) + ".md") }
        let msg = RepoManager.buildCommitMessage(entries: entries, additions: 9, deletions: 0)
        XCTAssertTrue(msg.contains("等 9 个文件"), msg)
        XCTAssertEqual(msg.components(separatedBy: "、").count, 5, msg)
    }

    /// Same basename in two folders must be distinguishable in the title.
    func testDuplicateBasenamesFallBackToRelativePaths() {
        let entries = [
            StatusEntry(change: .modified, path: "笔记/a.md"),
            StatusEntry(change: .modified, path: "写作/a.md"),
        ]
        let msg = RepoManager.buildCommitMessage(entries: entries, additions: 2, deletions: 2)
        XCTAssertTrue(msg.contains("笔记/a.md"), msg)
        XCTAssertTrue(msg.contains("写作/a.md"), msg)
    }
}

/// GitRunner timeout with a fake git that sleeps (real timeout verification).
final class GitTimeoutTests: XCTestCase {
    func testTimeoutActuallyFires() async {
        let dir = TestSupport.makeTempDir("fakegit")
        let script = dir + "/git"
        let body = "#!/bin/sh\nsleep 10\n"
        try? body.write(toFile: script, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let runner = GitRunner(gitExecutable: script, defaultTimeout: 0.5)
        do {
            _ = try await runner.run(["anything"], cwd: dir)
            XCTFail("should have timed out")
        } catch let e as GitCommandError {
            XCTAssertEqual(e.exitCode, -9)
            XCTAssertTrue(e.stderr.contains("timed out"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        try? FileManager.default.removeItem(atPath: dir)
    }
}

/// ConfigStore robustness: corrupted JSON must not crash and resets to empty.
final class ConfigRecoveryTests: XCTestCase {
    func testCorruptedConfigRecovers() {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("cfgbad"))
        try? "not-json{{{".write(toFile: dir.appendingPathComponent("config.json").path, atomically: true, encoding: .utf8)
        let store = ConfigStore(directory: dir)
        var cfg = store.load()
        XCTAssertEqual(cfg.roots.count, 0, "corrupt config degrades to empty")
        // And saving afterwards still works.
        cfg.roots.append(ManagedRoot(path: "/tmp/x"))
        store.save(cfg)
        XCTAssertEqual(ConfigStore(directory: dir).load().roots.count, 1)
        try? FileManager.default.removeItem(atPath: dir.path)
    }
}


/// v1.3.0 complete settings: general preferences persistence + runtime apply.
final class GeneralSettingsTests: XCTestCase {
    func testRoundtripAndBackwardCompat() {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("genset"))
        // 1. Old config WITHOUT a general key must decode with defaults.
        let legacy = Data(#"{"roots": [{"path": "/tmp/a"}]}"#.utf8)
        try? legacy.write(to: dir.appendingPathComponent("config.json"))
        let store1 = ConfigStore(directory: dir)
        let loaded = store1.load()
        XCTAssertEqual(loaded.general, .default, "missing general key decodes to defaults")
        // CRITICAL: legacy roots must SURVIVE the decode (v1.3.0 root-loss bug).
        XCTAssertEqual(loaded.roots.count, 1, "legacy roots must not be silently dropped")
        XCTAssertEqual(loaded.roots.first?.path, "/tmp/a")
        // 1b. Configs from <=v3.1.2 still carry the removed local threshold key;
        // it must be ignored without dropping the rest (v3.1.3).
        let oldKey = Data(#"{"roots": [], "general": {"largeFileThresholdMB": 200, "debounceSeconds": 7}}"#.utf8)
        try? oldKey.write(to: dir.appendingPathComponent("config.json"))
        let migrated = ConfigStore(directory: dir).load()
        XCTAssertEqual(migrated.general.debounceSeconds, 7, "other general values survive the removed key")
        XCTAssertEqual(migrated.general, GeneralSettings(debounceSeconds: 7))
        // 2. Save -> load roundtrip.
        var cfg = loaded
        cfg.general.notificationsEnabled = false
        cfg.general.debounceSeconds = 10
        store1.save(cfg)
        cfg.general.launchAtLoginRequested = true
        store1.save(cfg)
        let again = ConfigStore(directory: dir).load()
        XCTAssertFalse(again.general.notificationsEnabled)
        XCTAssertEqual(again.general.debounceSeconds, 10)
        XCTAssertTrue(again.general.launchAtLoginRequested, "login intent persists")
        try? FileManager.default.removeItem(atPath: dir.path)
    }

    /// Debouncer quiet window must follow runtime changes.
    func testDebouncerDynamicInterval() {
        let exp = expectation(description: "fires after changed interval")
        let d = Debouncer(quietInterval: 30, maxWait: 60) { _ in exp.fulfill() }
        d.setQuietInterval(0.2)
        XCTAssertEqual(d.currentQuietInterval, 0.2)
        d.touch("dyn")
        wait(for: [exp], timeout: 2)
        d.cancelAll()
    }

    func testServiceApplyGeneral() async throws {
        let root = TestSupport.makeTempDir("svcgen")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: root + "/cfg"))
        try await service.start()
        service.updateGeneral { $0.debounceSeconds = 30 }
        XCTAssertEqual(service.debouncer?.currentQuietInterval, 30)
        let persisted = service.configStore.load().general
        XCTAssertEqual(persisted.debounceSeconds, 30)
        try? FileManager.default.removeItem(atPath: root)
    }
}

/// ff-only pull (multi-machine sync entry).
final class PullTests: XCTestCase {
    var root: String!
    var repos: RepoManager!

    override func setUp() {
        root = TestSupport.makeTempDir("pull")
        try? FileManager.default.createDirectory(atPath: root + "/repo", withIntermediateDirectories: true)
        TestSupport.write("seed", to: root + "/repo/s.md")
        repos = RepoManager(runner: TestSupport.newRunner())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root!)
    }

    func testPullFailsGracefullyWithoutRemote() async throws {
        _ = try await repos.ensureRepo(at: root + "/repo")
        do {
            _ = try await repos.pull(path: root + "/repo")
            XCTFail("pull without remote should throw")
        } catch let error as PullError {
            // v4.1.1: a classified, readable error instead of a bare exit code.
            XCTAssertEqual(error, .noRemote)
        }
    }

    func testPullAlreadyUpToDate() async throws {
        _ = try await repos.ensureRepo(at: root + "/repo")
        let remote = root + "/r.git"
        _ = try await repos.runner.run(["init", "--bare", remote])
        try await repos.setRemote(path: root + "/repo", url: remote)
        TestSupport.write("v1", to: root + "/repo/s.md")
        _ = try await repos.commitAll(path: root + "/repo")
        try await repos.runner.run(["push", "-u", "origin", "HEAD"], cwd: root + "/repo")
        let result = try await repos.pull(path: root + "/repo")
        XCTAssertEqual(result.pulledCommits, 0, "ff-only pull on an up-to-date repo brings no new commits")
        XCTAssertEqual(result.headBefore, result.headAfter)
    }
}


/// FR-01 auto-install closure (v1.4.0).
final class AutoInstallTests: XCTestCase {
    func testStartWithAutoInstall() async throws {
        final class InstallThenFoundLocator: GitLocator {
            var installed = false
            func locate() -> String? { installed ? "/usr/bin/git" : nil }
        }
        final class FakeInstaller: GitInstalling {
            let locator: InstallThenFoundLocator
            var calls = 0
            init(_ l: InstallThenFoundLocator) { self.locator = l }
            func install() async throws -> GitDetection {
                calls += 1
                locator.installed = true
                return GitDetection(gitPath: "/usr/bin/git", version: "test", source: .system)
            }
        }
        let locator = InstallThenFoundLocator()
        let installer = FakeInstaller(locator)
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: TestSupport.makeTempDir("autoinstall")),
                                       locator: locator)
        try await service.startWithAutoInstall(installer: installer)
        XCTAssertEqual(installer.calls, 1, "install ran once when git was missing")
        XCTAssertNotNil(service.detection)
    }

    func testStartSucceedsDirectlyWithoutInstall() async throws {
        final class NoopInstaller: GitInstalling {
            var calls = 0
            func install() async throws -> GitDetection {
                calls += 1
                throw GitEnvError.installFailed
            }
        }
        let installer = NoopInstaller()
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: TestSupport.makeTempDir("noopinstall")))
        try await service.startWithAutoInstall(installer: installer)
        XCTAssertEqual(installer.calls, 0, "no install when git already present")
    }
}

/// GhRepoCreator validation + fake-gh flow (v1.4.0).
final class GhRepoCreatorTests: XCTestCase {
    func testRejectsInvalidNames() async {
        let creator = GhRepoCreator()
        for bad in ["", "has space", "a/b", "../evil"] {
            do {
                _ = try await creator.createPrivate(name: bad, ghPath: "/usr/bin/true")
                XCTFail("should reject: \(bad)")
            } catch {
                // expected
            }
        }
    }

    func testCreateWithFakeGh() async throws {
        let dir = TestSupport.makeTempDir("fakegh")
        let gh = dir + "/gh"
        let body = "#!/bin/sh\nif [ \"$1\" = \"api\" ]; then echo \"testowner\"; else echo \"created\"; fi\n"
        try body.write(toFile: gh, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
        let creator = GhRepoCreator()
        let url = try await creator.createPrivate(name: "my-notes", ghPath: gh)
        XCTAssertEqual(url, "https://github.com/testowner/my-notes.git")
        try? FileManager.default.removeItem(atPath: dir)
    }
}


/// v2.1.0 per-repo authentication: keychain roundtrip + auth mode config.
final class CredentialStoreTests: XCTestCase {
    func testKeychainRoundtrip() async throws {
        let runner = TestSupport.newRunner()
        guard await CredentialStore.isAvailable(runner: runner) else {
            throw XCTSkip("git credential-osxkeychain unavailable on this machine")
        }
        let url = "https://fv-test-" + UUID().uuidString.prefix(8) + ".example/repo.git"
        defer { Task { try? await CredentialStore.erase(runner: runner, url: url) } }
        // Store -> fill returns matching credentials.
        // SECURITY: never print credential values in assertions.
        try await CredentialStore.store(runner: runner, url: url,
                                        username: "ci-user", password: "pat-secret-123")
        let got = await CredentialStore.fill(runner: runner, url: url)
        XCTAssertNotNil(got, "stored credential must be retrievable")
        XCTAssertEqual(got?.username, "ci-user")
        if got?.password != "pat-secret-123" {
            XCTFail("password mismatch (value hidden)")
        }
        // Erase via reject; helpers that refuse foreign-host erase are tolerated.
        try? await CredentialStore.erase(runner: runner, url: url)
    }

    /// v4.0.2: PAT mode needs a helper; prepare() must configure one idempotently
    /// and the configured helper must accept a store/fill roundtrip.
    func testPrepareConfiguresHelperIdempotentlyAndRoundtrips() async throws {
        let root = TestSupport.makeTempDir("credprepare")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = root + "/repo"
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let runner = TestSupport.newRunner()
        _ = try? await runner.run(["init", "-q", repo])
        let storeFile = URL(fileURLWithPath: root + "/cred/credentials")

        let b1 = await CredentialStore.prepare(runner: runner, repoPath: repo, storeFile: storeFile)
        XCTAssertNotEqual(b1, .unavailable, "a credential helper must always be configurable")
        let b2 = await CredentialStore.prepare(runner: runner, repoPath: repo, storeFile: storeFile)
        XCTAssertEqual(b1, b2, "prepare must be idempotent and keep the chosen backend")

        let all = try? await runner.run(["config", "--local", "--get-all", "credential.helper"], cwd: repo)
        let raw = all?.stdout ?? ""
        XCTAssertFalse(raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "prepare must leave a helper configured")
        // PAT mode takes over the chain: the first (reset) value is empty so an
        // inherited helper cannot shadow the token configured for this repo.
        XCTAssertTrue(raw.hasPrefix("\n"), "expected the reset marker before the helper, got: \(raw.debugDescription)")

        let url = "https://fv-prepare-" + UUID().uuidString.prefix(8) + ".example/r.git"
        defer { Task { try? await CredentialStore.erase(runner: runner, url: url) } }
        try await CredentialStore.store(runner: runner, url: url, username: "u", password: "t")
        let got = await CredentialStore.fill(runner: runner, url: url)
        XCTAssertEqual(got?.username, "u")
        XCTAssertEqual(got?.password, "t")
    }

    func testStorePathParsing() {
        XCTAssertEqual(CredentialStore.storePath(fromHelperValue: "store --file=/tmp/x"), "/tmp/x")
        XCTAssertEqual(CredentialStore.storePath(fromHelperValue: "store --file=\"/tmp/a b\""), "/tmp/a b")
        XCTAssertNil(CredentialStore.storePath(fromHelperValue: "osxkeychain"))
    }

    func testAuthModeConfigRoundtrip() async throws {
        let root = TestSupport.makeTempDir("authmode")
        try? FileManager.default.createDirectory(atPath: root + "/repo", withIntermediateDirectories: true)
        TestSupport.write("s", to: root + "/repo/s.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: root + "/repo")
        let repo = root + "/repo"
        let m0 = await repos.authMode(path: repo)
        XCTAssertEqual(m0, .auto, "default auto")
        await repos.setAuthMode(path: repo, mode: .pat)
        let m1 = await repos.authMode(path: repo)
        XCTAssertEqual(m1, .pat)
        await repos.setAuthMode(path: repo, mode: .ssh)
        let m2 = await repos.authMode(path: repo)
        XCTAssertEqual(m2, .ssh)
        try? FileManager.default.removeItem(atPath: root)
    }
}


/// v2.2.4: remote URL comes from the repo's own source control, editable,
/// and survives remove-root -> re-add unchanged.
final class RemoteSourceOfTruthTests: XCTestCase {
    func testReadsNonOriginRemote() async throws {
        let root = TestSupport.makeTempDir("sot")
        try? FileManager.default.createDirectory(atPath: root + "/repo", withIntermediateDirectories: true)
        TestSupport.write("s", to: root + "/repo/s.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: root + "/repo")
        let repo = root + "/repo"
        // User configured a remote in their own tooling under a custom name.
        try await repos.runner.run(["remote", "add", "upstream", "https://example.com/up.git"], cwd: repo)
        let url = await repos.remoteURL(path: repo)
        XCTAssertEqual(url, "https://example.com/up.git", "must read non-origin remotes")
        // Saving via settings writes the standard origin (terminal-compatible).
        try await repos.setRemote(path: repo, url: "https://example.com/origin.git")
        let url2 = await repos.remoteURL(path: repo)
        XCTAssertEqual(url2, "https://example.com/origin.git")
        let all = await repos.allRemotes(path: repo)
        XCTAssertEqual(all.count, 2, "upstream preserved alongside origin")
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Remove-root -> re-add: remote/auth/autopush/history all intact.
    func testRemoveReaddPreservesEverything() async throws {
        let base = TestSupport.makeTempDir("rerea")
        try? FileManager.default.createDirectory(atPath: base + "/vault/nested", withIntermediateDirectories: true)
        TestSupport.write("seed", to: base + "/vault/s.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: base + "/vault")
        let repos = service.repoManager!
        // v4.0: the managed root is the repo.
        let repo = base + "/vault"
        let remote = base + "/r.git"
        _ = try await repos.runner.run(["init", "--bare", remote])
        try await repos.setRemote(path: repo, url: remote)
        await repos.setAutoPush(path: repo, enabled: true)
        await repos.setAuthMode(path: repo, mode: .pat)
        TestSupport.write("v1", to: repo + "/s.md")
        _ = try await repos.commitAll(path: repo)
        // Remove the root, then re-add it.
        await service.removeRoot(path: base + "/vault")
        XCTAssertEqual(service.rootsSnapshot().count, 0)
        try await service.addRoot(path: base + "/vault")
        // Everything intact (read from the folder's own source control).
        let url = await repos.remoteURL(path: repo)
        XCTAssertEqual(url, remote)
        let auto = await repos.autoPushEnabled(path: repo)
        XCTAssertTrue(auto)
        let mode = await repos.authMode(path: repo)
        XCTAssertEqual(mode, .pat)
        let log = try await repos.log(path: repo)
        XCTAssertEqual(log.count, 2, "history intact")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/.git"))
        try? FileManager.default.removeItem(atPath: base)
    }
}