import Foundation

/// Extra history capabilities (v4.0.5): per-file diffs, commit comparison,
/// history content search, tags, backup refs, snapshot export, integrity
/// checks, blame, folder restore, submodule and LFS detection.
///
/// Kept separate from HistoryService so the core browsing API stays small.
public struct FileDiff: Equatable, Sendable {
    /// Unified diff text (empty when the file did not change).
    public let text: String
    public let isBinary: Bool
    public let truncated: Bool
    public let added: Int
    public let removed: Int

    public init(text: String, isBinary: Bool, truncated: Bool, added: Int, removed: Int) {
        self.text = text
        self.isBinary = isBinary
        self.truncated = truncated
        self.added = added
        self.removed = removed
    }

    public var isEmpty: Bool { text.isEmpty && !isBinary }
}

/// +N −M line counts for one changed file.
public struct FileChangeStat: Equatable, Sendable {
    public let path: String
    public let added: Int
    public let removed: Int
    public let isBinary: Bool

    public init(path: String, added: Int, removed: Int, isBinary: Bool) {
        self.path = path
        self.added = added
        self.removed = removed
        self.isBinary = isBinary
    }

    public var summary: String {
        if isBinary { return NSLocalizedString("二进制", comment: "diff stat") }
        return "+" + String(added) + " −" + String(removed)
    }
}

/// One file in a two-commit comparison.
public struct ComparedFile: Identifiable, Equatable, Sendable {
    public let path: String
    public let status: String
    public let added: Int
    public let removed: Int
    public let isBinary: Bool

    public var id: String { path }
    public var statusCharacter: String { status.isEmpty ? "?" : String(status.prefix(1)) }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, status: String, added: Int, removed: Int, isBinary: Bool) {
        self.path = path
        self.status = status
        self.added = added
        self.removed = removed
        self.isBinary = isBinary
    }
}

/// A named version (git tag).
public struct TagInfo: Identifiable, Equatable, Sendable {
    public let name: String
    public let hash: String
    public let date: Date?
    public let subject: String

    public var id: String { name }

    public init(name: String, hash: String, date: Date?, subject: String) {
        self.name = name
        self.hash = hash
        self.date = date
        self.subject = subject
    }
}

/// One pre-rollback snapshot kept in refs/filevault/backup.
public struct BackupSnapshot: Identifiable, Equatable, Sendable {
    public let refName: String
    public let stamp: String
    public let hash: String
    public let date: Date?
    public let subject: String

    public var id: String { refName }
    public var shortHash: String { String(hash.prefix(7)) }

    public init(refName: String, stamp: String, hash: String, date: Date?, subject: String) {
        self.refName = refName
        self.stamp = stamp
        self.hash = hash
        self.date = date
        self.subject = subject
    }
}

/// One line of git blame output.
public struct BlameLine: Identifiable, Equatable, Sendable {
    public let id: Int
    public let hash: String
    public let author: String
    public let date: Date?
    public let text: String

    public var shortHash: String { String(hash.prefix(7)) }

    public init(id: Int, hash: String, author: String, date: Date?, text: String) {
        self.id = id
        self.hash = hash
        self.author = author
        self.date = date
        self.text = text
    }
}

/// Result of git fsck.
public struct FsckReport: Equatable, Sendable {
    public let ok: Bool
    public let issues: [String]
    public let danglingCount: Int

    public init(ok: Bool, issues: [String], danglingCount: Int) {
        self.ok = ok
        self.issues = issues
        self.danglingCount = danglingCount
    }

    public var summary: String {
        if ok {
            return String(format: NSLocalizedString("仓库完好（%d 个悬空对象）", comment: "fsck"),
                          danglingCount)
        }
        return String(format: NSLocalizedString("发现 %d 个问题", comment: "fsck"), issues.count)
    }
}

/// A gitlink entry (nested repository recorded by a commit).
public struct SubmoduleEntry: Equatable, Sendable {
    public let path: String
    public let hash: String

    public var shortHash: String { String(hash.prefix(7)) }

    public init(path: String, hash: String) {
        self.path = path
        self.hash = hash
    }
}

/// Detects a Git LFS pointer file (the real content lives on the LFS server).
public enum GitLFSPointer {
    public static let header = "version https://git-lfs.github.com/spec/v1"

    public static func isPointer(_ text: String) -> Bool {
        text.hasPrefix(header)
    }
}

public extension HistoryService {
    // MARK: - Diffs

    /// Unified diff of one file inside a commit (vs its parent; root-safe).
    func diff(repoPath: String, hash: String, file: String,
              maxBytes: Int = 200_000) async throws -> FileDiff {
        try RepoManager.validateRepoRelativePath(file)
        try Self.requireHash(hash, error: HistoryError.commitNotFound(hash))
        let r = try await repoManager.runner.run(
            ["show", "--format=", "--no-color", "--no-ext-diff", "--unified=3", hash, "--", file],
            cwd: repoPath
        )
        guard r.succeeded else {
            throw GitCommandError(command: "show --patch", exitCode: r.exitCode, stderr: r.stderr)
        }
        return Self.makeDiff(r.stdout, maxBytes: maxBytes)
    }

    /// Unified diff of one file between two arbitrary commits.
    func diff(repoPath: String, from: String, to: String, file: String,
              maxBytes: Int = 200_000) async throws -> FileDiff {
        try RepoManager.validateRepoRelativePath(file)
        try Self.requireHash(from, error: HistoryError.commitNotFound(from))
        try Self.requireHash(to, error: HistoryError.commitNotFound(to))
        let r = try await repoManager.runner.run(
            ["diff", "--no-color", "--no-ext-diff", "--unified=3", from, to, "--", file],
            cwd: repoPath
        )
        guard r.succeeded else {
            throw GitCommandError(command: "diff", exitCode: r.exitCode, stderr: r.stderr)
        }
        return Self.makeDiff(r.stdout, maxBytes: maxBytes)
    }

    /// Per-file +N −M stats for one commit (path -> stat).
    func changeStats(repoPath: String, hash: String) async throws -> [String: FileChangeStat] {
        try Self.requireHash(hash, error: HistoryError.commitNotFound(hash))
        let r = try await repoManager.runner.run(
            ["diff-tree", "--no-commit-id", "-r", "--root", "--numstat",
             "--diff-merges=first-parent", "-z", hash],
            cwd: repoPath
        )
        guard r.succeeded else {
            throw GitCommandError(command: "diff-tree --numstat", exitCode: r.exitCode, stderr: r.stderr)
        }
        var stats: [String: FileChangeStat] = [:]
        for record in r.stdout.split(separator: "\u{0}", omittingEmptySubsequences: true) {
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let path = String(parts[2])
            guard !path.isEmpty else { continue }
            let binary = parts[0] == "-"
            stats[path] = FileChangeStat(path: path,
                                         added: binary ? 0 : (Int(parts[0]) ?? 0),
                                         removed: binary ? 0 : (Int(parts[1]) ?? 0),
                                         isBinary: binary)
        }
        return stats
    }

    /// Files that differ between two commits, with status and line counts.
    func compare(repoPath: String, from: String, to: String) async throws -> [ComparedFile] {
        try Self.requireHash(from, error: HistoryError.commitNotFound(from))
        try Self.requireHash(to, error: HistoryError.commitNotFound(to))
        // -z keeps names with tabs/newlines/quotes intact; without it a single
        // odd filename produced bogus rows and a truncated path (v4.2.25).
        let names = try await repoManager.runner.run(
            ["diff", "--name-status", "-z", "--no-renames", from, to],
            cwd: repoPath
        )
        guard names.succeeded else {
            throw GitCommandError(command: "diff --name-status", exitCode: names.exitCode, stderr: names.stderr)
        }
        var stats: [String: (Int, Int, Bool)] = [:]
        let nums = try await repoManager.runner.run(
            ["diff", "--numstat", "--no-renames", "-z", from, to],
            cwd: repoPath
        )
        if nums.succeeded {
            for record in nums.stdout.split(separator: "\u{0}", omittingEmptySubsequences: true) {
                let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { continue }
                let path = String(parts[2])
                let binary = parts[0] == "-"
                stats[path] = (binary ? 0 : (Int(parts[0]) ?? 0),
                               binary ? 0 : (Int(parts[1]) ?? 0),
                               binary)
            }
        }
        var result: [ComparedFile] = []
        // --no-renames: every record is "STATUS\0PATH\0".
        let tokens = names.stdout.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index + 1 < tokens.count {
            let status = tokens[index]
            let path = tokens[index + 1]
            index += 2
            guard !path.isEmpty else { continue }
            let s = stats[path] ?? (0, 0, false)
            result.append(ComparedFile(path: path, status: status,
                                       added: s.0, removed: s.1, isBinary: s.2))
        }
        return result
    }

    // MARK: - Blame

    /// Line-by-line attribution of one file at a commit.
    func blame(repoPath: String, hash: String, file: String,
               limit: Int = 5_000) async throws -> [BlameLine] {
        try RepoManager.validateRepoRelativePath(file)
        try Self.requireHash(hash, error: HistoryError.commitNotFound(hash))
        let r = try await repoManager.runner.run(
            ["blame", "--line-porcelain", hash, "--", file],
            cwd: repoPath
        )
        guard r.succeeded else {
            throw GitCommandError(command: "blame", exitCode: r.exitCode, stderr: r.stderr)
        }
        var lines: [BlameLine] = []
        var currentHash = ""
        var currentAuthor = ""
        var currentDate: Date?
        for raw in r.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("\t") {
                guard !currentHash.isEmpty else { continue }
                lines.append(BlameLine(id: lines.count, hash: currentHash,
                                       author: currentAuthor, date: currentDate,
                                       text: String(line.dropFirst())))
                if lines.count >= limit { break }
                continue
            }
            if line.hasPrefix("author ") {
                currentAuthor = String(line.dropFirst(7))
                continue
            }
            if line.hasPrefix("author-time ") {
                if let seconds = TimeInterval(line.dropFirst(12)) {
                    currentDate = Date(timeIntervalSince1970: seconds)
                }
                continue
            }
            let parts = line.split(separator: " ")
            if parts.count >= 3, parts[0].count == 40,
               parts[0].allSatisfy({ $0.isHexDigit }) {
                currentHash = String(parts[0])
            }
        }
        return lines
    }

    // MARK: - Tags (named versions)

    func tags(repoPath: String) async throws -> [TagInfo] {
        let r = try await repoManager.runner.run(
            ["tag", "--list", "--sort=-creatordate",
             "--format=%(refname:short)%00%(creatordate:iso8601)%00%(subject)"],
            cwd: repoPath
        )
        guard r.succeeded else {
            throw GitCommandError(command: "tag --list", exitCode: r.exitCode, stderr: r.stderr)
        }
        var result: [TagInfo] = []
        for line in r.stdout.split(separator: "\n") {
            let parts = line.components(separatedBy: "\u{0}")
            guard let name = parts.first, !name.isEmpty else { continue }
            let date = parts.count > 1 ? Self.parseGitDate(parts[1]) : nil
            let subject = parts.count > 2 ? parts[2] : ""
            let rev = try await repoManager.runner.run(["rev-parse", name + "^{commit}"], cwd: repoPath)
            guard rev.succeeded else { continue }
            let hash = rev.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hash.isEmpty else { continue }
            result.append(TagInfo(name: name, hash: hash, date: date, subject: subject))
        }
        return result
    }

    /// Name a version. Annotated tags keep the message in git itself.
    func createTag(repoPath: String, name: String, hash: String,
                   message: String? = nil) async throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\")
        guard !clean.isEmpty, !clean.hasPrefix("-"), !clean.hasSuffix("."),
              !clean.contains(".."), clean.rangeOfCharacter(from: forbidden) == nil else {
            throw HistoryError.invalidTagName(name)
        }
        let check = try await repoManager.runner.run(["check-ref-format", "refs/tags/" + clean], cwd: repoPath)
        guard check.succeeded else { throw HistoryError.invalidTagName(name) }
        try Self.requireHash(hash, error: HistoryError.commitNotFound(hash))
        let note = (message?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? clean
        let r = try await repoManager.runner.run(
            ["tag", "-a", clean, hash, "-m", note],
            cwd: repoPath
        )
        guard r.succeeded else {
            throw GitCommandError(command: "tag -a", exitCode: r.exitCode, stderr: r.stderr)
        }
    }

    func deleteTag(repoPath: String, name: String) async throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.hasPrefix("-") else { throw HistoryError.invalidTagName(name) }
        let r = try await repoManager.runner.run(["tag", "-d", clean], cwd: repoPath)
        guard r.succeeded else {
            throw GitCommandError(command: "tag -d", exitCode: r.exitCode, stderr: r.stderr)
        }
    }

    // MARK: - Backup refs (recover a mistaken rollback)

    func backups(repoPath: String) async throws -> [BackupSnapshot] {
        let r = try await repoManager.runner.run(
            ["for-each-ref", "refs/filevault/backup", "--sort=-creatordate",
             "--format=%(refname)%00%(objectname)%00%(creatordate:iso8601)%00%(subject)"],
            cwd: repoPath
        )
        guard r.succeeded else {
            throw GitCommandError(command: "for-each-ref", exitCode: r.exitCode, stderr: r.stderr)
        }
        var result: [BackupSnapshot] = []
        for line in r.stdout.split(separator: "\n") {
            let parts = line.components(separatedBy: "\u{0}")
            guard parts.count >= 2, !parts[0].isEmpty else { continue }
            let refName = parts[0]
            let hash = parts[1]
            let stamp = refName.split(separator: "/").last.map(String.init) ?? refName
            let date = parts.count > 2 ? Self.parseGitDate(parts[2]) : nil
            let subject = parts.count > 3 ? parts[3] : ""
            result.append(BackupSnapshot(refName: refName, stamp: stamp, hash: hash,
                                         date: date, subject: subject))
        }
        return result
    }

    // MARK: - Export / integrity

    /// Write a zip of the complete snapshot at a commit.
    func exportSnapshot(repoPath: String, hash: String, to destination: URL) async throws {
        try Self.requireHash(hash, error: HistoryError.commitNotFound(hash))
        let fm = FileManager.default
        try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        let r = try await repoManager.runner.run(
            ["archive", "--format=zip", "-o", destination.path, hash],
            cwd: repoPath
        )
        guard r.succeeded, fm.fileExists(atPath: destination.path) else {
            try? fm.removeItem(at: destination)
            throw HistoryError.exportFailed(file: hash)
        }
    }

    /// Full consistency check (git fsck). Read-only.
    func fsck(repoPath: String) async throws -> FsckReport {
        let r = try await repoManager.runner.run(
            ["fsck", "--full", "--no-progress"],
            cwd: repoPath,
            timeout: 180
        )
        let combined = r.stdout + "\n" + r.stderr
        let lines = combined.split(separator: "\n").map(String.init)
        let dangling = lines.filter { $0.hasPrefix("dangling ") }.count
        let issues = lines.filter {
            $0.contains("error:") || $0.contains("missing") || $0.contains("broken") || $0.contains("fatal:")
        }
        return FsckReport(ok: r.exitCode == 0, issues: Array(issues.prefix(20)), danglingCount: dangling)
    }

    /// Files under `dir` that are not in the index at all (untracked AND
    /// ignored): a folder removal would delete them (v4.2.16).
    private func untrackedFiles(under dir: String, repoPath: String) async throws -> [String] {
        var paths: [String] = []
        for extra in [[], ["--ignored", "--exclude-standard"]] {
            let args = ["ls-files", "--others", "-z"] + extra + ["--", dir]
            let r = try await repoManager.runner.run(args, cwd: repoPath)
            // Fail closed: a failed listing means "unknown", not "nothing in
            // the way" — the folder removal below would silently delete
            // content that exists in no commit (v4.2.27).
            guard r.succeeded else {
                throw GitCommandError(command: "ls-files --others", exitCode: r.exitCode, stderr: r.stderr)
            }
            paths += r.stdout.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
        }
        return Array(Set(paths)).sorted()
    }

    // MARK: - Folder restore

    /// Restore one folder (not just one file) to its state at a commit.
    ///
    /// A plain checkout only rewrites paths that exist in the target; files
    /// added since would survive. Those are removed first so the folder really
    /// matches the version. If the folder did not exist then, it is removed.
    @discardableResult
    func restoreDirectory(repoPath: String, directory: String, to hash: String) async throws -> String {
        let dir = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !dir.isEmpty else { throw HistoryError.invalidPath(directory) }
        try RepoManager.validateRepoRelativePath(dir)
        try Self.requireHash(hash, error: HistoryError.commitNotFound(hash))
        // restoreFile/resetRepo verify the object exists; restoreDirectory was
        // the one entry that skipped this check, so a well-formed but
        // nonexistent hash fell into the "folder absent at that version"
        // branch and DELETED the folder instead of erroring (v4.2.27).
        let verify = try await repoManager.runner.run(["rev-parse", "--verify", "\(hash)^{commit}"], cwd: repoPath)
        guard verify.succeeded else { throw HistoryError.commitNotFound(hash) }
        // Same exclusion rules as single-file restore/reset: no concurrent
        // rebase and no concurrent auto-commit while the working tree is being
        // rewritten (v4.2.26).
        try await repoManager.acquireRemoteOp(repoPath)
        defer { repoManager.releaseRemoteOp(repoPath) }
        try await repoManager.acquireLocalOp(repoPath)
        defer { repoManager.releaseLocalOp(repoPath) }
        guard !(await repoManager.operationInProgress(path: repoPath)) else {
            throw HistoryError.repositoryBusy
        }

        // Never lose pending edits; a failed status means unknown, not clean.
        let dirty = try await repoManager.status(path: repoPath)
        if !dirty.isEmpty {
            _ = try await repoManager.commitAll(path: repoPath, message: "backup: 恢复文件夹前自动保存未提交改动")
        }

        let exists = try await repoManager.runner.run(["cat-file", "-e", hash + ":" + dir], cwd: repoPath)
        if exists.succeeded {
            // Files present in HEAD but absent from the target must go. Rename
            // detection is disabled on purpose: with it, "a.txt -> b.txt" hides
            // b.txt from --diff-filter=D and the rollback leaves it behind
            // (v4.2.25). -z keeps names with quotes/newlines usable.
            let deleted = try await repoManager.runner.run(
                ["diff", "--name-only", "-z", "--no-renames", "--diff-filter=D", "HEAD", hash, "--", dir],
                cwd: repoPath
            )
            // A failed diff must not be skipped silently: files added since the
            // target version would survive while the UI says the folder was
            // restored (v4.2.26).
            guard deleted.succeeded else {
                throw GitCommandError(command: "diff --name-only",
                                      exitCode: deleted.exitCode, stderr: deleted.stderr)
            }
            // The "folder exists at that version" branch needs the same
            // ignored-file guardrail as resetRepo/restoreFile: checkout rewrites
            // every tracked-in-target path, so an ignored/untracked file sitting
            // there (a .env, a credential file) would be silently replaced by
            // content from the target commit — and that content is in NO commit,
            // so no backup ref could bring it back (v4.2.27). Checked BEFORE the
            // rm below so a refusal leaves the working tree untouched.
            let tree = try await repoManager.runner.run(
                ["ls-tree", "-r", "--name-only", "-z", hash, "--", dir], cwd: repoPath)
            guard tree.succeeded else {
                throw GitCommandError(command: "ls-tree", exitCode: tree.exitCode, stderr: tree.stderr)
            }
            let targets = tree.stdout.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
            let conflicts = try await repoManager.ignoredConflicts(targetPaths: targets, path: repoPath)
            if !conflicts.isEmpty {
                throw HistoryError.rollbackWouldOverwriteIgnored(files: conflicts)
            }
            let paths = deleted.stdout.split(separator: "\u{0}").map(String.init).filter { !$0.isEmpty }
            if !paths.isEmpty {
                let rm = try await repoManager.runner.run(["rm", "-f", "--"] + paths, cwd: repoPath)
                guard rm.succeeded else {
                    throw HistoryError.restoreFailed(stderr: rm.stderr)
                }
            }
            let checkout = try await repoManager.runner.run(["checkout", hash, "--", dir], cwd: repoPath)
            guard checkout.succeeded else {
                // The target tree may exist but checkout can still fail (an
                // untracked file in the way, unreadable file): report the real
                // git reason instead of claiming the version lacks the folder.
                throw HistoryError.restoreFailed(stderr: checkout.stderr)
            }
        } else {
            // The folder did not exist at that version: remove it entirely.
            // Removing it would also take files that are NOT backed up (ignored
            // or never committed, e.g. a .env); refuse instead of losing them.
            let untracked = try await untrackedFiles(under: dir, repoPath: repoPath)
            if !untracked.isEmpty {
                throw HistoryError.rollbackWouldDeleteUntracked(directory: dir, files: untracked)
            }
            _ = try await repoManager.runner.run(["rm", "-r", "-f", "--ignore-unmatch", "--", dir], cwd: repoPath)
            let full = (repoPath as NSString).appendingPathComponent(dir)
            try? FileManager.default.removeItem(atPath: full)
        }
        return try await repoManager.commitAll(
            path: repoPath,
            message: String(format: NSLocalizedString("rollback: 恢复文件夹 %@ 到 %@", comment: "commit message"),
                            dir, String(hash.prefix(7)))
        )
    }

    // MARK: - Content search across history

    /// Commits whose diff changed the number of occurrences of a string
    /// (git log -S). Matches inside file CONTENT, not commit messages.
    func searchHistory(repoPath: String, query: String, limit: Int = 100) async throws -> [CommitInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let r = try await repoManager.runner.run(
            ["log", "-S" + q, "--pretty=format:%H%x00%h%x00%s%x00%aI", "-n", String(limit)],
            cwd: repoPath
        )
        guard r.succeeded else {
            throw GitCommandError(command: "log -S", exitCode: r.exitCode, stderr: r.stderr)
        }
        return r.stdout.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\u{0}")
            guard parts.count == 4, !parts[0].isEmpty, !parts[3].isEmpty else { return nil }
            let date = Self.parseGitDate(parts[3]) ?? Date(timeIntervalSince1970: 0)
            return CommitInfo(hash: parts[0], shortHash: parts[1], subject: parts[2], date: date)
        }
    }

    // MARK: - Submodules

    /// If the path at this commit is a gitlink, return the recorded commit.
    func submoduleEntry(repoPath: String, hash: String, path: String) async throws -> SubmoduleEntry? {
        try RepoManager.validateRepoRelativePath(path)
        let r = try await repoManager.runner.run(["ls-tree", hash, "--", path], cwd: repoPath)
        guard r.succeeded else { return nil }
        for line in r.stdout.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let meta = line[line.startIndex..<tab].split(separator: " ")
            guard meta.count >= 3, meta[0] == "160000" else { continue }
            return SubmoduleEntry(path: String(line[line.index(after: tab)...]), hash: String(meta[2]))
        }
        return nil
    }

    // MARK: - Helpers

    private static func requireHash(_ hash: String, error: HistoryError) throws {
        guard hash.range(of: "^[0-9a-fA-F]{4,40}$", options: .regularExpression) != nil else {
            throw error
        }
    }

    static func makeDiff(_ raw: String, maxBytes: Int) -> FileDiff {
        let binary = raw.contains("Binary files") || raw.contains("GIT binary patch")
        var added = 0
        var removed = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
            else if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
        }
        var text = raw
        var truncated = false
        if text.utf8.count > maxBytes {
            var bytes = 0
            var cut = text.startIndex
            for idx in text.indices {
                bytes += String(text[idx]).utf8.count
                if bytes > maxBytes { break }
                cut = text.index(after: idx)
            }
            text = String(text[..<cut])
            truncated = true
        }
        return FileDiff(text: text, isBinary: binary, truncated: truncated, added: added, removed: removed)
    }

    static func parseGitDate(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: raw) { return d }
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return fallback.date(from: raw)
    }
}
