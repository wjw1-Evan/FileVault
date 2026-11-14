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

public extension HistoryService {
    /// Changed files of one commit ("M\ta.md" style lines, FR-09 content view).
    func changedFiles(repoPath: String, hash: String) async throws -> [String] {
        let r = try await repoManager.runner.run(
            ["diff-tree", "--no-commit-id", "--name-status", "-r", "--root", hash],
            cwd: repoPath
        )
        guard r.succeeded else {
            throw GitCommandError(command: "diff-tree", exitCode: r.exitCode, stderr: r.stderr)
        }
        return r.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}

public extension HistoryService {
    /// Version timeline of ONE file: commits that touched it, newest first (v2.2.0).
    func fileHistory(repoPath: String, file: String, limit: Int = 100) async throws -> [CommitInfo] {
        let r = try await repoManager.runner.run(
            ["log", "--follow", "--pretty=format:%H|%h|%s|%aI", "-n", String(limit), "--", file],
            cwd: repoPath
        )
        guard r.succeeded else {
            throw GitCommandError(command: "log --follow", exitCode: r.exitCode, stderr: r.stderr)
        }
        return r.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            let f = ISO8601DateFormatter()
            let d = f.date(from: String(parts[3])) ?? Date(timeIntervalSince1970: 0)
            return CommitInfo(hash: String(parts[0]), shortHash: String(parts[1]),
                              subject: String(parts[2]), date: d)
        }
    }
}
