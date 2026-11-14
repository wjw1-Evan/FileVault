import Foundation

/// Manages per-root repos: scan, init/adopt, status, commit, remote config, log, rollback.
public final class RepoManager: @unchecked Sendable {
    public let runner: GitRunner

    public init(runner: GitRunner) {
        self.runner = runner
    }

    // MARK: - Scan

    /// List first-level subfolders (hidden dirs are skipped).
    public func firstLevelFolders(root: String) -> [SubRepo] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        return items.sorted()
            .filter { !$0.hasPrefix(".") }
    .map { name in
            SubRepo(
                name: name,
                path: (root as NSString).appendingPathComponent(name),
                isRepo: fm.fileExists(atPath: (root as NSString).appendingPathComponent(name) + "/.git")
            )
        }
    }

    /// Prepare repos under a root: init new, adopt existing, skip hidden (FR-03).
    public func ensureRepos(root: String) async throws -> RepoSetupResult {
        var created: [String] = []
        var adopted: [String] = []
        var hidden = 0
        for entry in firstLevelFolders(root: root) {
            if entry.isRepo {
                adopted.append(entry.name)
            } else {
                try await createRepo(at: entry.path)
                created.append(entry.name)
            }
    }
        return RepoSetupResult(created: created, adopted: adopted, skippedHidden: hiddenCount(root: root))
    }

    /// Count hidden entries at first level (report only).
    private func hiddenCount(root: String) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: root))?.filter { $0.hasPrefix(".") }.count ?? 0
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
    public func status(path: String) async throws -> [StatusEntry] {
        let r = try await runner.run(["status", "--porcelain"], cwd: path)
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
            case "M", "T", "U", "C": return .modified
            default: break
            }
        }
        if let x = xy.first {
            switch x {
            case "D": return .deleted
            case "A": return .added
            case "M", "T", "U", "C": return .modified
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

    /// Commit everything: add -A, build summary message from staged diff, commit.
    /// Returns the new commit hash.
    @discardableResult
    public func commitAll(path: String, message: String? = nil) async throws -> String {
        let entries = try await status(path: path)
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
    /// `auto: N 处变更 (+X -Y)，新增 a.md，修改 b.txt，删除 c.log` (max 5 files listed).
    static func buildCommitMessage(entries: [StatusEntry], additions: Int, deletions: Int) -> String {
        var added: [String] = []
        var modified: [String] = []
        var deleted: [String] = []
        for e in entries {
            switch e.change {
            case .added: added.append(e.displayName)
            case .modified, .renamed, .typeChanged: modified.append(e.displayName)
            case .deleted: deleted.append(e.displayName)
            case .other: modified.append(e.displayName)
            }
        }
        let total = entries.count
        var parts: [String] = []
        func take(_ list: [String]) -> [String] { Array(list.prefix(5 - parts.count)) }
        func appendGroup(_ verb: String, _ list: [String]) -> Void {
            let names = take(list)
            if !names.isEmpty {
                parts.append(verb + " " + names.joined(separator: "、"))
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

    /// Get remote origin URL, nil when not configured.
    public func remoteURL(path: String) async -> String? {
        let r = try? await runner.run(["remote", "get-url", "origin"], cwd: path)
        guard let r, r.succeeded else { return nil }
        let url = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
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
    public func log(path: String, max: Int = 50) async throws -> [CommitInfo] {
        let r = try await runner.run(["log", "--pretty=format:%H|%h|%s|%aI", "-n", String(max)], cwd: path)
        guard r.succeeded else { return [] }
        return r.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            let dateStr = String(parts[3])
            let f = ISO8601DateFormatter()
            let d = f.date(from: dateStr) ?? Date(timeIntervalSince1970: 0)
            return CommitInfo(hash: String(parts[0]), shortHash: String(parts[1]), subject: String(parts[2]), date: d)
        }
    }

    /// Restore one file to a given commit, then commit the rollback.
    public func restoreFile(path: String, file: String, to hash: String) async throws -> String {
        _ = try await runner.run(["checkout", hash, "--", file], cwd: path)
        return try await commitAll(path: path, message: "rollback: 恢复 \(file) 到 \(String(hash.prefix(7)))")
    }

    /// Reset the whole repo to a given commit (hard rollback; needs user confirmation in UI).
    public func resetRepo(path: String, to hash: String) async throws {
        _ = try await runner.run(["reset", "--hard", hash], cwd: path)
    }

    // MARK: - Large file protection (FR-12)

    public static let defaultLargeFileThreshold: UInt64 = 200 * 1024 * 1024
    public static let largeFileMarkerComment = "# filevault-excluded-large-file"

    /// Exclude oversize untracked files via .git/info/exclude (not polluting user .gitignore).
    @discardableResult
    public func excludeLargeFiles(path: String, threshold: UInt64 = RepoManager.defaultLargeFileThreshold) async -> [String] {
        let fm = FileManager.default
        guard let entries = try? await status(path: path) else { return [] }
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
