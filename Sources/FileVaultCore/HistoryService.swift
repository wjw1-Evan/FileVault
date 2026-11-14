import Foundation

/// History browsing and rollback (FR-09/10).
public final class HistoryService: @unchecked Sendable {
    public let repoManager: RepoManager

    public init(repoManager: RepoManager) {
        self.repoManager = repoManager
    }

    /// Commits of a repo, newest first.
    public func commits(repoPath: String, limit: Int = 50) async throws -> [CommitInfo] {
        try await repoManager.log(path: repoPath, max: limit)
    }

    /// Content of one file at a given commit.
    public func fileContent(repoPath: String, hash: String, file: String) async throws -> String {
        let r = try await repoManager.runner.run(["show", "\(hash):\(file)"], cwd: repoPath)
        guard r.succeeded else {
            throw GitCommandError(command: "show", exitCode: r.exitCode, stderr: r.stderr)
        }
        return r.stdout
    }

    /// Restore one file to a given commit and auto-commit the rollback (FR-10).
    public func restoreFile(repoPath: String, file: String, to hash: String) async throws -> String {
        try await repoManager.restoreFile(path: repoPath, file: file, to: hash)
    }

    /// Reset the whole repo to a given commit (FR-10, needs confirm in UI).
    public func resetRepo(repoPath: String, to hash: String) async throws {
        try await repoManager.resetRepo(path: repoPath, to: hash)
    }
}
