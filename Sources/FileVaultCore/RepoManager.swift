import Foundation

/// Manages the repo that IS a managed root folder: init/adopt, status, commit,
/// remote config, log, rollback.
///
/// v4.0: the managed root is exactly one repository. Everything under it —
/// loose files at the root, nested folders, hidden folders except .git and
/// whatever .gitignore excludes — is versioned together.
public final class RepoManager: @unchecked Sendable {
    public let runner: GitRunner

    public init(runner: GitRunner) {
        self.runner = runner
    }

    // MARK: - Prepare

    /// Whether the path already is a Git repository (a .git entry exists).
    /// A .git *file* counts too (worktrees / linked checkouts).
    public func isRepo(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    /// Prepare the managed root itself as ONE repo: adopt an existing .git
    /// untouched, otherwise git init + identity + initial commit (FR-03).
    @discardableResult
    public func ensureRepo(at path: String) async throws -> RepoSetupResult {
        if isRepo(at: path) {
            return RepoSetupResult(created: false, adopted: true)
        }
        try await createRepo(at: path)
        return RepoSetupResult(created: true, adopted: false)
    }

    /// Create a new repo in an existing folder: init + gitignore + identity + initial commit.
    func createRepo(at path: String) async throws {
        // git init -b main
        _ = try await runner.run(["init", "-b", "main"], cwd: path)
        injectGitignore(into: path)
        // Local identity so auto-commits always work (never touches user's global config).
        _ = try? await runner.run(["config", "user.name", "FileVault"], cwd: path)
        _ = try? await runner.run(["config", "user.email", "filevault@localhost"], cwd: path)
        // Initial commit when working tree is not empty.
        let entries = try await status(path: path)
        if !entries.isEmpty {
            _ = try? await commitAll(path: path, message: "auto: 初始版本")
        }
    }

    // MARK: - Gitignore

    /// Inject the standard .gitignore template into a NEW repo only.
    func injectGitignore(into path: String) {
        let template = """
        .DS_Store
        node_modules/
        *.tmp
        ~$*
        Thumbs.db
        """
        let url = URL(fileURLWithPath: path).appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Status / Commit

    /// Parse `git status --porcelain` into structured entries (FR-04 fallback check).
    ///
    /// `--untracked-files=all` matters: the default collapses a brand-new
    /// directory into ONE entry ("dir/"), which used to hide the files inside
    /// it from the commit message AND from the large-file exclusion check.
    public func status(path: String) async throws -> [StatusEntry] {
        let r = try await runner.run(["status", "--porcelain", "--untracked-files=all"], cwd: path)
        guard r.succeeded else { return [] }
        return r.stdout.split(separator: "\n").compactMap { line -> StatusEntry? in
            let l = String(line)
            guard l.count >= 3 else { return nil }
            let xy = String(l.prefix(2))
            let p = String(l.dropFirst(3))
            guard let change = Self.change(fromXY: xy) else { return nil }
            if change == .renamed, let range = p.range(of: " -> ") {
                return StatusEntry(change: change, path: String(p[range.upperBound...]), originalPath: String(p[..<range.lowerBound]))
            }
            return StatusEntry(change: change, path: p, originalPath: nil)
        }
    }

    /// Map porcelain XY code to Change kind (X=staged, Y=worktree; check both).
    static func change(fromXY xy: String) -> StatusEntry.Change? {
        if xy.contains("?") { return .added }
        if xy.hasPrefix("R") || xy.hasSuffix("R") { return .renamed }
        if let y = xy.last {
            switch y {
            case "D": return .deleted
            case "A": return .added
            case "T": return .typeChanged
            case "M", "U", "C": return .modified
            default: break
            }
        }
        if let x = xy.first {
            switch x {
            case "D": return .deleted
            case "A": return .added
            case "T": return .typeChanged
            case "M", "U", "C": return .modified
            default: break
            }
        }
        return .other
    }

    /// Whether the working tree has any change (self-heal check before commit).
    public func isDirty(path: String) async -> Bool {
        guard let entries = try? await status(path: path) else { return false }
        return !entries.isEmpty
    }

    // MARK: - Empty folders

    /// Hidden marker that makes an otherwise empty folder versionable.
    public static let emptyFolderMarker = ".gitkeep"

    /// Git cannot track empty directories, so a brand-new empty folder would
    /// never show up in history. Write a hidden marker into each such folder —
    /// only when everything inside it is ignored (e.g. .DS_Store) — and return
    /// the folder paths (relative to the repo root) that got one.
    public func materializeEmptyDirectoryMarkers(path: String, candidates: [String],
                                                 since: Date) async -> [String] {
        let fm = FileManager.default
        var marked: [String] = []
        var seen = Set<String>()
        for raw in candidates {
            let rel = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !rel.isEmpty, seen.insert(rel).inserted else { continue }
            let comps = rel.split(separator: "/")
            guard !comps.contains(where: { $0 == ".git" }) else { continue }
            let full = (path as NSString).appendingPathComponent(rel)
            // Real directories only: never follow symlinks (a marker could land
            // outside the protected folder) and never touch ignored folders
            // (node_modules/ etc.).
            let url = URL(fileURLWithPath: full)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                                 .creationDateKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            // Only folders CREATED while we were watching count as new. An old
            // empty folder that merely gets touched (Finder .DS_Store, mtime)
            // must not produce a "new folder" version.
            guard let created = values.creationDate, created >= since else { continue }
            if let r = try? await runner.run(["check-ignore", "-q", rel], cwd: path), r.exitCode == 0 {
                continue
            }
            let markerRel = rel + "/" + Self.emptyFolderMarker
            if let r = try? await runner.run(["check-ignore", "-q", markerRel], cwd: path), r.exitCode == 0 {
                continue
            }
            let children = (try? fm.contentsOfDirectory(atPath: full)) ?? []
            // A folder with real content is committed through that content;
            // only folders whose entries are all ignored need a marker.
            var versionable = false
            for child in children {
                let childRel = rel + "/" + child
                if let r = try? await runner.run(["check-ignore", "-q", childRel], cwd: path), r.exitCode == 0 {
                    continue
                }
                versionable = true
                break
            }
            guard !versionable else { continue }
            let keep = (full as NSString).appendingPathComponent(Self.emptyFolderMarker)
            if fm.fileExists(atPath: keep) { continue }
            guard fm.createFile(atPath: keep, contents: Data()) else { continue }
            marked.append(rel)
        }
        return marked
    }

    /// Commit everything: add -A, build summary message from staged diff, commit.
    /// Returns the new commit hash.
    @discardableResult
    public func commitAll(path: String, message: String? = nil, knownEntries: [StatusEntry]? = nil) async throws -> String {
        let entries: [StatusEntry]
        if let knownEntries {
            entries = knownEntries
        } else {
            entries = try await status(path: path)
        }
        guard !entries.isEmpty else { return "" }
        _ = try await runner.run(["add", "-A"], cwd: path)
        let stats = try await stagedStats(path: path)
        let msg = message ?? Self.buildCommitMessage(entries: entries, additions: stats.additions, deletions: stats.deletions)
        var args = ["commit", "-m", msg]
        // Adopted repos may lack identity config; provide overrides on failure.
        let c = try await runner.run(args, cwd: path)
        if !c.succeeded, c.stderr.contains("tell me who you are") {
            args = ["-c", "user.name=FileVault", "-c", "user.email=filevault@localhost", "commit", "-m", msg]
            let retry = try await runner.run(args, cwd: path)
            if retry.succeeded { return try await resolveHeadAndReturn(path: path) }
        }
        guard c.succeeded else {
            throw GitCommandError(command: "commit", exitCode: c.exitCode, stderr: c.stderr)
        }
        let hash = try await resolveHead(path: path)
        return hash
    }

    /// Staged diff stats for the commit message (+X -Y).
    struct StagedStats: Sendable {
        var additions: Int
        var deletions: Int
    }

    func stagedStats(path: String) async throws -> StagedStats {
        let r = try await runner.run(["diff", "--cached", "--numstat"], cwd: path)
        var add = 0
        var del = 0
        for line in r.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            if parts[0] == "-" { continue } // binary file
            add += Int(parts[0]) ?? 0
            del += Int(parts[1]) ?? 0
        }
        return StagedStats(additions: add, deletions: del)
    }

    public func resolveHead(path: String) async throws -> String {
        let r = try await runner.run(["rev-parse", "HEAD"], cwd: path)
        guard r.succeeded else {
            throw GitCommandError(command: "rev-parse HEAD", exitCode: r.exitCode, stderr: r.stderr)
        }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveHeadAndReturn(path: String) async throws -> String {
        try await resolveHead(path: path)
    }

    /// Build the auto commit message (FR-05):
    /// `auto: N 处变更 (+X -Y)，新增 a.md，修改 b.txt，删除 c.log`
    ///
    /// At most FIVE file names are listed IN TOTAL. A group that does not fit
    /// is summarised by count ("修改 3 个文件") so a 5-second burst of edits can
    /// never produce an unbounded commit subject. When two changed files share
    /// a basename, the relative path is used so the message stays unambiguous.
    static func buildCommitMessage(entries: [StatusEntry], additions: Int, deletions: Int) -> String {
        var added: [String] = []
        var modified: [String] = []
        var deleted: [String] = []
        let nameCounts = Dictionary(grouping: entries, by: \.displayName).mapValues(\.count)
        func label(_ entry: StatusEntry) -> String {
            (nameCounts[entry.displayName] ?? 0) > 1 ? entry.path : entry.displayName
        }
        for e in entries {
            switch e.change {
            case .added: added.append(label(e))
            case .modified, .renamed, .typeChanged: modified.append(label(e))
            case .deleted: deleted.append(label(e))
            case .other: modified.append(label(e))
            }
        }
        let total = entries.count
        var parts: [String] = []
        var remainingNames = 5
        func appendGroup(_ verb: String, _ list: [String]) {
            guard !list.isEmpty else { return }
            if remainingNames > 0 {
                let shown = Array(list.prefix(remainingNames))
                remainingNames -= shown.count
                if shown.count == list.count {
                    parts.append(verb + " " + shown.joined(separator: "、"))
                } else {
                    parts.append(verb + " " + shown.joined(separator: "、") + " 等 \(list.count) 个文件")
                }
            } else {
                parts.append(verb + " \(list.count) 个文件")
            }
        }
        appendGroup("新增", added)
        appendGroup("修改", modified)
        appendGroup("删除", deleted)
        let statPart = " (+\(additions) -\(deletions))"
        if parts.isEmpty {
            return "auto: \(total) 处变更\(statPart)"
        }
        return "auto: \(total) 处变更\(statPart)，" + parts.joined(separator: "，")
    }

    // MARK: - Remote config (FR-06/07)

    /// Set remote origin URL (stored in the repo's own .git/config; terminal-compatible).
    public func setRemote(path: String, url: String) async throws {
        let has = try await runner.run(["remote", "get-url", "origin"], cwd: path)
        if has.succeeded {
            _ = try await runner.run(["remote", "set-url", "origin", url], cwd: path)
        } else {
            _ = try await runner.run(["remote", "add", "origin", url], cwd: path)
        }
    }

    /// Effective remote URL — the source of truth is the repo's OWN git config
    /// (v2.2.4): prefers `origin`, falls back to any remote the user configured
    /// in their own source-control tooling (terminal / VS Code / Xcode).
    public func remoteURL(path: String) async -> String? {
        if let r = try? await runner.run(["remote", "get-url", "origin"], cwd: path),
           r.succeeded {
            let url = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty { return url }
        }
        return await firstAnyRemote(path: path)
    }

    /// All remotes configured in this repo as (name, url) pairs.
    public func allRemotes(path: String) async -> [(name: String, url: String)] {
        guard let names = try? await runner.run(["remote"], cwd: path), names.succeeded else { return [] }
        var out: [(String, String)] = []
        for name in names.stdout.split(separator: "\n").map(String.init).sorted() {
            guard let u = try? await runner.run(["remote", "get-url", name], cwd: path), u.succeeded else { continue }
            out.append((name, u.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return out
    }

    private func firstAnyRemote(path: String) async -> String? {
        for (_, url) in await allRemotes(path: path) where !url.isEmpty {
            return url
        }
        return nil
    }

    /// Remove remote origin.
    public func clearRemote(path: String) async throws {
        _ = try await runner.run(["remote", "remove", "origin"], cwd: path)
    }

    /// Toggle stored in the repo's own git config: filevault.autopush (terminal-visible).
    public func setAutoPush(path: String, enabled: Bool) async {
        _ = try? await runner.run(["config", "filevault.autopush", enabled ? "true" : "false"], cwd: path)
    }

    public func autoPushEnabled(path: String) async -> Bool {
        let r = try? await runner.run(["config", "--local", "--get", "filevault.autopush"], cwd: path)
        guard let r, r.succeeded else { return false }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    // MARK: - History / rollback (FR-09/10)

    /// Commit log (newest first).
    /// Fields are NUL-separated (%x00): a commit SUBJECT may contain "|" (user
    /// commits from terminal), which corrupted the old pipe-based parsing.
    /// Git itself never allows NUL inside a subject, so this separator is safe.
    public func log(path: String, max: Int = 50) async throws -> [CommitInfo] {
        let r = try await runner.run(["log", "--pretty=format:%H%x00%h%x00%s%x00%aI", "-n", String(max)], cwd: path)
        guard r.succeeded else { return [] }
        return r.stdout.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\u{0}")
            guard parts.count == 4, !parts[0].isEmpty, !parts[3].isEmpty else { return nil }
            let f = ISO8601DateFormatter()
            let d = f.date(from: parts[3]) ?? Date(timeIntervalSince1970: 0)
            return CommitInfo(hash: parts[0], shortHash: parts[1], subject: parts[2], date: d)
        }
    }

    /// Restore one file to the state it had in `hash`, then commit the rollback.
    ///
    /// - Rejects paths that escape the repo (absolute paths / `..` traversal).
    /// - Preserves uncommitted edits by committing them first (v3.3.1).
    /// - Throws when the file does not exist in that commit — the old
    ///   implementation ignored git's exit code and silently "succeeded".
    @discardableResult
    public func restoreFile(path: String, file: String, to hash: String) async throws -> String {
        try Self.validateRepoRelativePath(file)
        // Never lose data: snapshot pending changes before rewriting the file.
        let dirty = (try? await status(path: path)) ?? []
        if !dirty.isEmpty {
            _ = try await commitAll(path: path, message: "backup: 恢复前自动保存未提交改动")
        }
        let r = try await runner.run(["checkout", hash, "--", file], cwd: path)
        guard r.succeeded else {
            throw HistoryError.fileNotInCommit(file: file, hash: String(hash.prefix(7)))
        }
        return try await commitAll(path: path, message: "rollback: 恢复 \(file) 到 \(String(hash.prefix(7)))")
    }

    /// Hard-reset the repo to a given commit (history moves back; UI confirms).
    ///
    /// Safety (v3.3.1): pending edits are committed first, and the pre-reset
    /// HEAD is preserved in a hidden ref `refs/filevault/backup/<stamp>` so a
    /// mistaken rollback stays recoverable with plain git (`git log <ref>`).
    public func resetRepo(path: String, to hash: String) async throws {
        let verify = try await runner.run(["rev-parse", "--verify", "\(hash)^{commit}"], cwd: path)
        guard verify.succeeded else {
            throw HistoryError.commitNotFound(hash)
        }
        let dirty = (try? await status(path: path)) ?? []
        if !dirty.isEmpty {
            _ = try await commitAll(path: path, message: "backup: 回滚前自动保存未提交改动")
        }
        if let head = try? await runner.run(["rev-parse", "HEAD"], cwd: path),
           head.succeeded {
            let headHash = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !headHash.isEmpty {
                _ = try? await runner.run(["update-ref", "refs/filevault/backup/\(Self.backupStamp())", headHash], cwd: path)
            }
        }
        let r = try await runner.run(["reset", "--hard", hash], cwd: path)
        guard r.succeeded else {
            throw HistoryError.resetFailed(stderr: r.stderr)
        }
    }

    /// Reject absolute paths, empty names, NUL bytes and `..` traversal.
    static func validateRepoRelativePath(_ file: String) throws {
        let trimmed = file.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HistoryError.invalidPath(file) }
        guard !trimmed.hasPrefix("/") else { throw HistoryError.invalidPath(file) }
        guard !trimmed.contains("\u{0}") else { throw HistoryError.invalidPath(file) }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." || $0 == "." }) else {
            throw HistoryError.invalidPath(file)
        }
    }

    static func backupStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// Pull with --ff-only: never auto-merges (PRD); conflicts surface as errors.
    public func pull(path: String) async throws -> String {
        let r = try await runner.run(["pull", "--ff-only", "origin"], cwd: path)
        guard r.succeeded else {
            throw GitCommandError(command: "pull --ff-only origin", exitCode: r.exitCode, stderr: r.stderr)
        }
        return r.stdout
    }

    // MARK: - Per-repo auth mode (v2.1.0)

    public enum AuthMode: String {
        case auto, pat, ssh
    }

    public func setAuthMode(path: String, mode: AuthMode) async {
        _ = try? await runner.run(["config", "filevault.auth", mode.rawValue], cwd: path)
    }

    public func authMode(path: String) async -> AuthMode {
        let r = try? await runner.run(["config", "--local", "--get", "filevault.auth"], cwd: path)
        guard let r, r.succeeded,
              let mode = AuthMode(rawValue: r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .auto
        }
        return mode
    }

    /// Tracked files of a repo (v2.2.0 file-centric restore).
    public func listFiles(path: String) async -> [String] {
        guard let r = try? await runner.run(["ls-files"], cwd: path), r.succeeded else { return [] }
        return r.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.sorted()
    }

    // MARK: - Large file protection (FR-12)

    public static let largeFileMarkerComment = "# filevault-excluded-large-file"

    /// Exclude oversize untracked files via .git/info/exclude (not polluting user .gitignore).
    ///
    /// `threshold` is the ceiling derived from the repo's remote (see
    /// `GitHubLimits.effectiveThreshold(remoteURL:)`); `0` means the remote has
    /// no known single-file limit, so nothing is excluded.
    @discardableResult
    public func excludeLargeFiles(path: String, threshold: UInt64, entries precomputed: [StatusEntry]? = nil) async -> [String] {
        guard threshold > 0 else { return [] }
        let fm = FileManager.default
        let entries: [StatusEntry]
        if let precomputed {
            entries = precomputed
        } else {
            guard let fetched = try? await status(path: path) else { return [] }
            entries = fetched
        }
        var excluded: [String] = []
        for e in entries where e.change == .added {
            let abs = (path as NSString).appendingPathComponent(e.path)
            if let attrs = try? fm.attributesOfItem(atPath: abs),
               let size = attrs[.size] as? UInt64, size > threshold {
                appendExcludeRule(path: path, rule: e.path)
                excluded.append(e.path)
            }
        }
        return excluded
    }

    /// Append a rule to .git/info/exclude with marker comment if not present.
    private func appendExcludeRule(path: String, rule: String) {
        let file = URL(fileURLWithPath: path).appendingPathComponent(".git/info/exclude")
        let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if current.contains(rule) { return }
        var out = current
        if !current.hasSuffix("\n") && !current.isEmpty { out += "\n" }
        if !current.contains(Self.largeFileMarkerComment) {
            out += Self.largeFileMarkerComment + "\n"
        }
        out += rule + "\n"
        try? out.write(to: file, atomically: true, encoding: .utf8)
    }
}
