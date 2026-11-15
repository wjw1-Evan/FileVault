import Foundation

/// What the protected folder looks like for one path (v4.1 recovery redesign).
///
/// 「恢复」 only ever means one of two things for a user:
/// - a file was **deleted** and should come back, or
/// - a file was **modified** (or broken) and should go back to an older version.
/// Everything in this file is built around that model: the recovery window lists
/// files by their current state, and restore always takes ONE file to ONE
/// version. Whole-folder rollback stays in the history window.
public enum RecoveryState: String, Equatable, Sendable {
    /// Gone from the folder, but still present in history.
    case deleted
    /// On disk and different from its latest committed version (or paused).
    case modified
    /// On disk and identical to its latest committed version.
    case available

    /// Sort order for the file list: things that need attention first.
    var sortRank: Int {
        switch self {
        case .deleted: return 0
        case .modified: return 1
        case .available: return 2
        }
    }
}

/// One path the recovery window can help with.
public struct RecoverableFile: Identifiable, Equatable, Sendable {
    /// Repo-relative path with "/" separators.
    public let path: String
    public let state: RecoveryState
    /// When the path last changed (commit date). nil when that is older than the scan window.
    public let lastChanged: Date?
    /// Subject of the commit that last changed the path.
    public let lastSubject: String
    /// Abbreviated hash of the commit that last changed the path.
    public let lastShortHash: String
    /// Abbreviated hash of the commit that deleted the file (deleted state only,
    /// and only when the deletion was committed — a folder-level delete that has
    /// not been committed yet has no commit of its own).
    public let deletedIn: String?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir == "." ? "" : dir
    }

    public init(path: String,
                state: RecoveryState,
                lastChanged: Date? = nil,
                lastSubject: String = "",
                lastShortHash: String = "",
                deletedIn: String? = nil) {
        self.path = path
        self.state = state
        self.lastChanged = lastChanged
        self.lastSubject = lastSubject
        self.lastShortHash = lastShortHash
        self.deletedIn = deletedIn
    }
}

/// Result of scanning one folder for recoverable files.
public struct RecoverySnapshot: Equatable, Sendable {
    /// Every path history knows about, sorted deleted → modified → available,
    /// then newest change first, then path.
    public let files: [RecoverableFile]
    /// True when the history scan hit its limit (older deletions may be missing).
    public let truncated: Bool
    /// Number of commits the recent-activity scan looked at.
    public let scannedCommits: Int

    public init(files: [RecoverableFile], truncated: Bool = false, scannedCommits: Int = 0) {
        self.files = files
        self.truncated = truncated
        self.scannedCommits = scannedCommits
    }

    public static let empty = RecoverySnapshot(files: [])

    public var deleted: [RecoverableFile] { files.filter { $0.state == .deleted } }
    public var modified: [RecoverableFile] { files.filter { $0.state == .modified } }
    public var deletedCount: Int { deleted.count }
    public var modifiedCount: Int { modified.count }
}

/// One version of one file: a commit that touched it.
public struct FileVersion: Identifiable, Equatable, Sendable {
    public let hash: String
    public let shortHash: String
    public let subject: String
    public let date: Date
    /// Git name-status inside that commit: A / M / D / R100 / ...
    public let status: String
    /// False when the commit is the one that deleted the file (nothing to restore there).
    public let exists: Bool

    public var id: String { hash }
    public var isDeletion: Bool { !exists }
    public var statusCharacter: String {
        guard let first = status.first else { return "?" }
        return String(first)
    }

    public init(hash: String, shortHash: String, subject: String, date: Date,
                status: String, exists: Bool) {
        self.hash = hash
        self.shortHash = shortHash
        self.subject = subject
        self.date = date
        self.status = status
        self.exists = exists
    }
}

/// Outcome of restoring one file to one version.
public enum RestoreResult: Equatable, Sendable {
    /// A rollback commit was created from that version's content.
    /// recreated is true when the file did not exist on disk before.
    case restored(commit: String, recreated: Bool)
    /// The file on disk already matches that version — nothing was committed.
    case unchanged
}

/// File-level recovery: index a folder, list one file's versions, restore one file.
///
/// Design notes
/// - 「恢复」 is file-first. The history window browses commits; this service
///   answers "which files can I get back right now, and to which version?".
/// - Restore never touches other files: it checks the target blob, backs up any
///   pending edits with a commit, checks out that one path and commits the result.
/// - Scans are bounded (recent commits / deletions) so opening the window stays
///   fast on large folders; the snapshot reports when a limit was hit.
public final class RecoveryService: Sendable {
    public let repoManager: RepoManager
    public let history: HistoryService

    private var runner: GitRunner { repoManager.runner }

    public init(repoManager: RepoManager, history: HistoryService? = nil) {
        self.repoManager = repoManager
        self.history = history ?? HistoryService(repoManager: repoManager)
    }

    // MARK: - Folder index

    /// Scan the folder: files in the latest commit (HEAD), plus files that were
    /// deleted at some point and are still gone.
    ///
    /// - Parameters:
    ///   - recentCommits: how far back "last changed" metadata is collected.
    ///   - deletionCommits: how far back deleted files are searched (deletions
    ///     are rare, so this can look much further than recentCommits).
    public func snapshot(repoPath: String,
                         recentCommits: Int = 500,
                         deletionCommits: Int = 3_000) async throws -> RecoverySnapshot {
        let head = try await headEntries(repoPath: repoPath)
        let statuses = (try? await repoManager.status(path: repoPath)) ?? []
        let recent = try await scanLog(repoPath: repoPath, limit: recentCommits)
        let deletions = try await scanLog(repoPath: repoPath, limit: deletionCommits,
                                          deletionsOnly: true)

        var dirtyByPath: [String: StatusEntry.Change] = [:]
        for entry in statuses { dirtyByPath[entry.path] = entry.change }

        // Newest record wins: the log is newest-first.
        var lastByPath: [String: PathRecord] = [:]
        for record in recent.records where lastByPath[record.path] == nil {
            lastByPath[record.path] = record
        }
        var deletedByPath: [String: PathRecord] = [:]
        for record in deletions.records
        where record.status.hasPrefix("D") && deletedByPath[record.path] == nil {
            deletedByPath[record.path] = record
        }

        let fm = FileManager.default
        var files: [RecoverableFile] = []
        var seen = Set<String>()

        for entry in head {
            // Folder markers are an implementation detail, and submodules only
            // record a commit id — neither can be restored as a file here.
            guard !isHiddenMarker(entry.path), entry.mode != "160000" else { continue }
            guard seen.insert(entry.path).inserted else { continue }
            let full = (repoPath as NSString).appendingPathComponent(entry.path)
            let onDisk = fm.fileExists(atPath: full)
            let change = dirtyByPath[entry.path]
            let state: RecoveryState
            if !onDisk || change == .deleted {
                state = .deleted
            } else if change == .modified || change == .renamed || change == .typeChanged {
                state = .modified
            } else {
                state = .available
            }
            let last = lastByPath[entry.path]
            files.append(RecoverableFile(path: entry.path,
                                         state: state,
                                         lastChanged: last?.date,
                                         lastSubject: last?.subject ?? "",
                                         lastShortHash: last?.short ?? ""))
        }

        // Files that were deleted in a commit and never came back.
        let headPaths = Set(head.map(\.path))
        for (path, record) in deletedByPath {
            guard !seen.contains(path), !isHiddenMarker(path), !headPaths.contains(path) else { continue }
            let full = (repoPath as NSString).appendingPathComponent(path)
            guard !fm.fileExists(atPath: full) else { continue }
            seen.insert(path)
            files.append(RecoverableFile(path: path,
                                         state: .deleted,
                                         lastChanged: record.date,
                                         lastSubject: record.subject,
                                         lastShortHash: record.short,
                                         deletedIn: record.short))
        }

        files.sort { lhs, rhs in
            if lhs.state.sortRank != rhs.state.sortRank {
                return lhs.state.sortRank < rhs.state.sortRank
            }
            let l = lhs.lastChanged ?? .distantPast
            let r = rhs.lastChanged ?? .distantPast
            if l != r { return l > r }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }

        let truncated = recent.commitCount >= max(1, recentCommits)
            || deletions.commitCount >= max(1, deletionCommits)
        return RecoverySnapshot(files: files, truncated: truncated, scannedCommits: recent.commitCount)
    }

    // MARK: - One file's versions

    /// Commits that touched the file, newest first, including the commit that
    /// deleted it (marked exists == false) so the UI can show the full story.
    public func versions(repoPath: String, file: String, limit: Int = 100) async throws -> [FileVersion] {
        try RepoManager.validateRepoRelativePath(file)
        let r = try await runner.run(
            ["log", "--follow", "-z", "--name-status",
             "--pretty=format:%x01%H%x01%h%x01%aI%x01%s",
             "-n", String(max(1, limit)), "--", file],
            cwd: repoPath
        )
        guard r.succeeded else {
            if Self.isUnbornError(r.stderr) { return [] }
            throw GitCommandError(command: "log --follow", exitCode: r.exitCode, stderr: r.stderr)
        }
        var seen = Set<String>()
        var result: [FileVersion] = []
        for record in Self.parseLog(r.stdout).records where seen.insert(record.commit).inserted {
            result.append(FileVersion(hash: record.commit,
                                      shortHash: record.short,
                                      subject: record.subject,
                                      date: record.date ?? Date(timeIntervalSince1970: 0),
                                      status: record.status,
                                      exists: !record.status.hasPrefix("D")))
        }
        return result
    }

    /// Newest version that actually contains the file, starting at a revision
    /// (default HEAD). Passing the deletion commit returns the last commit that
    /// still had the file — that is what 「找回」 restores.
    public func lastExistingVersion(repoPath: String, file: String,
                                   from revision: String = "HEAD") async throws -> String? {
        try RepoManager.validateRepoRelativePath(file)
        let r = try await runner.run(
            ["log", "-1", "--format=%H", "--diff-filter=d", revision, "--", file],
            cwd: repoPath
        )
        guard r.succeeded else { return nil }
        let hash = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }

    // MARK: - Restore

    /// Restore one file to its content at a version and commit the rollback.
    ///
    /// Pending edits anywhere in the folder are committed first (as a backup
    /// commit), so nothing on disk is ever lost by the restore.
    public func restore(repoPath: String, file: String, to hash: String) async throws -> RestoreResult {
        try RepoManager.validateRepoRelativePath(file)
        guard hash.range(of: "^[0-9a-fA-F]{4,40}$", options: .regularExpression) != nil else {
            throw HistoryError.commitNotFound(hash)
        }
        let verify = try await runner.run(["rev-parse", "--verify", hash + "^{commit}"], cwd: repoPath)
        guard verify.succeeded else { throw HistoryError.commitNotFound(hash) }
        // Byte-for-byte comparison with the working tree: an identical file
        // must report "nothing to do" instead of creating an empty commit.
        let diff = try await runner.run(["diff", "--quiet", hash, "--", file], cwd: repoPath)
        switch diff.exitCode {
        case 0:
            return .unchanged
        case 1:
            break
        default:
            if diff.stderr.contains("Not a valid object") || diff.stderr.contains("unknown revision") {
                throw HistoryError.commitNotFound(hash)
            }
            throw GitCommandError(command: "diff --quiet", exitCode: diff.exitCode, stderr: diff.stderr)
        }
        let full = (repoPath as NSString).appendingPathComponent(file)
        let wasMissing = !FileManager.default.fileExists(atPath: full)
        do {
            let commit = try await repoManager.restoreFile(path: repoPath, file: file, to: hash)
            guard !commit.isEmpty else { return .unchanged }
            return .restored(commit: commit, recreated: wasMissing)
        } catch let error as GitCommandError {
            throw HistoryError.restoreFailed(stderr: error.stderr)
        }
    }

    /// Recover a file that was deleted by a commit: restores the newest version
    /// that still contained it.
    public func restoreDeleted(repoPath: String, file: String,
                               deletedIn: String) async throws -> RestoreResult {
        guard let target = try await lastExistingVersion(repoPath: repoPath,
                                                        file: file,
                                                        from: deletedIn) else {
            throw HistoryError.fileNotInCommit(file: file, hash: String(deletedIn.prefix(7)))
        }
        return try await restore(repoPath: repoPath, file: file, to: target)
    }

    /// Unified diff between a version and the CURRENT folder content
    /// (this is what "当前 vs 这个版本" shows in the window).
    public func workingDiff(repoPath: String, file: String, version hash: String,
                            maxBytes: Int = 200_000) async throws -> FileDiff {
        try RepoManager.validateRepoRelativePath(file)
        let r = try await runner.run(
            ["diff", "--no-color", "--no-ext-diff", "--unified=3", hash, "--", file],
            cwd: repoPath
        )
        guard r.exitCode <= 1 else {
            throw GitCommandError(command: "diff", exitCode: r.exitCode, stderr: r.stderr)
        }
        return HistoryService.makeDiff(r.stdout, maxBytes: maxBytes)
    }

    // MARK: - Internals

    struct PathRecord: Equatable, Sendable {
        let commit: String
        let short: String
        let date: Date?
        let subject: String
        let status: String
        let path: String
        let originalPath: String?
    }

    struct ParsedLog: Equatable, Sendable {
        var records: [PathRecord] = []
        var commitCount = 0
    }

    private struct HeadEntry: Equatable, Sendable {
        let path: String
        let mode: String
    }

    /// git ls-tree -r -z --full-tree HEAD → every tracked file at HEAD.
    private func headEntries(repoPath: String) async throws -> [HeadEntry] {
        let r = try await runner.run(["ls-tree", "-r", "-z", "--full-tree", "HEAD"], cwd: repoPath)
        guard r.succeeded else {
            if Self.isUnbornError(r.stderr) { return [] }
            throw GitCommandError(command: "ls-tree", exitCode: r.exitCode, stderr: r.stderr)
        }
        var entries: [HeadEntry] = []
        for record in r.stdout.split(separator: "\u{0}", omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let meta = record[record.startIndex..<tab].split(separator: " ")
            let path = String(record[record.index(after: tab)...])
            guard !path.isEmpty, meta.count >= 3 else { continue }
            entries.append(HeadEntry(path: path, mode: String(meta[0])))
        }
        return entries
    }

    private func scanLog(repoPath: String, limit: Int, deletionsOnly: Bool = false) async throws -> ParsedLog {
        var args = ["log", "-z", "--name-status"]
        if deletionsOnly { args.append("--diff-filter=D") }
        args.append(contentsOf: ["--pretty=format:%x01%H%x01%h%x01%aI%x01%s",
                                 "-n", String(max(1, limit)), "--"])
        let r = try await runner.run(args, cwd: repoPath)
        guard r.succeeded else {
            if Self.isUnbornError(r.stderr) { return ParsedLog() }
            throw GitCommandError(command: "log", exitCode: r.exitCode, stderr: r.stderr)
        }
        return Self.parseLog(r.stdout)
    }

    private func isHiddenMarker(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == RepoManager.emptyFolderMarker
    }

    static func isUnbornError(_ stderr: String) -> Bool {
        stderr.contains("does not have any commits yet")
            || stderr.contains("Not a valid object name")
            || stderr.contains("unknown revision")
            || stderr.contains("bad revision")
    }

    /// Parse git log -z --name-status with a NUL-safe pretty header.
    ///
    /// Git's NUL layout is unusual: the header and the FIRST status share a
    /// record (\x01H\x01h\x01date\x01subject\nM), then path, status, path,
    /// … and an empty record closes the commit. Renames carry two paths.
    static func parseLog(_ raw: String) -> ParsedLog {
        var parsed = ParsedLog()
        let tokens = raw.split(separator: "\u{0}", omittingEmptySubsequences: false)
        var commit: (hash: String, short: String, date: Date?, subject: String)?
        var pendingStatus: String?
        var pendingOldPath: String?
        var index = 0
        while index < tokens.count {
            let token = String(tokens[index])
            index += 1
            if token.isEmpty {
                pendingStatus = nil
                pendingOldPath = nil
                continue
            }
            if token.hasPrefix("\u{1}") {
                let parts = token.dropFirst().components(separatedBy: "\u{1}")
                guard parts.count >= 4 else { continue }
                let lines = parts[3].components(separatedBy: "\n")
                commit = (parts[0], parts[1], HistoryService.parseGitDate(parts[2]), lines.first ?? "")
                parsed.commitCount += 1
                pendingStatus = lines.count > 1 ? lines[1] : nil
                pendingOldPath = nil
                continue
            }
            guard let current = commit else { continue }
            if let status = pendingStatus {
                if status.hasPrefix("R") || status.hasPrefix("C") {
                    if pendingOldPath == nil {
                        pendingOldPath = token
                        continue
                    }
                    parsed.records.append(PathRecord(commit: current.hash, short: current.short,
                                                     date: current.date, subject: current.subject,
                                                     status: status, path: token,
                                                     originalPath: pendingOldPath))
                    pendingOldPath = nil
                    pendingStatus = nil
                    continue
                }
                parsed.records.append(PathRecord(commit: current.hash, short: current.short,
                                                 date: current.date, subject: current.subject,
                                                 status: status, path: token, originalPath: nil))
                pendingStatus = nil
                continue
            }
            // No pending status yet: this token is the status of the next file.
            pendingStatus = token
        }
        return parsed
    }
}
