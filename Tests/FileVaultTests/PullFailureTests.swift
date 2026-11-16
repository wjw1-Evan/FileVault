import XCTest
@testable import FileVaultCore

/// Pull failures must explain themselves and name a next step (v4.1.1).
///
/// Before this, `RepoManager.pull` threw a `GitCommandError` that did not
/// conform to `LocalizedError`, so the settings window showed Foundation's
/// generic "The operation couldn't be completed. (… error 1.)" text.
final class PullFailureClassificationTests: XCTestCase {
    func testDivergenceMessagesAreDetected() {
        let messages = [
            "hint: Diverging branches can't be fast-forwarded, you need to either:\nhint:\nhint: \tgit merge --no-ff\nfatal: Not possible to fast-forward, aborting.",
            " ! [rejected]        main -> main (non-fast-forward)",
            "fatal: refusing to merge unrelated histories",
        ]
        for message in messages {
            XCTAssertTrue(PullError.isDivergence(message), message)
        }
        XCTAssertFalse(PullError.isDivergence("fatal: could not read Username for 'https://example.com': terminal prompts disabled"))
    }

    func testAuthFailureReusesCredentialGuidance() {
        let error = PullError.classify(stderr: "fatal: Authentication failed for 'https://example.com/repo.git/'",
                                       remote: "origin", branch: "main")
        guard case .authenticationFailed = error else { return XCTFail("got \(error)") }
        XCTAssertEqual(error.recoverySuggestion, AuthClassifier.guidance())
        XCTAssertTrue(error.technicalDetail?.contains("Authentication failed") == true)
    }

    /// A raw SSH connectivity failure also carries git's "Could not read from
    /// remote repository"; that must not turn into "re-save your token" advice.
    func testSSHConnectFailureIsNetworkNotAuth() {
        let stderr = "ssh: connect to host github.com port 22: Connection refused\nfatal: Could not read from remote repository."
        let error = PullError.classify(stderr: stderr, remote: "origin", branch: "main")
        guard case .networkFailed = error else { return XCTFail("got \(error)") }
        XCTAssertNotEqual(error.recoverySuggestion, AuthClassifier.guidance())
    }

    /// A branch named "sprint-401" is not an HTTP 401.
    func testBranchNameWithStatusCodeIsNotAuth() {
        let error = PullError.classify(stderr: "fatal: couldn't find remote ref sprint-401",
                                       remote: "origin", branch: "sprint-401")
        XCTAssertEqual(error, .remoteBranchMissing(remote: "origin", branch: "sprint-401"))
    }

    /// Real HTTP status codes must still be reported as authentication.
    func testHTTPStatusIsStillAuth() {
        let stderr = "fatal: unable to access 'https://example.com/repo.git/': The requested URL returned error: 401"
        let error = PullError.classify(stderr: stderr, remote: "origin", branch: "main")
        guard case .authenticationFailed = error else { return XCTFail("got \(error)") }
    }

    func testNetworkFailureIsNamedAsNetwork() {
        let stderr = "fatal: unable to access 'https://example.com/repo.git/': Could not resolve host: example.com"
        let error = PullError.classify(stderr: stderr, remote: "origin", branch: "main")
        guard case .networkFailed = error else { return XCTFail("got \(error)") }
        XCTAssertEqual(error.errorDescription, "网络连接失败，无法访问远程仓库")
        XCTAssertEqual(error.recoverySuggestion, "检查网络或代理设置后重试。")
    }

    func testMissingRemoteBranchExplainsHowToPushFirst() {
        let error = PullError.classify(stderr: "fatal: couldn't find remote ref main",
                                       remote: "origin", branch: "main")
        XCTAssertEqual(error, .remoteBranchMissing(remote: "origin", branch: "main"))
        XCTAssertTrue((error.errorDescription ?? "").contains("origin"))
        XCTAssertTrue((error.recoverySuggestion ?? "").contains("git push -u origin main"))
    }

    func testUnavailableRemoteIsNotReportedAsAuth() {
        let error = PullError.classify(stderr: "fatal: repository 'https://example.com/x.git/' not found",
                                       remote: "origin", branch: "main")
        guard case .remoteUnavailable = error else { return XCTFail("got \(error)") }
        XCTAssertEqual(error.errorDescription, "无法访问远程仓库（地址有误或没有权限）")
    }

    func testLocalChangesAreCalledOut() {
        let stderr = "error: Your local changes to the following files would be overwritten by merge:"
        let error = PullError.classify(stderr: stderr, remote: "origin", branch: "main")
        guard case .localChanges = error else { return XCTFail("got \(error)") }
        XCTAssertEqual(error.errorDescription, "本地未提交的改动阻碍了拉取")
    }

    func testUnknownGitOutputStillProducesAReadableReason() {
        let error = PullError.classify(stderr: "fatal: something unexpected happened",
                                       remote: "origin", branch: "main")
        guard case .failed(let detail) = error else { return XCTFail("got \(error)") }
        XCTAssertEqual(detail, "fatal: something unexpected happened")
        XCTAssertEqual(error.errorDescription, "拉取失败：fatal: something unexpected happened")
        XCTAssertNil(error.recoverySuggestion)
    }

    /// Condensed stderr keeps the reason, drops git's hint spam, caps the length.
    func testCondenseDropsHintsAndCapsLength() {
        let noisy = "hint: a\n\nhint: b\nfatal: real reason\n  "
        XCTAssertEqual(PullError.condense(noisy), "fatal: real reason")
        let capped = PullError.condense(String(repeating: "x", count: 1000))
        XCTAssertEqual(capped.count, 401)   // 400 + ellipsis
        XCTAssertTrue(capped.hasSuffix("…"))
    }
}

/// The generic-NSError regression itself: localizedDescription must carry git's
/// own words now that `GitCommandError` conforms to `LocalizedError`.
final class GitCommandErrorLocalizationTests: XCTestCase {
    func testLocalizedDescriptionCarriesCommandExitCodeAndStderr() {
        let error = GitCommandError(command: "pull --ff-only origin main", exitCode: 128,
                                    stderr: "fatal: Not possible to fast-forward, aborting.\n")
        let text = error.localizedDescription
        XCTAssertTrue(text.contains("pull --ff-only origin main"), text)
        XCTAssertTrue(text.contains("128"), text)
        XCTAssertTrue(text.contains("Not possible to fast-forward"), text)
        XCTAssertFalse(text.contains("The operation couldn’t be completed"), text)
        XCTAssertFalse(text.contains("FileVaultCore.GitCommandError"), text)
    }

    func testEmptyStderrStillExplainsTheCommand() {
        let text = GitCommandError(command: "fetch", exitCode: 1, stderr: " \n").localizedDescription
        XCTAssertTrue(text.contains("fetch"), text)
        XCTAssertTrue(text.contains("1"), text)
    }
}

/// Real-git pull scenarios: branch resolution, fast-forward counting and the
/// failure modes the settings window reports (v4.1.1).
final class PullScenarioTests: XCTestCase {
    private var root: String!
    private var repos: RepoManager!

    override func setUp() {
        root = TestSupport.makeTempDir("pullscenario")
        repos = RepoManager(runner: TestSupport.newRunner())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func git(_ args: [String], cwd: String,
                     file: StaticString = #filePath, line: UInt = #line) async -> GitResult {
        do {
            let r = try await repos.runner.run(args, cwd: cwd)
            XCTAssertTrue(r.succeeded, "git \(args.joined(separator: " ")) failed: \(r.stderr)", file: file, line: line)
            return r
        } catch {
            XCTFail("git \(args.joined(separator: " ")) threw: \(error)", file: file, line: line)
            return GitResult(exitCode: -1, stdout: "", stderr: "\(error)")
        }
    }

    private func makeRepo(_ name: String, seedContent: String = "seed\n") async throws -> String {
        let path = root + "/" + name
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        // Content must be able to differ: two FileVault initial commits built in
        // the same second from identical files have the SAME hash, which would
        // silently make an "unrelated" repo share history with the seed.
        TestSupport.write(seedContent, to: path + "/seed.md")
        _ = try await repos.ensureRepo(at: path)
        return path
    }

    private func makeBareRemote(_ name: String = "remote.git") async throws -> String {
        let path = root + "/" + name
        await git(["init", "--bare", path], cwd: root)
        return path
    }

    /// A bare remote seeded from a local repo the way machine A would have it,
    /// plus its HEAD pointed at main so later clones check out a real branch.
    private func seededRemote() async throws -> (remote: String, seed: String) {
        let remote = try await makeBareRemote()
        let seed = try await makeRepo("seed")
        try await repos.setRemote(path: seed, url: remote)
        await git(["push", "-u", "origin", "HEAD"], cwd: seed)
        await git(["symbolic-ref", "HEAD", "refs/heads/main"], cwd: remote)
        return (remote, seed)
    }

    @discardableResult
    private func commit(_ text: String, file: String, in repo: String) async throws -> String {
        TestSupport.write(text, to: repo + "/" + file)
        return try await repos.commitAll(path: repo, message: "test: " + file)
    }

    private func cloneOf(_ remote: String, as name: String) async throws -> String {
        let path = root + "/" + name
        await git(["clone", remote, path], cwd: root)
        return path
    }

    // MARK: - Scenarios

    func testPullWithoutRemoteIsClassified() async throws {
        let repo = try await makeRepo("lonely")
        do {
            _ = try await repos.pull(path: repo)
            XCTFail("pull without a remote should throw")
        } catch let error as PullError {
            XCTAssertEqual(error, .noRemote)
            XCTAssertNotNil(error.recoverySuggestion)
        }
    }

    /// Regression: no upstream configured, remote has a newer commit. The old
    /// command (`git pull --ff-only origin`) stopped with "did not specify a
    /// branch" before fetching anything; the branch must come from HEAD.
    func testPullWithoutUpstreamFastForwardsCurrentBranch() async throws {
        let (remote, seed) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b")
        // The tracking config is gone (adopted repo, or cleaned by another tool).
        _ = try? await repos.runner.run(["config", "--unset", "branch.main.remote"], cwd: machineB)
        _ = try? await repos.runner.run(["config", "--unset", "branch.main.merge"], cwd: machineB)
        let upstream = try await repos.runner.run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], cwd: machineB)
        XCTAssertFalse(upstream.succeeded, "test setup must leave no upstream")

        try await commit("v2\n", file: "seed.md", in: seed)
        await git(["push"], cwd: seed)
        let remoteHead = try await repos.resolveHead(path: seed)

        let result = try await repos.pull(path: machineB)
        XCTAssertEqual(result.strategy, .fastForward)
        XCTAssertEqual(result.pulledCommits, 1)
        XCTAssertEqual(result.replayedCommits, 0)
        XCTAssertEqual(result.headAfter, remoteHead)
        XCTAssertEqual(try String(contentsOfFile: machineB + "/seed.md", encoding: .utf8), "v2\n")
    }

    func testUpToDatePullReportsZeroNewCommits() async throws {
        let (remote, _) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b")
        let result = try await repos.pull(path: machineB)
        XCTAssertEqual(result.strategy, .fastForward)
        XCTAssertEqual(result.pulledCommits, 0)
        XCTAssertEqual(result.replayedCommits, 0)
        XCTAssertEqual(result.headBefore, result.headAfter)
    }

    /// v4.1.2: two machines that both committed are reconciled automatically by
    /// replaying the local-only auto-commit on top of the remote tip (rebase).
    func testDivergedPullAutoRebasesLocalCommits() async throws {
        let (remote, seed) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b")
        // Both machines committed on their own.
        try await commit("b\n", file: "b.md", in: machineB)
        let localBefore = try await repos.resolveHead(path: machineB)
        try await commit("a\n", file: "a.md", in: seed)
        await git(["push"], cwd: seed)
        let remoteHead = try await repos.resolveHead(path: seed)

        let result = try await repos.pull(path: machineB)
        XCTAssertEqual(result.strategy, .rebased)
        XCTAssertEqual(result.pulledCommits, 1, "one remote commit arrived")
        XCTAssertEqual(result.replayedCommits, 1, "one local commit was replayed")
        XCTAssertNotEqual(result.headAfter, localBefore, "rebase rewrote the local commit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: machineB + "/a.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: machineB + "/b.md"))
        // Linear history: the remote commit is now an ancestor of HEAD, and the
        // replayed local commit sits on top of it.
        let ancestor = try await repos.runner.run(["merge-base", "--is-ancestor", remoteHead, "HEAD"],
                                                  cwd: machineB)
        XCTAssertTrue(ancestor.succeeded, "remote tip must be an ancestor after the rebase")
        let subjects = try await repos.runner.run(["log", "--format=%s", "-2"], cwd: machineB)
        XCTAssertTrue(subjects.stdout.contains("test: a.md"))
        XCTAssertTrue(subjects.stdout.contains("test: b.md"))
    }

    /// Conflicting edits must never leave conflict markers in the repository:
    /// the rebase is aborted, HEAD/content are restored and the files are named.
    func testConflictingEditsAbortCleanlyAndReportFiles() async throws {
        let (remote, seed) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b")
        // Both machines edit the SAME file differently.
        TestSupport.write("machine B version\n", to: machineB + "/seed.md")
        _ = try await repos.commitAll(path: machineB, message: "test: B edit")
        try await commit("machine A version\n", file: "seed.md", in: seed)
        await git(["push"], cwd: seed)
        let before = try await repos.resolveHead(path: machineB)
        let localContent = try String(contentsOfFile: machineB + "/seed.md", encoding: .utf8)

        do {
            _ = try await repos.pull(path: machineB)
            XCTFail("conflicting pull should throw")
        } catch let error as PullError {
            guard case .mergeConflict(let files, let aborted) = error else {
                return XCTFail("expected mergeConflict, got \(error)")
            }
            XCTAssertEqual(files, ["seed.md"])
            XCTAssertTrue(aborted, "the rebase must be aborted, not left half-applied")
            XCTAssertTrue((error.recoverySuggestion ?? "").contains("git pull --rebase"),
                          error.recoverySuggestion ?? "")
        }
        // Restored exactly: same HEAD, same content, clean tree, no rebase state.
        let headAfter = try await repos.resolveHead(path: machineB)
        let contentAfter = try String(contentsOfFile: machineB + "/seed.md", encoding: .utf8)
        let dirtyAfter = try await repos.status(path: machineB).count
        XCTAssertEqual(headAfter, before)
        XCTAssertEqual(contentAfter, localContent)
        XCTAssertFalse(contentAfter.contains("<<<<<<<"), "no conflict markers may remain")
        XCTAssertEqual(dirtyAfter, 0, "working tree must be clean again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: machineB + "/.git/rebase-merge"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: machineB + "/.git/rebase-apply"))
    }

    /// Pending edits become a commit before the auto-merge touches the tree.
    func testDirtyWorkingTreeIsCommittedBeforeAutoMerge() async throws {
        let (remote, seed) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b")
        try await commit("b\n", file: "b.md", in: machineB)
        TestSupport.write("uncommitted draft\n", to: machineB + "/draft.md")
        try await commit("a\n", file: "a.md", in: seed)
        await git(["push"], cwd: seed)

        let result = try await repos.pull(path: machineB)
        XCTAssertEqual(result.strategy, .rebased)
        let dirty = try await repos.status(path: machineB).count
        XCTAssertEqual(dirty, 0, "pending edits were committed first")
        let head = try await repos.runner.run(["log", "-1", "--format=%s"], cwd: machineB)
        XCTAssertTrue(head.stdout.contains("拉取前自动保存"), head.stdout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: machineB + "/draft.md"))
    }

    /// The reported situation: a freshly created FileVault repo bound to a
    /// remote that already has its own unrelated history.
    func testUnrelatedHistoriesAreExplained() async throws {
        let (remote, _) = try await seededRemote()
        let fresh = try await makeRepo("fresh", seedContent: "different content\n")
        try await repos.setRemote(path: fresh, url: remote)

        do {
            _ = try await repos.pull(path: fresh)
            XCTFail("unrelated pull should throw")
        } catch let error as PullError {
            XCTAssertEqual(error, .unrelatedHistories)
            XCTAssertEqual(error.errorDescription, "远程仓库与本地历史互不相关，不能快进合并")
            XCTAssertTrue((error.recoverySuggestion ?? "").contains("git fetch origin"),
                          error.recoverySuggestion ?? "")
        }
    }

    func testRemoteWithoutMatchingBranchIsExplained() async throws {
        let remote = try await makeBareRemote()
        let repo = try await makeRepo("unpushed")
        try await repos.setRemote(path: repo, url: remote)

        do {
            _ = try await repos.pull(path: repo)
            XCTFail("pull from an empty remote should throw")
        } catch let error as PullError {
            XCTAssertEqual(error, .remoteBranchMissing(remote: "origin", branch: "main"))
            XCTAssertTrue((error.recoverySuggestion ?? "").contains("git push -u origin main"),
                          error.recoverySuggestion ?? "")
        }
    }

    /// A moved/deleted/unmounted protected folder must not be reported as a
    /// detached HEAD (git's "not a git repository" goes to stderr, not exit code).
    func testMissingRepositoryFolderIsClassified() async throws {
        let plain = root + "/not-a-repo"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        do {
            _ = try await repos.pull(path: plain)
            XCTFail("pull on a plain folder should throw")
        } catch let error as PullError {
            XCTAssertEqual(error, .notARepository)
            XCTAssertNotNil(error.recoverySuggestion)
        }
    }

    /// With several remotes and no upstream, a guessed remote could fast-forward
    /// the working tree from the wrong place — refuse instead.
    func testSeveralRemotesWithoutUpstreamAreRejected() async throws {
        let repo = try await makeRepo("multi")
        let alpha = try await makeBareRemote("alpha.git")
        let beta = try await makeBareRemote("beta.git")
        await git(["remote", "add", "alpha", alpha], cwd: repo)
        await git(["remote", "add", "beta", beta], cwd: repo)
        do {
            _ = try await repos.pull(path: repo)
            XCTFail("ambiguous remotes should throw")
        } catch let error as PullError {
            XCTAssertEqual(error, .ambiguousRemote)
            XCTAssertTrue((error.recoverySuggestion ?? "").contains("--set-upstream-to"),
                          error.recoverySuggestion ?? "")
        }
    }

    func testDetachedHeadIsRejectedBeforeFetching() async throws {
        let repo = try await makeRepo("detached")
        await git(["checkout", "--detach", "HEAD"], cwd: repo)
        do {
            _ = try await repos.pull(path: repo)
            XCTFail("detached HEAD pull should throw")
        } catch let error as PullError {
            XCTAssertEqual(error, .detachedHead)
        }
    }

    // MARK: - Force pull (remote wins)

    /// The reported situation: a new local repo bound to a remote that already
    /// has its own history. Force pull replaces the local history with the
    /// remote one and keeps the old HEAD recoverable.
    func testForcePullReplacesUnrelatedHistoryAndBacksUpLocal() async throws {
        let (remote, seed) = try await seededRemote()
        let fresh = try await makeRepo("fresh-force", seedContent: "different content\n")
        try await repos.setRemote(path: fresh, url: remote)
        let oldHead = try await repos.resolveHead(path: fresh)
        let remoteHead = try await repos.resolveHead(path: seed)

        let result = try await repos.forcePull(path: fresh)
        XCTAssertEqual(result.replacedHead, oldHead)
        XCTAssertEqual(result.headAfter, remoteHead)
        XCTAssertEqual(result.discardedCommits, 1)
        let backupRef = try XCTUnwrap(result.backupRef)
        let backupHead = try await repos.runner.run(["rev-parse", backupRef], cwd: fresh)
        XCTAssertEqual(backupHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines), oldHead)
        // Folder content now matches the remote.
        XCTAssertEqual(try String(contentsOfFile: fresh + "/seed.md", encoding: .utf8), "seed\n")
        let status = try await repos.status(path: fresh)
        XCTAssertEqual(status.count, 0, "working tree must be clean after the reset")
        // Upstream is bound so the next pull/push needs no setup.
        let upstream = try await repos.runner.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
                                                  cwd: fresh)
        XCTAssertTrue(upstream.succeeded, upstream.stderr)
        XCTAssertEqual(upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "origin/main")
    }

    /// Diverged (related) history: the local commit is discarded but its content
    /// stays recoverable from the backup ref.
    func testForcePullDiscardsDivergedCommitRecoverably() async throws {
        let (remote, seed) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b-force")
        try await commit("local only\n", file: "local.md", in: machineB)
        let oldHead = try await repos.resolveHead(path: machineB)
        try await commit("remote only\n", file: "remote.md", in: seed)
        await git(["push"], cwd: seed)
        let remoteHead = try await repos.resolveHead(path: seed)

        let result = try await repos.forcePull(path: machineB)
        XCTAssertEqual(result.headAfter, remoteHead)
        XCTAssertEqual(result.discardedCommits, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: machineB + "/local.md"),
                       "a file only present in the discarded history is removed from disk")
        let backupRef = try XCTUnwrap(result.backupRef)
        let recovered = try await repos.runner.run(["show", backupRef + ":local.md"], cwd: machineB)
        XCTAssertEqual(recovered.stdout, "local only\n", "the backup ref still contains that content")
        XCTAssertTrue(FileManager.default.fileExists(atPath: machineB + "/remote.md"))
    }

    /// Force pull with nothing to discard is just a safe catch-up.
    func testForcePullFastForwardsWhenLocalIsBehind() async throws {
        let (remote, seed) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b-behind")
        try await commit("v2\n", file: "seed.md", in: seed)
        await git(["push"], cwd: seed)
        let remoteHead = try await repos.resolveHead(path: seed)

        let result = try await repos.forcePull(path: machineB)
        XCTAssertEqual(result.headAfter, remoteHead)
        XCTAssertEqual(result.discardedCommits, 0)
        XCTAssertEqual(try String(contentsOfFile: machineB + "/seed.md", encoding: .utf8), "v2\n")
    }

    /// No remote: the force pull must fail without touching HEAD.
    func testForcePullWithoutRemoteLeavesRepoUntouched() async throws {
        let repo = try await makeRepo("lonely-force")
        let before = try await repos.resolveHead(path: repo)
        do {
            _ = try await repos.forcePull(path: repo)
            XCTFail("force pull without a remote should throw")
        } catch let error as PullError {
            XCTAssertEqual(error, .noRemote)
        }
        let after = try await repos.resolveHead(path: repo)
        XCTAssertEqual(after, before)
    }

    // MARK: - Merge sync (keep both sides' files)

    /// The requested case: the remote already has files AND the local folder
    /// has files of its own. Sync must bring the remote files in without losing
    /// either side; same-name differences end up as two files.
    func testMergeSyncKeepsFilesFromBothSides() async throws {
        let (remote, seed) = try await seededRemote()
        // Local folder: own files, own (unrelated) history.
        let local = try await makeRepo("local-sync")   // seed.md identical on both sides
        TestSupport.write("local only\n", to: local + "/local-only.md")
        try FileManager.default.createDirectory(atPath: local + "/dir", withIntermediateDirectories: true)
        TestSupport.write("local shared\n", to: local + "/dir/shared.md")
        _ = try await repos.commitAll(path: local, message: "test: local files")
        try await repos.setRemote(path: local, url: remote)
        let localHead = try await repos.resolveHead(path: local)

        // Remote: its own files, including a same-name-different-content one.
        try FileManager.default.createDirectory(atPath: seed + "/dir", withIntermediateDirectories: true)
        TestSupport.write("remote shared\n", to: seed + "/dir/shared.md")
        TestSupport.write("remote only\n", to: seed + "/remote-only.md")
        _ = try await repos.commitAll(path: seed, message: "test: remote files")
        await git(["push"], cwd: seed)
        let remoteHead = try await repos.resolveHead(path: seed)

        let result = try await repos.mergeSync(path: local)
        XCTAssertTrue(result.didChange)
        XCTAssertEqual(result.addedFromRemote, 1, "remote-only.md came from the remote")
        XCTAssertEqual(result.keptLocalOnly, 1, "local-only.md stayed")
        XCTAssertEqual(result.localCopies.count, 1)
        let copy = try XCTUnwrap(result.localCopies.first)
        XCTAssertEqual(copy.path, "dir/shared.md")
        XCTAssertEqual(copy.copyPath, "dir/shared (本地副本).md")
        XCTAssertNotNil(result.backupRef, "the replaced HEAD must stay recoverable")

        // Remote version at the original path, local version in the copy.
        let sharedNow = try String(contentsOfFile: local + "/dir/shared.md", encoding: .utf8)
        let localCopyNow = try String(contentsOfFile: local + "/dir/shared (本地副本).md", encoding: .utf8)
        XCTAssertEqual(sharedNow, "remote shared\n")
        XCTAssertEqual(localCopyNow, "local shared\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: local + "/remote-only.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: local + "/local-only.md"))
        let dirty = try await repos.status(path: local).count
        XCTAssertEqual(dirty, 0, "the merge commit leaves a clean tree")

        // Merge commit with exactly the local and remote heads as parents.
        let parents = try await repos.runner.run(["rev-list", "--parents", "-n", "1", "HEAD"], cwd: local)
        let hashes = parents.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").map(String.init)
        XCTAssertEqual(hashes.count, 3, "a merge commit has two parents")
        XCTAssertEqual(Set(hashes.suffix(2)), Set([localHead, remoteHead]))

        // Upstream bound for later pulls/pushes.
        let upstream = try await repos.runner.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
                                                  cwd: local)
        XCTAssertTrue(upstream.succeeded, upstream.stderr)

        // Backup ref still points at the replaced local HEAD.
        let backupRef = try XCTUnwrap(result.backupRef)
        let backupHead = try await repos.runner.run(["rev-parse", backupRef], cwd: local)
        XCTAssertEqual(backupHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines), localHead)
    }

    func testMergeSyncSecondRunIsNoOp() async throws {
        let (remote, _) = try await seededRemote()
        let local = try await makeRepo("local-sync2", seedContent: "local\n")
        try await repos.setRemote(path: local, url: remote)
        _ = try await repos.mergeSync(path: local)
        let headAfterFirst = try await repos.resolveHead(path: local)

        let second = try await repos.mergeSync(path: local)
        XCTAssertFalse(second.didChange)
        XCTAssertEqual(second.addedFromRemote, 0)
        XCTAssertTrue(second.localCopies.isEmpty)
        let headAfterSecond = try await repos.resolveHead(path: local)
        XCTAssertEqual(headAfterSecond, headAfterFirst)
    }

    /// Related but diverged histories: both sides' new files survive.
    func testMergeSyncRelatedDivergenceKeepsBothChanges() async throws {
        let (remote, seed) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b-sync")
        try await commit("local\n", file: "local.md", in: machineB)
        let localHead = try await repos.resolveHead(path: machineB)
        try await commit("remote\n", file: "remote2.md", in: seed)
        await git(["push"], cwd: seed)
        let remoteHead = try await repos.resolveHead(path: seed)

        let result = try await repos.mergeSync(path: machineB)
        XCTAssertEqual(result.addedFromRemote, 1, "remote2.md")
        XCTAssertEqual(result.keptLocalOnly, 1, "local.md")
        XCTAssertTrue(result.localCopies.isEmpty, "different paths need no copies")
        XCTAssertTrue(FileManager.default.fileExists(atPath: machineB + "/local.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: machineB + "/remote2.md"))
        let parents = try await repos.runner.run(["rev-list", "--parents", "-n", "1", "HEAD"], cwd: machineB)
        let hashes = parents.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").map(String.init)
        XCTAssertEqual(Set(hashes.suffix(2)), Set([localHead, remoteHead]))
    }

    func testMergeSyncWithoutRemoteFailsWithoutChangingHead() async throws {
        let repo = try await makeRepo("lonely-sync")
        let before = try await repos.resolveHead(path: repo)
        do {
            _ = try await repos.mergeSync(path: repo)
            XCTFail("sync without a remote should throw")
        } catch let error as PullError {
            XCTAssertEqual(error, .noRemote)
        }
        let after = try await repos.resolveHead(path: repo)
        XCTAssertEqual(after, before)
    }
}
