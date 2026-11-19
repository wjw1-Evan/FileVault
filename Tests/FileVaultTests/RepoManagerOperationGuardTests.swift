import XCTest
@testable import FileVaultCore

/// RepoManager's operation guards and gitignore editor errors — the paths the
/// coverage report called out (local/remoteOperationInProgress 0%,
/// GitignoreError.errorDescription 0%).
final class RepoManagerOperationGuardTests: XCTestCase {

    /// Thread-safe completion flag (this toolchain's Task has no isCompleted —
    /// same helper shape as SyncPushGenerationTests).
    private final class Done: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    func testLocalOperationSlotDiscipline() async throws {
        let repos = RepoManager(runner: TestSupport.newRunner())
        let repo = "/vault/work"
        XCTAssertFalse(repos.localOperationInProgress(path: repo))

        try await repos.acquireLocalOp(repo)
        XCTAssertTrue(repos.localOperationInProgress(path: repo),
                      "a restore/rollback in flight is visible to the UI")

        // A second mutation must wait: the slot is exclusive per repo.
        let acquired = Done()
        let second = Task.detached {
            try await repos.acquireLocalOp(repo)
            acquired.set()
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(acquired.isSet, "the slot is exclusive while held")

        repos.releaseLocalOp(repo)
        try await second.value
        // The waiting task now OWNS the slot; hand it back before probing.
        repos.releaseLocalOp(repo)
        XCTAssertFalse(repos.localOperationInProgress(path: repo))

        // Released slots are immediately reusable.
        try await repos.acquireLocalOp(repo)
        repos.releaseLocalOp(repo)
    }

    func testRemoteOperationSlotDiscipline() async throws {
        let repos = RepoManager(runner: TestSupport.newRunner())
        let repo = "/vault/work"
        XCTAssertFalse(repos.remoteOperationInProgress(path: repo))

        try await repos.acquireRemoteOp(repo)
        XCTAssertTrue(repos.remoteOperationInProgress(path: repo))
        let acquired = Done()
        let second = Task.detached {
            try await repos.acquireRemoteOp(repo)
            acquired.set()
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(acquired.isSet, "the remote slot is exclusive while held")
        repos.releaseRemoteOp(repo)
        try await second.value
        // The waiting task now OWNS the slot; hand it back before probing.
        repos.releaseRemoteOp(repo)
        XCTAssertFalse(repos.remoteOperationInProgress(path: repo))
    }

    /// A failing network git command comes back as a RESULT for classification;
    /// the throw path is reserved for transport errors (v4.1.7: a timeout is
    /// reported as a readable network error, not a bare failure).
    func testUnreachableRemoteSurfacesAsClassifiedPullError() async throws {
        let base = TestSupport.makeTempDir("opguard")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/repo"
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        TestSupport.write("seed", to: repoPath + "/seed.txt")
        let repos = RepoManager(runner: TestSupport.newRunner())
        _ = try await repos.ensureRepo(at: repoPath)
        _ = try? await SyncManager(repoManager: repos).configureRemote(
            repoPath: repoPath, url: base + "/absent.git", autoPush: false)

        do {
            _ = try await repos.mergeSync(path: repoPath)
            XCTFail("a fetch from an unreachable path must fail")
        } catch let error as PullError {
            XCTAssertNotEqual(error, PullError.networkFailed(detail: ""),
                              "a failing command is classified, not reported as transport loss")
        } catch {
            XCTFail("expected a classified PullError, got \(error)")
        }
    }

    // MARK: - .gitignore editor errors (readable, never silent)

    func testReadGitignoreEmptyWhenAbsentAndRoundtripWhenPresent() throws {
        let base = TestSupport.makeTempDir("ignore-ok")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repos = RepoManager(runner: TestSupport.newRunner())
        XCTAssertEqual(try repos.readGitignore(path: base), "",
                       "no .gitignore yet is an empty draft, not an error")
        try repos.saveGitignore(path: base, content: ".DS_Store\nnode_modules/\n")
        XCTAssertEqual(try repos.readGitignore(path: base), ".DS_Store\nnode_modules/\n")
    }

    /// v4.2.26: a non-UTF-8 .gitignore must refuse to open instead of showing
    /// an empty draft that would overwrite the user's real rules on save.
    func testReadGitignoreRefusesNonUTF8File() throws {
        let base = TestSupport.makeTempDir("ignore-utf8")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let file = base + "/.gitignore"
        FileManager.default.createFile(atPath: file, contents: Data([0xFF, 0xFE, 0x00]))
        let repos = RepoManager(runner: TestSupport.newRunner())
        XCTAssertThrowsError(try repos.readGitignore(path: base)) { error in
            guard case RepoManager.GitignoreError.notUTF8(let path) = error else {
                return XCTFail("expected notUTF8, got \(error)")
            }
            XCTAssertTrue(path.hasSuffix(".gitignore"))
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    /// A .gitignore that cannot be read or written (here: it is a directory)
    /// explains itself; the editor keeps the draft open instead of pretending.
    func testGitignoreReadAndWriteFailuresAreReadable() throws {
        let base = TestSupport.makeTempDir("ignore-fail")
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: base + "/.gitignore",
                                                withIntermediateDirectories: true)
        let repos = RepoManager(runner: TestSupport.newRunner())
        XCTAssertThrowsError(try repos.readGitignore(path: base)) { error in
            XCTAssertTrue(error.localizedDescription.contains(".gitignore"),
                           error.localizedDescription)
        }
        XCTAssertThrowsError(try repos.saveGitignore(path: base, content: "x")) { error in
            guard case RepoManager.GitignoreError.writeFailed = error else {
                return XCTFail("expected writeFailed, got \(error)")
            }
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}
