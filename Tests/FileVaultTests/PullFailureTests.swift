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

    /// Every case must render a non-empty localized reason; only `.failed` may
    /// omit a recovery suggestion.
    func testEveryCaseHasReadableDescriptionAndSuggestion() {
        let cases: [PullError] = [
            .noRemote, .ambiguousRemote(), .notARepository, .detachedHead,
            .remoteBranchMissing(remote: "origin", branch: "main"),
            .unrelatedHistories,
            .mergeConflict(files: ["a.md"], aborted: true),
            .mergeConflict(files: ["a.md"], aborted: false),
            .authenticationFailed(detail: "x"), .networkFailed(detail: "x"),
            .remoteUnavailable(detail: "x"), .localChanges(detail: "x"),
            .busy, .repositoryLocked(detail: "x"), .unsafeRepository(detail: "x"),
            .failed(detail: "x"),
        ]
        for error in cases {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "no description for \(error)")
            if case .failed = error {
                XCTAssertNil(error.recoverySuggestion)
            } else {
                XCTAssertFalse((error.recoverySuggestion ?? "").isEmpty, "no suggestion for \(error)")
            }
        }
    }

    func testConflictDescriptionReflectsCleanupState() {
        let aborted = PullError.mergeConflict(files: ["a.md"], aborted: true)
        let notAborted = PullError.mergeConflict(files: ["a.md"], aborted: false)
        XCTAssertNotEqual(aborted.errorDescription, notAborted.errorDescription)
        XCTAssertTrue((aborted.errorDescription ?? "").contains("已中止"))
        XCTAssertTrue((notAborted.errorDescription ?? "").contains("未能自动恢复"))
        XCTAssertTrue((aborted.recoverySuggestion ?? "").contains("git pull --rebase"))
        XCTAssertTrue((notAborted.recoverySuggestion ?? "").contains("git rebase --abort"))
    }

    func testConflictFileListIsCappedAndReadable() {
        XCTAssertEqual(PullError.fileList([]), "未知文件")
        XCTAssertEqual(PullError.fileList(["a.md"]), "a.md")
        XCTAssertEqual(PullError.fileList(["a.md", "b.md"]), "a.md、b.md")
        let five = PullError.fileList(["a", "b", "c", "d", "e"])
        XCTAssertTrue(five.contains("a、b、c"), five)
        XCTAssertTrue(five.contains("等 5 个文件"), five)
        XCTAssertTrue((PullError.mergeConflict(files: ["a.md"], aborted: true).recoverySuggestion ?? "")
            .contains("a.md"))
    }

    func testTechnicalDetailOnlyForTextualCases() {
        XCTAssertEqual(PullError.failed(detail: "boom").technicalDetail, "boom")
        XCTAssertEqual(PullError.networkFailed(detail: "dns").technicalDetail, "dns")
        XCTAssertNil(PullError.noRemote.technicalDetail)
        XCTAssertEqual(PullError.mergeConflict(files: ["a.md", "b.md"], aborted: true).technicalDetail,
                       "a.md, b.md")
        XCTAssertNil(PullError.mergeConflict(files: [], aborted: true).technicalDetail)
    }

    func testUnstagedChangesAreClassifiedAsLocalChanges() {
        let error = PullError.classify(stderr: "error: cannot pull with rebase: You have unstaged changes.",
                                       remote: "origin", branch: "main")
        guard case .localChanges = error else { return XCTFail("got \(error)") }
    }

    func testBusyAndNotARepositoryAreUserReadable() {
        XCTAssertTrue((PullError.busy.errorDescription ?? "").contains("正在执行另一次"))
        XCTAssertTrue((PullError.busy.recoverySuggestion ?? "").contains("重试"))
        XCTAssertTrue((PullError.notARepository.errorDescription ?? "").contains("Git 仓库"))
    }
    /// A stale/held git lock must be named with a fix, not reported as auth or
    /// network trouble (v4.1.7).
    func testRepositoryLockIsExplained() {
        let stderr = "fatal: Unable to create '/x/repo/.git/index.lock': File exists.\n\nAnother git process seems to be running in this repository"
        let error = PullError.classify(stderr: stderr, remote: "origin", branch: "main")
        guard case .repositoryLocked = error else { return XCTFail("got \(error)") }
        XCTAssertTrue((error.errorDescription ?? "").contains("占用"))
        XCTAssertTrue((error.recoverySuggestion ?? "").contains("index.lock"))
        XCTAssertTrue(error.technicalDetail?.contains("index.lock") == true)
    }

    /// A folder owned by another account makes git refuse everything; the fix
    /// is a single safe.directory line (v4.1.9).
    func testDubiousOwnershipIsExplained() {
        let error = PullError.classify(
            stderr: "fatal: detected dubious ownership in repository at '/Volumes/X/repo'",
            remote: "origin", branch: "main")
        guard case .unsafeRepository = error else { return XCTFail("got \(error)") }
        XCTAssertTrue((error.errorDescription ?? "").contains("所有者"))
        XCTAssertTrue((error.recoverySuggestion ?? "").contains("safe.directory"))
        XCTAssertTrue(error.technicalDetail?.contains("dubious ownership") == true)
    }

    /// main-vs-master mismatches are common; the error must list the remote's
    /// actual branches and show the set-upstream command.
    func testBranchMismatchListsAvailableBranches() {
        let error = PullError.remoteBranchMissing(remote: "origin", branch: "main",
                                                  available: ["develop", "master"])
        let description = error.errorDescription ?? ""
        let suggestion = error.recoverySuggestion ?? ""
        XCTAssertTrue(description.contains("main"), description)
        XCTAssertTrue(description.contains("master"), description)
        XCTAssertTrue(description.contains("develop"), description)
        XCTAssertTrue(suggestion.contains("现有：develop、master"), suggestion)
        XCTAssertTrue(suggestion.contains("--set-upstream-to=origin/<分支>"), suggestion)
        // No available branches keeps the old "push first" guidance.
        let empty = PullError.remoteBranchMissing(remote: "origin", branch: "main", available: [])
        XCTAssertTrue((empty.recoverySuggestion ?? "").contains("git push -u origin main"))
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
            guard case .ambiguousRemote(let remotes) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(remotes.sorted(), ["alpha", "beta"], "the actual remote names must be listed")
            let description = error.errorDescription ?? ""
            XCTAssertTrue(description.contains("alpha"), description)
            XCTAssertTrue(description.contains("beta"), description)
            XCTAssertTrue((error.recoverySuggestion ?? "").contains("--set-upstream-to=alpha/"),
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
        XCTAssertEqual(result.remoteCopies.count, 1)
        let copy = try XCTUnwrap(result.remoteCopies.first)
        XCTAssertEqual(copy.path, "dir/shared.md")
        XCTAssertEqual(copy.copyPath, "dir/shared (远程副本).md")
        XCTAssertNotNil(result.backupRef, "the replaced HEAD must stay recoverable")
        XCTAssertTrue(result.needsPush, "a sync is a round trip: local work must be pushed")
        XCTAssertGreaterThan(result.aheadCommits, 0)

        // Local version at the original path, remote version in the copy.
        let sharedNow = try String(contentsOfFile: local + "/dir/shared.md", encoding: .utf8)
        let remoteCopyNow = try String(contentsOfFile: local + "/dir/shared (远程副本).md", encoding: .utf8)
        XCTAssertEqual(sharedNow, "local shared\n")
        XCTAssertEqual(remoteCopyNow, "remote shared\n")
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
        XCTAssertTrue(second.remoteCopies.isEmpty)
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
        XCTAssertTrue(result.remoteCopies.isEmpty, "different paths need no copies")
        XCTAssertEqual(result.aheadCommits, 2, "local.md commit + the merge commit")
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

    /// Local already contains everything from the remote: sync must not create a
    /// merge commit, but must report the local commits still waiting to push.
    func testMergeSyncLocalAheadReportsPushNeeded() async throws {
        let (remote, _) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b-ahead")
        try await commit("local\n", file: "local-ahead.md", in: machineB)
        let before = try await repos.resolveHead(path: machineB)

        let result = try await repos.mergeSync(path: machineB)
        XCTAssertFalse(result.didChange)
        XCTAssertEqual(result.addedFromRemote, 0)
        XCTAssertTrue(result.remoteCopies.isEmpty)
        XCTAssertTrue(result.needsPush)
        XCTAssertEqual(result.aheadCommits, 1)
        let after = try await repos.resolveHead(path: machineB)
        XCTAssertEqual(after, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: machineB + "/local-ahead.md"))
    }

    /// Unrelated histories whose trees are already identical still get a merge
    /// commit, so the two sides can be pushed/pulled together afterwards.
    func testMergeSyncIdenticalTreesCreatesMergeCommit() async throws {
        let (remote, seed) = try await seededRemote()
        let local = try await makeRepo("local-identical")   // same file contents as seed
        // Two FileVault initial commits built in the same second are identical
        // objects; re-date the local one so the histories are truly unrelated
        // while the trees stay equal.
        _ = try await repos.runner.run(["commit", "--amend", "--no-edit", "--date", "2020-01-01T00:00:00"],
                                       cwd: local)
        try await repos.setRemote(path: local, url: remote)
        let localHead = try await repos.resolveHead(path: local)
        let remoteHead = try await repos.resolveHead(path: seed)

        let result = try await repos.mergeSync(path: local)
        XCTAssertTrue(result.didChange, "unrelated roots need a merge commit even with equal trees")
        XCTAssertEqual(result.addedFromRemote, 0)
        XCTAssertEqual(result.keptLocalOnly, 0)
        XCTAssertTrue(result.remoteCopies.isEmpty)
        let dirty = try await repos.status(path: local).count
        XCTAssertEqual(dirty, 0)
        let parents = try await repos.runner.run(["rev-list", "--parents", "-n", "1", "HEAD"], cwd: local)
        let hashes = parents.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").map(String.init)
        XCTAssertEqual(Set(hashes.suffix(2)), Set([localHead, remoteHead]))
    }

    // MARK: - Empty repo, dirty tree, locking

    func testPullIntoEmptyRepoAdoptsRemoteBranch() async throws {
        let (remote, _) = try await seededRemote()
        let empty = root + "/empty-pull"
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        await git(["init", "-b", "main"], cwd: empty)
        try await repos.setRemote(path: empty, url: remote)

        let result = try await repos.pull(path: empty)
        XCTAssertNil(result.headBefore)
        XCTAssertEqual(result.strategy, .fastForward)
        XCTAssertEqual(result.pulledCommits, 1)
        XCTAssertEqual(try String(contentsOfFile: empty + "/seed.md", encoding: .utf8), "seed\n")
        let log = try await repos.runner.run(["log", "--oneline"], cwd: empty)
        XCTAssertTrue(log.succeeded, log.stderr)
    }

    func testPullCommitsPendingEditsBeforeFastForward() async throws {
        let (remote, seed) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b-dirty-pull")
        try await commit("v2\n", file: "seed.md", in: seed)
        await git(["push"], cwd: seed)
        // Uncommitted local work must survive the pull as a commit.
        TestSupport.write("draft\n", to: machineB + "/draft.md")

        _ = try await repos.pull(path: machineB)
        let subjects = try await repos.runner.run(["log", "--format=%s", "-3"], cwd: machineB)
        XCTAssertTrue(subjects.stdout.contains("拉取前自动保存未提交改动"), subjects.stdout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: machineB + "/draft.md"))
        XCTAssertEqual(try String(contentsOfFile: machineB + "/seed.md", encoding: .utf8), "v2\n")
        let dirty = try await repos.status(path: machineB).count
        XCTAssertEqual(dirty, 0)
    }

    func testRemoteOperationLockIsReleasedAfterFailure() async throws {
        let repo = try await makeRepo("lock-release")
        for attempt in 1...2 {
            do {
                _ = try await repos.pull(path: repo)
                XCTFail("attempt \(attempt): pull without a remote should throw")
            } catch let error as PullError {
                XCTAssertEqual(error, .noRemote,
                               "attempt \(attempt) must not be .busy: the lock was released")
            }
        }
    }

    func testConcurrentPullsAreSerialized() async throws {
        let (remote, seed) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b-concurrent")
        try await commit("v2\n", file: "seed.md", in: seed)
        await git(["push"], cwd: seed)

        async let first = repos.pull(path: machineB)
        async let second = repos.pull(path: machineB)
        let (r1, r2) = try await (first, second)
        XCTAssertEqual(r1.headAfter, r2.headAfter, "both pulls must converge on the remote tip")
        let dirty = try await repos.status(path: machineB).count
        XCTAssertEqual(dirty, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: machineB + "/.git/rebase-merge"))
    }

    // MARK: - Force pull edges

    func testForcePullBacksUpPendingEdits() async throws {
        let (remote, seed) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b-force-dirty")
        try await commit("v2\n", file: "seed.md", in: seed)
        await git(["push"], cwd: seed)
        TestSupport.write("unsaved local edit\n", to: machineB + "/draft.md")

        let result = try await repos.forcePull(path: machineB)
        let backupRef = try XCTUnwrap(result.backupRef)
        // The pending edit was committed before the reset, so the backup ref
        // still contains it.
        let recovered = try await repos.runner.run(["show", backupRef + ":draft.md"], cwd: machineB)
        XCTAssertEqual(recovered.stdout, "unsaved local edit\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: machineB + "/draft.md"),
                       "the remote tree replaces the working tree")
        XCTAssertGreaterThanOrEqual(result.discardedCommits, 1)
    }

    func testForcePullWhenAlreadyInSyncIsNoOp() async throws {
        let (remote, _) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b-force-same")
        let before = try await repos.resolveHead(path: machineB)

        let result = try await repos.forcePull(path: machineB)
        XCTAssertNil(result.backupRef, "nothing is replaced, so nothing needs backing up")
        XCTAssertEqual(result.discardedCommits, 0)
        XCTAssertEqual(result.headAfter, before)
    }

    func testForcePullRejectsDetachedHead() async throws {
        let repo = try await makeRepo("force-detached")
        await git(["checkout", "--detach", "HEAD"], cwd: repo)
        do {
            _ = try await repos.forcePull(path: repo)
            XCTFail("force pull on a detached HEAD should throw")
        } catch let error as PullError {
            XCTAssertEqual(error, .detachedHead)
        }
    }

    func testForcePullRemoteWithoutBranchFailsCleanly() async throws {
        let remote = try await makeBareRemote("force-empty.git")
        let repo = try await makeRepo("force-unpushed")
        try await repos.setRemote(path: repo, url: remote)
        let before = try await repos.resolveHead(path: repo)
        do {
            _ = try await repos.forcePull(path: repo)
            XCTFail("force pull from an empty remote should throw")
        } catch let error as PullError {
            XCTAssertEqual(error, .remoteBranchMissing(remote: "origin", branch: "main"))
        }
        let after = try await repos.resolveHead(path: repo)
        XCTAssertEqual(after, before)
    }

    // MARK: - Merge sync edges

    func testMergeSyncDeleteModifyKeepsSurvivingSide() async throws {
        let (remote, seed) = try await seededRemote()
        // Base commit carrying both files on the remote.
        TestSupport.write("base\n", to: seed + "/mod-local.md")
        TestSupport.write("base\n", to: seed + "/del-local.md")
        _ = try await repos.commitAll(path: seed, message: "test: base files")
        await git(["push"], cwd: seed)
        let machineB = try await cloneOf(remote, as: "machine-b-delmod")
        // Local: modify mod-local, delete del-local.
        TestSupport.write("local change\n", to: machineB + "/mod-local.md")
        _ = try await repos.runner.run(["rm", "del-local.md"], cwd: machineB)
        _ = try await repos.commitAll(path: machineB, message: "test: local del/mod")
        // Remote: delete mod-local, modify del-local.
        _ = try await repos.runner.run(["rm", "mod-local.md"], cwd: seed)
        TestSupport.write("remote change\n", to: seed + "/del-local.md")
        _ = try await repos.commitAll(path: seed, message: "test: remote del/mod")
        await git(["push"], cwd: seed)

        let result = try await repos.mergeSync(path: machineB)
        XCTAssertTrue(result.remoteCopies.isEmpty, "delete/modify keeps one surviving side, no copies")
        XCTAssertEqual(try String(contentsOfFile: machineB + "/mod-local.md", encoding: .utf8),
                       "local change\n", "remote deleted it but local changed it: keep local")
        XCTAssertEqual(try String(contentsOfFile: machineB + "/del-local.md", encoding: .utf8),
                       "remote change\n", "local deleted it but remote changed it: restore remote")
        let dirty = try await repos.status(path: machineB).count
        XCTAssertEqual(dirty, 0)
        XCTAssertTrue(result.needsPush)
    }

    func testMergeSyncRemoteAheadFastForwards() async throws {
        let (remote, seed) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b-ff-sync")
        try await commit("remote only\n", file: "new-remote.md", in: seed)
        await git(["push"], cwd: seed)
        let remoteHead = try await repos.resolveHead(path: seed)

        let result = try await repos.mergeSync(path: machineB)
        XCTAssertTrue(result.didChange)
        XCTAssertEqual(result.addedFromRemote, 1)
        XCTAssertTrue(result.remoteCopies.isEmpty)
        XCTAssertEqual(result.headAfter, remoteHead)
        let parents = try await repos.runner.run(["rev-list", "--parents", "-n", "1", "HEAD"], cwd: machineB)
        let hashes = parents.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").map(String.init)
        XCTAssertEqual(hashes.count, 2, "a fast-forward has a single parent")
    }

    func testMergeSyncCopyNameCollisionGetsSuffix() async throws {
        let (remote, seed) = try await seededRemote()
        let local = try await makeRepo("local-collision")
        TestSupport.write("local\n", to: local + "/shared.md")
        TestSupport.write("already there\n", to: local + "/shared (远程副本).md")
        _ = try await repos.commitAll(path: local, message: "test: local files")
        try await repos.setRemote(path: local, url: remote)
        TestSupport.write("remote\n", to: seed + "/shared.md")
        _ = try await repos.commitAll(path: seed, message: "test: remote file")
        await git(["push"], cwd: seed)

        let result = try await repos.mergeSync(path: local)
        XCTAssertEqual(result.remoteCopies.count, 1)
        XCTAssertEqual(result.remoteCopies.first?.copyPath, "shared (远程副本 2).md")
        XCTAssertEqual(try String(contentsOfFile: local + "/shared.md", encoding: .utf8), "local\n")
        XCTAssertEqual(try String(contentsOfFile: local + "/shared (远程副本 2).md", encoding: .utf8),
                       "remote\n")
        XCTAssertEqual(try String(contentsOfFile: local + "/shared (远程副本).md", encoding: .utf8),
                       "already there\n")
    }

    func testMergeSyncEmptyLocalRepoAdoptsRemote() async throws {
        let (remote, seed) = try await seededRemote()
        let empty = root + "/empty-sync"
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        await git(["init", "-b", "main"], cwd: empty)
        try await repos.setRemote(path: empty, url: remote)
        let remoteHead = try await repos.resolveHead(path: seed)

        let result = try await repos.mergeSync(path: empty)
        XCTAssertNil(result.headBefore)
        XCTAssertEqual(result.headAfter, remoteHead)
        XCTAssertGreaterThanOrEqual(result.addedFromRemote, 2)   // .gitignore + seed.md
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty + "/seed.md"))
        let upstream = try await repos.runner.run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], cwd: empty)
        XCTAssertTrue(upstream.succeeded, upstream.stderr)
    }

    func testMergeSyncCommitMessageNamesTheMode() async throws {
        let (remote, _) = try await seededRemote()
        let local = try await makeRepo("local-message", seedContent: "different content\n")
        try await repos.setRemote(path: local, url: remote)
        _ = try await repos.mergeSync(path: local)
        let subject = try await repos.runner.run(["log", "-1", "--format=%s"], cwd: local)
        XCTAssertEqual(subject.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       "sync: 同步远程文件到本地（保留本地文件）")
    }

    /// A local main branch against a remote whose branch is master must explain
    /// the mismatch with the remote's real branch names (v4.1.7).
    func testPullExplainsBranchNameMismatch() async throws {
        let remote = root + "/master.git"
        await git(["init", "--bare", remote], cwd: root)
        let seed = root + "/masterSeed"
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        await git(["init", "-b", "master"], cwd: seed)
        _ = try await repos.runner.run(["config", "user.name", "Seed"], cwd: seed)
        _ = try await repos.runner.run(["config", "user.email", "seed@x"], cwd: seed)
        TestSupport.write("seed\n", to: seed + "/seed.md")
        _ = try await repos.runner.run(["add", "-A"], cwd: seed)
        _ = try await repos.runner.run(["commit", "-m", "seed"], cwd: seed)
        _ = try await repos.runner.run(["remote", "add", "origin", remote], cwd: seed)
        await git(["push", "-u", "origin", "master"], cwd: seed)

        let local = try await makeRepo("branch-mismatch")
        try await repos.setRemote(path: local, url: remote)
        do {
            _ = try await repos.pull(path: local)
            XCTFail("pull should explain the branch mismatch")
        } catch let error as PullError {
            guard case .remoteBranchMissing(let reportedRemote, let branch, let available) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(reportedRemote, "origin")
            XCTAssertEqual(branch, "main")
            XCTAssertEqual(available, ["master"], "the remote's real branches must be listed")
            XCTAssertTrue((error.errorDescription ?? "").contains("master"))
            XCTAssertTrue((error.recoverySuggestion ?? "").contains("现有：master"), error.recoverySuggestion ?? "")
            XCTAssertTrue((error.recoverySuggestion ?? "").contains("--set-upstream-to=origin/<分支>"),
                          error.recoverySuggestion ?? "")
        }
    }

    /// Ignored local files (.DS_Store) that the remote starts tracking must not
    /// block the pull: they are preserved as "本地副本" and nothing is lost
    /// (v4.1.8).
    func testPullPreservesIgnoredLocalFileInsteadOfFailing() async throws {
        let (remote, seed) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b-ignored-file")
        // The remote starts tracking .DS_Store (force-added: it is gitignored).
        TestSupport.write("remote version\n", to: seed + "/.DS_Store")
        _ = try await repos.runner.run(["add", "-f", ".DS_Store"], cwd: seed)
        _ = try await repos.runner.run(["commit", "-m", "test: track DS_Store"], cwd: seed)
        await git(["push"], cwd: seed)
        // Locally the same name is an ignored, untracked file with other content.
        TestSupport.write("local version\n", to: machineB + "/.DS_Store")
        let dirty = try await repos.status(path: machineB).count
        XCTAssertEqual(dirty, 0, "the local .DS_Store must stay ignored")

        let result = try await repos.pull(path: machineB)
        XCTAssertEqual(result.movedLocalCopies, [".DS_Store (本地副本)"])
        XCTAssertEqual(try String(contentsOfFile: machineB + "/.DS_Store", encoding: .utf8),
                       "remote version\n")
        XCTAssertEqual(try String(contentsOfFile: machineB + "/.DS_Store (本地副本)", encoding: .utf8),
                       "local version\n", "the local content must not be lost")
    }


    /// Sync (keep local files) must protect ignored local files too: the merge
    /// would otherwise overwrite them silently (v4.1.8).
    func testMergeSyncPreservesIgnoredLocalFileInsteadOfFailing() async throws {
        let (remote, seed) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b-ignored-sync")
        TestSupport.write("remote version\n", to: seed + "/.DS_Store")
        _ = try await repos.runner.run(["add", "-f", ".DS_Store"], cwd: seed)
        _ = try await repos.runner.run(["commit", "-m", "test: track DS_Store"], cwd: seed)
        await git(["push"], cwd: seed)
        TestSupport.write("local version\n", to: machineB + "/.DS_Store")

        let result = try await repos.mergeSync(path: machineB)
        XCTAssertEqual(result.movedLocalCopies, [".DS_Store (本地副本)"])
        XCTAssertEqual(try String(contentsOfFile: machineB + "/.DS_Store", encoding: .utf8),
                       "remote version\n")
        XCTAssertEqual(try String(contentsOfFile: machineB + "/.DS_Store (本地副本)", encoding: .utf8),
                       "local version\n", "the local content must not be lost")
    }
    /// The same protection applies to the destructive force pull reset.
    func testForcePullPreservesIgnoredLocalFileInsteadOfFailing() async throws {
        let (remote, seed) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b-ignored-force")
        TestSupport.write("remote version\n", to: seed + "/.DS_Store")
        _ = try await repos.runner.run(["add", "-f", ".DS_Store"], cwd: seed)
        _ = try await repos.runner.run(["commit", "-m", "test: track DS_Store"], cwd: seed)
        await git(["push"], cwd: seed)
        TestSupport.write("local version\n", to: machineB + "/.DS_Store")

        let result = try await repos.forcePull(path: machineB)
        XCTAssertEqual(result.movedLocalCopies, [".DS_Store (本地副本)"])
        XCTAssertEqual(try String(contentsOfFile: machineB + "/.DS_Store", encoding: .utf8),
                       "remote version\n")
        XCTAssertEqual(try String(contentsOfFile: machineB + "/.DS_Store (本地副本)", encoding: .utf8),
                       "local version\n", "the local content must not be lost")
        let seedHead = try await repos.resolveHead(path: seed)
        XCTAssertEqual(result.headAfter, seedHead)
    }

    /// Several remotes and no upstream: the in-app choice sets the upstream so
    /// the automatic sync has a target (v4.2.1).
    func testUpstreamRemoteSelectionResolvesAmbiguity() async throws {
        let (remote, _) = try await seededRemote()
        let machineB = try await cloneOf(remote, as: "machine-b-select")
        // Make BOTH remotes non-origin, then drop the upstream the clone set.
        await git(["remote", "rename", "origin", "alpha"], cwd: machineB)
        let beta = try await makeBareRemote("beta.git")
        await git(["remote", "add", "beta", beta], cwd: machineB)
        await git(["config", "--unset", "branch.main.remote"], cwd: machineB)
        await git(["config", "--unset", "branch.main.merge"], cwd: machineB)

        let names = await repos.remoteNames(path: machineB)
        XCTAssertEqual(names.sorted(), ["alpha", "beta"])
        do {
            _ = try await repos.pull(path: machineB)
            XCTFail("ambiguous remotes should refuse")
        } catch let error as PullError {
            guard case .ambiguousRemote(let listed) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(listed.sorted(), ["alpha", "beta"])
        }

        try await repos.setUpstreamRemote(path: machineB, remote: "alpha")
        let upstream = try await repos.runner.run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], cwd: machineB)
        XCTAssertEqual(upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "alpha/main")
        let result = try await repos.pull(path: machineB)
        XCTAssertEqual(result.pulledCommits, 0, "the pull now targets the chosen remote")
    }
}

/// The auto-commit pipeline must stay out of the way while a pull's rebase or a
/// sync merge owns the repository (v4.1.5).
final class CommitPipelineGuardTests: XCTestCase {
    func testPipelineSkipsWhileMergeOrRebaseInProgress() async throws {
        let dir = TestSupport.makeTempDir("pipeguard")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        TestSupport.write("seed\n", to: dir + "/seed.md")
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: dir)

        var commits: [String] = []
        let lock = NSLock()
        let engine = CommitEngine(repoManager: repos,
                                  debouncer: Debouncer(quietInterval: 30, maxWait: 60, onFired: { _ in }),
                                  pause: PauseController())
        engine.onCommit = { _, hash, _ in lock.lock(); commits.append(hash); lock.unlock() }
        TestSupport.write("pending\n", to: dir + "/pending.md")

        // A half-applied merge (as created by our sync merge) blocks commits.
        let mergeHead = dir + "/.git/MERGE_HEAD"
        let head = try await repos.resolveHead(path: dir)
        TestSupport.write(head + "\n", to: mergeHead)
        await engine.runCommitPipeline(repoPath: dir)
        lock.lock(); let afterMerge = commits.count; lock.unlock()
        XCTAssertEqual(afterMerge, 0, "no commit while MERGE_HEAD exists")
        let dirtyAfterMerge = try await repos.status(path: dir).count
        XCTAssertEqual(dirtyAfterMerge, 1, "the pending file stays uncommitted")

        // Same for a half-applied rebase.
        try? FileManager.default.removeItem(atPath: mergeHead)
        try? FileManager.default.createDirectory(atPath: dir + "/.git/rebase-merge",
                                                 withIntermediateDirectories: true)
        await engine.runCommitPipeline(repoPath: dir)
        lock.lock(); let afterRebase = commits.count; lock.unlock()
        XCTAssertEqual(afterRebase, 0, "no commit while a rebase is half-applied")
        try? FileManager.default.removeItem(atPath: dir + "/.git/rebase-merge")

        // Once no operation is in progress the pipeline commits normally.
        await engine.runCommitPipeline(repoPath: dir)
        lock.lock(); let afterClean = commits.count; lock.unlock()
        XCTAssertEqual(afterClean, 1, "pipeline commits again when the repo is free")
        let dirty = try await repos.status(path: dir).count
        XCTAssertEqual(dirty, 0)
    }
}


/// A crash or force-quit can leave a half-applied rebase/merge behind; the
/// repair action must clear it without touching committed history (v4.1.8).
final class InterruptedOperationRepairTests: XCTestCase {
    private var root = ""
    private var repos: RepoManager!

    override func setUp() async throws {
        root = TestSupport.makeTempDir("repair")
        repos = RepoManager(runner: TestSupport.newRunner())
    }

    override func tearDown() async throws {
        if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }
    }

    private func git(_ args: [String], _ cwd: String) async {
        _ = try? await repos.runner.run(args, cwd: cwd)
    }

    func testRepairCleansLeftoverRebaseAndMerge() async throws {
        let dir = root + "/repo"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        TestSupport.write("seed\n", to: dir + "/seed.md")
        _ = try await repos.ensureRepo(at: dir)
        let base = try await repos.resolveHead(path: dir)

        // A real conflicting rebase leaves .git/rebase-merge behind.
        await git(["checkout", "-b", "other"], dir)
        TestSupport.write("other\n", to: dir + "/seed.md")
        _ = try await repos.commitAll(path: dir, message: "test: other")
        await git(["checkout", "main"], dir)
        TestSupport.write("main\n", to: dir + "/seed.md")
        _ = try await repos.commitAll(path: dir, message: "test: main")
        let mainHead = try await repos.resolveHead(path: dir)
        XCTAssertNotEqual(mainHead, base)
        await git(["rebase", "other"], dir)

        var state = await repos.interruptedOperation(path: dir)
        XCTAssertTrue(state.rebase, "a conflicted rebase must be detected")
        XCTAssertFalse(state.isEmpty)
        let cleanedRebase = try await repos.repairInterruptedOperation(path: dir)
        XCTAssertNotNil(cleanedRebase, "the leftover rebase must be cleaned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/.git/rebase-merge"))
        let afterRebaseRepair = try await repos.resolveHead(path: dir)
        XCTAssertEqual(afterRebaseRepair, mainHead, "aborting must restore the original HEAD")
        let dirtyAfterRebase = try await repos.status(path: dir).count
        XCTAssertEqual(dirtyAfterRebase, 0)

        // A real conflicting merge leaves MERGE_HEAD behind.
        await git(["merge", "other"], dir)
        state = await repos.interruptedOperation(path: dir)
        XCTAssertTrue(state.merge, "a conflicted merge must be detected")
        let cleanedMerge = try await repos.repairInterruptedOperation(path: dir)
        XCTAssertNotNil(cleanedMerge, "the leftover merge must be cleaned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/.git/MERGE_HEAD"))
        let afterMergeRepair = try await repos.resolveHead(path: dir)
        XCTAssertEqual(afterMergeRepair, mainHead)
    }


    func testRepairRemovesStaleIndexLockButKeepsFreshOne() async throws {
        let dir = root + "/locked"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        TestSupport.write("seed\n", to: dir + "/seed.md")
        _ = try await repos.ensureRepo(at: dir)
        let lock = dir + "/.git/index.lock"
        TestSupport.write("", to: lock)

        // A fresh lock may belong to a live git command: never touch it.
        let freshCleaned = try await repos.repairInterruptedOperation(path: dir)
        XCTAssertNil(freshCleaned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock))

        // A 10-minute-old lock is crash leftover: detect and remove it.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)],
                                              ofItemAtPath: lock)
        let state = await repos.interruptedOperation(path: dir)
        XCTAssertTrue(state.staleLock)
        XCTAssertFalse(state.isEmpty)
        let cleaned = try await repos.repairInterruptedOperation(path: dir)
        XCTAssertNotNil(cleaned, "the stale lock must be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock))
        let after = await repos.interruptedOperation(path: dir)
        XCTAssertTrue(after.isEmpty)
    }
    func testRepairIsNoOpWhenNothingPending() async throws {
        let dir = root + "/clean"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        TestSupport.write("seed\n", to: dir + "/seed.md")
        _ = try await repos.ensureRepo(at: dir)
        let head = try await repos.resolveHead(path: dir)
        let state = await repos.interruptedOperation(path: dir)
        XCTAssertTrue(state.isEmpty)
        let cleaned = try await repos.repairInterruptedOperation(path: dir)
        XCTAssertNil(cleaned)
        let headAfter = try await repos.resolveHead(path: dir)
        XCTAssertEqual(headAfter, head)
    }
}
