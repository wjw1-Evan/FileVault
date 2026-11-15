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
        try RepoManager.validateRepoRelativePath(file)
        guard hash.range(of: "^[0-9a-fA-F]{4,40}$", options: .regularExpression) != nil else {
            throw HistoryError.commitNotFound(hash)
        }
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
    /// NUL-separated fields — see RepoManager.log (subject may contain "|").
    func fileHistory(repoPath: String, file: String, limit: Int = 100) async throws -> [CommitInfo] {
        let r = try await repoManager.runner.run(
            ["log", "--follow", "--pretty=format:%H%x00%h%x00%s%x00%aI", "-n", String(limit), "--", file],
            cwd: repoPath
        )
        guard r.succeeded else {
            throw GitCommandError(command: "log --follow", exitCode: r.exitCode, stderr: r.stderr)
        }
        return r.stdout.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\u{0}")
            guard parts.count == 4, !parts[0].isEmpty, !parts[3].isEmpty else { return nil }
            let f = ISO8601DateFormatter()
            let d = f.date(from: parts[3]) ?? Date(timeIntervalSince1970: 0)
            return CommitInfo(hash: parts[0], shortHash: parts[1], subject: parts[2], date: d)
        }
    }
}

public extension HistoryService {
    /// Write the file's content at `hash` to `destination` (binary-safe).
    ///
    /// v3.4.3: the history window can "open" a historical version of a file.
    /// `GitRunner` captures stdout as text (fine for diffs, lossy for images or
    /// PDFs), so the blob is streamed straight into a file handle here.
    func exportFile(repoPath: String, hash: String, file: String, to destination: URL) async throws {
        try RepoManager.validateRepoRelativePath(file)
        guard hash.range(of: "^[0-9a-fA-F]{4,40}$", options: .regularExpression) != nil else {
            throw HistoryError.commitNotFound(hash)
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination) else {
            throw HistoryError.exportFailed(file: file)
        }
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: repoManager.runner.gitExecutable)
        process.arguments = ["-C", repoPath, "show", "\(hash):\(file)"]
        process.standardOutput = handle
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw HistoryError.exportFailed(file: file)
        }
        process.waitUntilExit()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            try? fm.removeItem(at: destination)
            let detail = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw detail.isEmpty
                ? HistoryError.fileNotInCommit(file: file, hash: String(hash.prefix(7)))
                : HistoryError.exportFailed(file: file)
        }
    }
}

