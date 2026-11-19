import XCTest
@testable import FileVaultCore

/// v4.2.31: GitHub answers an oversized blob with the SAME summary line as a
/// branch-protection refusal ("! [remote rejected] … (pre-receive hook
/// declined)"). The size wording must therefore be classified FIRST — the old
/// order reported a file-size problem as "adjust branch protection" and the
/// size guidance was unreachable for real GitHub output.
final class PushRejectionClassificationTests: XCTestCase {
    /// Verbatim shape of a real GitHub size rejection (per-blob message +
    /// GH001 + the generic rejection summary line).
    private let oversizedStderr = """
    remote: error: File big.bin is 212.94 MiB; this exceeds GitHub's file size limit of 100.00 MiB
    remote: error: GH001: Large files detected. You may want to try Git Large File Storage - https://git-lfs.github.com.
    To github.com:user/repo.git
     ! [remote rejected] HEAD -> main (pre-receive hook declined)
    error: failed to push some refs to 'github.com:user/repo.git'
    """

    private let protectedStderr = """
    remote: error: GH006: Protected branch update failed for refs/heads/main.
    remote: error: Cannot force-push to a protected branch.
    To github.com:user/repo.git
     ! [remote rejected] HEAD -> main (protected branch hook declined)
    error: failed to push some refs to 'github.com:user/repo.git'
    """

    func testGitHubSizeRejectionIsNotReportedAsBranchProtection() throws {
        let message = SyncManager.deterministicPushRejection(
            GitCommandError(command: "push origin", exitCode: 1, stderr: oversizedStderr))
        let text = try XCTUnwrap(message)
        XCTAssertTrue(text.contains("文件过大"),
                      "a size rejection must name the real reason, got: \(text)")
        XCTAssertTrue(text.contains("big.bin"),
                      "the oversized file must be named, got: \(text)")
        XCTAssertFalse(text.contains("分支保护"),
                      "size rejections must not send the user to branch-protection settings, got: \(text)")
    }

    func testBranchProtectionRejectionStillReportedAsProtection() throws {
        let message = SyncManager.deterministicPushRejection(
            GitCommandError(command: "push origin", exitCode: 1, stderr: protectedStderr))
        let text = try XCTUnwrap(message)
        XCTAssertTrue(text.contains("分支保护"), "got: \(text)")
        XCTAssertFalse(text.contains("文件过大"), "got: \(text)")
    }

    func testOversizedFileNamesAreExtractedFromGitHubOutput() {
        let names = SyncManager.oversizedFiles(in: oversizedStderr)
        XCTAssertEqual(names, ["big.bin"])
    }

    func testOrdinaryNetworkFailureIsNotDeterministicRejection() {
        let message = SyncManager.deterministicPushRejection(
            GitCommandError(command: "push origin", exitCode: 128,
                             stderr: "fatal: could not read from remote repository."))
        XCTAssertNil(message, "a network failure stays retryable")
    }
}
