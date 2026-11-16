import Foundation

/// Manages the repo that IS a managed root folder: init/adopt, status, commit,
/// remote config, log, rollback.
///
/// v4.0: the managed root is exactly one repository. Everything under it —
/// loose files at the root, nested folders, hidden folders except .git and
/// whatever .gitignore excludes — is versioned together.
public final class RepoManager: @unchecked Sendable {
    public let runner: GitRunner

    /// Serializes remote operations (pull / sync / force-pull) per folder: two
    /// rebases on the same repo would fight over the index. The wait is async
    /// (no thread blocking) and bounded.
    private let remoteOpLock = NSLock()
    private var remoteOpsBusy: Set<String> = []

    public init(runner: GitRunner) {
        self.runner = runner
    }

    /// Wait for the folder's remote-operation slot (throws `busy` after 60 s,
    /// which only happens if a previous operation is genuinely stuck).
    private func acquireRemoteOp(_ path: String) async throws {
        let deadline = Date().addingTimeInterval(60)
        while true {
            remoteOpLock.lock()
            if !remoteOpsBusy.contains(path) {
                remoteOpsBusy.insert(path)
                remoteOpLock.unlock()
                return
            }
            remoteOpLock.unlock()
            if Date() > deadline { throw PullError.busy }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func releaseRemoteOp(_ path: String) {
        remoteOpLock.lock()
        remoteOpsBusy.remove(path)
        remoteOpLock.unlock()
    }

    /// Network git commands (fetch/pull/push) get a much longer budget than
    /// local ones: a big folder on a slow link routinely exceeds the 30 s
    /// default, and a timeout would be reported as a failure (v4.1.7).
    public static let networkTimeout: TimeInterval = 120

    /// Run a network git command; a timeout becomes a readable network error.
    private func runNetwork(_ args: [String], cwd: String) async throws -> GitResult {
        do {
            return try await runner.run(args, cwd: cwd, timeout: Self.networkTimeout)
        } catch let error as GitCommandError where error.exitCode == -9 {
            throw PullError.networkFailed(
                detail: NSLocalizedString("操作超时（网络较慢或仓库较大，已等待 120 秒）", comment: "pull error"))
        }
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
    /// What the user got when they bound or REPLACED the remote (v4.1.6).
    public struct RemoteChange: Sendable, Equatable {
        /// True when origin pointed somewhere else before this call.
        public let changed: Bool
        /// True only when an EXISTING origin was replaced (not a first bind).
        public let isReplacement: Bool
        /// False when the new remote could not be read (bad URL / missing auth).
        public let fetchSucceeded: Bool
        /// Whether the new remote has the current branch.
        public let remoteBranchExists: Bool
        /// Commits on the remote's copy of the current branch (0 = empty/new).
        public let remoteCommitCount: Int
        /// The new remote carries DIFFERENT history (not fast-forwardable in
        /// either direction): automating push/merge could mix two histories, so
        /// the user must choose sync / force pull / push first (v4.1.7).
        public let needsDecision: Bool
    }

    /// Bind origin to `url`. When the URL actually changes, everything that
    /// belonged to the OLD remote is detached first — the branch upstream and
    /// remote-tracking refs would otherwise make status/push keep comparing
    /// against the previous repository (v4.1.6). Returns what was found on the
    /// new remote so the UI can ask the user how to reconcile.
    @discardableResult
    public func setRemote(path: String, url: String) async throws -> RemoteChange {
        let old = try? await runner.run(["remote", "get-url", "origin"], cwd: path)
        let oldURL = old?.succeeded == true
            ? old?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        if let oldURL, oldURL == url {
            // Same remote: report the current state without touching anything.
            let info = await remoteBranchInfo(path: path)
            return RemoteChange(changed: false, isReplacement: false, fetchSucceeded: true,
                                remoteBranchExists: info.exists, remoteCommitCount: info.count,
                                needsDecision: false)
        }

        if oldURL != nil {
            _ = try await runner.run(["remote", "set-url", "origin", url], cwd: path)
        } else {
            _ = try await runner.run(["remote", "add", "origin", url], cwd: path)
        }
        // Guarantee the default fetch refspec: a hand-edited/imported remote may
        // lack it, which would keep remote-tracking refs empty and make pulls
        // look like "branch missing" forever (v4.1.7).
        await ensureOriginFetchRefspec(path: path)

        if oldURL != nil {
            // The old remote's refs and upstream are meaningless for the new one.
            _ = try? await runner.run(["branch", "--unset-upstream"], cwd: path)
            await deleteRemoteTrackingRefs(path: path, remote: "origin")
        }

        // Read the new remote (an empty repo fetches fine and has no refs).
        let fetch = try? await runner.run(["fetch", "--prune", "origin"], cwd: path,
                                          timeout: Self.networkTimeout)
        let info = await remoteBranchInfo(path: path)
        var needsDecision = false
        if info.exists {
            let remoteRef = "refs/remotes/origin/" + info.branch
            // A fast-forward in either direction is safe to automate; only
            // diverged/unrelated histories need the user's choice.
            let remoteIsAncestor = await isAncestor(remoteRef, of: "HEAD", path: path)
            let localIsAncestor = await isAncestor("HEAD", of: remoteRef, path: path)
            needsDecision = !(remoteIsAncestor || localIsAncestor)
        }
        let change = RemoteChange(changed: true, isReplacement: oldURL != nil,
                                  fetchSucceeded: fetch?.succeeded == true,
                                  remoteBranchExists: info.exists,
                                  remoteCommitCount: info.count,
                                  needsDecision: needsDecision)
        await setRemoteSwitchPending(path: path, pending: change.needsDecision)
        return change
    }

    /// Called once the user resolved a remote switch explicitly (successful
    /// pull / sync / force pull / push).
    public func clearRemoteSwitchPending(path: String) async {
        await setRemoteSwitchPending(path: path, pending: false)
    }

    /// Whether a freshly REPLACED remote still waits for the user's choice.
    public func remoteSwitchPending(path: String) async -> Bool {
        let r = try? await runner.run(["config", "--local", "--get", Self.remoteSwitchPendingKey],
                                      cwd: path)
        guard let r, r.succeeded else { return false }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    private static let remoteSwitchPendingKey = "filevault.remoteswitchpending"

    private func setRemoteSwitchPending(path: String, pending: Bool) async {
        if pending {
            _ = try? await runner.run(["config", "--local", Self.remoteSwitchPendingKey, "true"], cwd: path)
        } else {
            _ = try? await runner.run(["config", "--local", "--unset", Self.remoteSwitchPendingKey],
                                      cwd: path)
        }
    }

    /// (exists on origin, commit count, branch) for the checked-out branch.
    private func remoteBranchInfo(path: String) async -> (exists: Bool, count: Int, branch: String) {
        let headRef = try? await runner.run(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: path)
        let branch = headRef?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !branch.isEmpty else { return (false, 0, "") }
        let ref = "refs/remotes/origin/" + branch
        guard let r = try? await runner.run(["rev-list", "--count", ref], cwd: path), r.succeeded else {
            return (false, 0, branch)
        }
        let count = Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return (count > 0, count, branch)
    }

    /// Make sure origin has the standard fetch refspec (hand-edited remotes or
    /// imported configs may lack it).
    private func ensureOriginFetchRefspec(path: String) async {
        let current = try? await runner.run(["config", "--local", "--get-all", "remote.origin.fetch"],
                                            cwd: path)
        if current?.succeeded == true,
           !(current?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return
        }
        _ = try? await runner.run(["config", "--local", "--add", "remote.origin.fetch",
                                   "+refs/heads/*:refs/remotes/origin/*"], cwd: path)
    }

    /// Branch names available on a remote (fetches first, best effort).
    private func remoteBranchNames(path: String, remote: String) async -> [String] {
        _ = try? await runner.run(["fetch", "--prune", remote], cwd: path, timeout: Self.networkTimeout)
        guard let r = try? await runner.run(["for-each-ref", "--format=%(refname:short)",
                                             "refs/remotes/" + remote + "/"], cwd: path),
              r.succeeded else { return [] }
        let prefix = remote + "/"
        return r.stdout.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix(prefix) && !$0.hasSuffix("/HEAD") }
            .map { String($0.dropFirst(prefix.count)) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    /// Add the remote's branch names to a "branch missing" error so a simple
    /// branch-name mismatch (main vs master) is explained, not guessed (v4.1.7).
    private func enrichBranchMissing(_ error: PullError, path: String) async -> PullError {
        guard case .remoteBranchMissing(let remote, let branch, let available) = error,
              available.isEmpty else { return error }
        let names = await remoteBranchNames(path: path, remote: remote)
        return .remoteBranchMissing(remote: remote, branch: branch, available: names)
    }

    /// Delete refs/remotes/<remote>/* (they belong to the previous repository).
    private func deleteRemoteTrackingRefs(path: String, remote: String) async {
        guard let list = try? await runner.run(["for-each-ref", "--format=%(refname)",
                                                "refs/remotes/" + remote + "/"], cwd: path),
              list.succeeded else { return }
        for ref in list.stdout.split(separator: "\n").map(String.init) where !ref.isEmpty {
            _ = try? await runner.run(["update-ref", "-d", ref], cwd: path)
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
    /// - Commit messages say what the user asked for: 「找回」 for a file that
    ///   was gone, 「还原」 for one that was overwritten (v4.1).
    @discardableResult
    public func restoreFile(path: String, file: String, to hash: String) async throws -> String {
        try Self.validateRepoRelativePath(file)
        guard hash.range(of: "^[0-9a-fA-F]{4,40}$", options: .regularExpression) != nil else {
            throw HistoryError.commitNotFound(hash)
        }
        // The path must exist in that version, otherwise git checkout fails with
        // a generic "pathspec did not match" message.
        let exists = try await runner.run(["cat-file", "-e", "\(hash):\(file)"], cwd: path)
        guard exists.succeeded else {
            throw HistoryError.fileNotInCommit(file: file, hash: String(hash.prefix(7)))
        }
        let full = (path as NSString).appendingPathComponent(file)
        let wasMissing = !FileManager.default.fileExists(atPath: full)
        // Never lose data: snapshot pending changes before rewriting the file.
        let dirty = (try? await status(path: path)) ?? []
        if !dirty.isEmpty {
            _ = try await commitAll(path: path, message: "backup: 恢复前自动保存未提交改动")
        }
        let r = try await runner.run(["checkout", hash, "--", file], cwd: path)
        guard r.succeeded else {
            throw HistoryError.restoreFailed(stderr: r.stderr)
        }
        let short = String(hash.prefix(7))
        let message = wasMissing
            ? "restore: 找回 \(file)（版本 \(short)）"
            : "restore: 还原 \(file) 到 \(short)"
        return try await commitAll(path: path, message: message)
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

    // MARK: - Pull (multi-machine sync)

    /// Outcome of one successful pull.
    public struct PullResult: Sendable, Equatable {
        public enum Strategy: String, Sendable, Equatable {
            /// No local-only commits: HEAD simply moved to the remote tip.
            case fastForward
            /// Local auto-commits were replayed on top of the remote tip.
            case rebased
        }
        public let output: String
        public let headBefore: String?
        public let headAfter: String
        /// Remote commits brought in (0 = already up to date).
        public let pulledCommits: Int
        /// Local commits replayed on top of the remote (0 for a fast-forward).
        public let replayedCommits: Int
        public let strategy: Strategy
        /// Local files that blocked the checkout (ignored but tracked remotely);
        /// they were preserved next to the original as "name (本地副本).ext".
        public let movedLocalCopies: [String]

        public init(output: String, headBefore: String?, headAfter: String,
                    pulledCommits: Int, replayedCommits: Int, strategy: Strategy,
                    movedLocalCopies: [String] = []) {
            self.output = output
            self.headBefore = headBefore
            self.headAfter = headAfter
            self.pulledCommits = pulledCommits
            self.replayedCommits = replayedCommits
            self.strategy = strategy
            self.movedLocalCopies = movedLocalCopies
        }
    }

    /// Pull: fast-forward when possible, auto-rebase when both sides moved
    /// (v4.1.2).
    ///
    /// FileVault auto-commits every few seconds, so as soon as the remote also
    /// advanced, `--ff-only` can never succeed. The local-only commits are
    /// unpushed machine snapshots, so replaying them on top of the remote keeps
    /// history linear and is the least surprising reconciliation. This is still
    /// "never auto-merge a conflict": a conflicting rebase is aborted
    /// immediately, the repository is restored to its pre-pull state and the
    /// conflicting paths are reported — conflict markers must never reach the
    /// auto-commit pipeline. Histories without a common ancestor are refused.
    ///
    /// v4.1.1: the branch is resolved explicitly. `git pull --ff-only origin` is
    /// only valid when origin is the branch's configured upstream; a repo whose
    /// first push never succeeded has no upstream, and git refuses with
    /// "You asked to pull from the remote 'origin', but did not specify a branch"
    /// before fetching anything. Failures become a classified `PullError`
    /// (real reason + recovery step) instead of an opaque git exit code.
    public func pull(path: String) async throws -> PullResult {
        // A protected folder can disappear (moved, deleted, external disk
        // unmounted). Without this, `symbolic-ref --quiet` still prints
        // "fatal: not a git repository" on stderr and the user would be told to
        // fix a detached HEAD that does not exist.
        guard isRepo(at: path) else { throw PullError.notARepository }
        try await acquireRemoteOp(path)
        defer { releaseRemoteOp(path) }
        let headRef = try await runner.run(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: path)
        let branch = headRef.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard headRef.succeeded, !branch.isEmpty else { throw PullError.detachedHead }

        let target = try await pullTarget(path: path, currentBranch: branch)

        // Local-first: pending edits become a commit before the working tree is
        // touched (same rule as rollback). Otherwise a pull can refuse on dirty
        // files, or a rebase would start with an unstaged state.
        if await isDirty(path: path) {
            _ = try? await commitAll(path: path, message: "auto: 拉取前自动保存未提交改动")
        }
        let before = try? await resolveHead(path: path)

        // Protect ignored local files the incoming commits would overwrite: git
        // overwrites them silently, which would lose the local content.
        var movedLocalCopies = await protectIncomingIgnoredFiles(path: path, remote: target.remote,
                                                                 branch: target.branch)

        // 1. Fast-forward: the common case, no local-only commits.
        let ffArgs = ["pull", "--ff-only", target.remote, target.branch]
        var ff = try await runNetwork(ffArgs, cwd: path)
        if !ff.succeeded {
            // Ignored local files (e.g. .DS_Store) that the remote also tracks
            // block the checkout; keep them as "(本地副本)" and retry once.
            let blocked = blockedUntrackedFiles(stderr: ff.stderr)
            if !blocked.isEmpty {
                let moved = await moveBlockedFilesAside(path: path, files: blocked)
                if !moved.isEmpty {
                    movedLocalCopies = moved
                    ff = try await runNetwork(ffArgs, cwd: path)
                }
            }
        }
        if ff.succeeded {
            let after = (try? await resolveHead(path: path)) ?? ""
            return PullResult(output: ff.stdout, headBefore: before, headAfter: after,
                              pulledCommits: await countCommits(path: path, from: before, to: after),
                              replayedCommits: 0, strategy: .fastForward,
                              movedLocalCopies: movedLocalCopies)
        }
        // Only divergence is reconciled automatically; auth/network/missing
        // branch/dirty-tree failures are reported as they are.
        guard PullError.isDivergence(ff.stderr) else {
            throw await enrichBranchMissing(PullError.classify(stderr: ff.stderr, remote: target.remote, branch: target.branch), path: path)
        }
        // The refused ff-only pull already fetched, so FETCH_HEAD tells us
        // whether the two histories share an ancestor at all.
        guard await historySharesAncestor(path: path) else { throw PullError.unrelatedHistories }

        // 2. Replay local-only auto-commits on top of the remote tip.
        let rebaseArgs = ["-c", "rebase.autoStash=false", "pull", "--rebase",
                          target.remote, target.branch]
        var rebase = try await runNetwork(rebaseArgs, cwd: path)
        if !rebase.succeeded {
            let blocked = blockedUntrackedFiles(stderr: rebase.stderr)
            if !blocked.isEmpty {
                let moved = await moveBlockedFilesAside(path: path, files: blocked)
                if !moved.isEmpty {
                    movedLocalCopies += moved
                    rebase = try await runNetwork(rebaseArgs, cwd: path)
                }
            }
        }
        if rebase.succeeded {
            let after = (try? await resolveHead(path: path)) ?? ""
            let remoteTip = await fetchHeadSHA(path: path) ?? after
            return PullResult(output: rebase.stdout, headBefore: before, headAfter: after,
                              pulledCommits: await countCommits(path: path, from: before, to: remoteTip),
                              replayedCommits: await countCommits(path: path, from: remoteTip, to: after),
                              strategy: .rebased, movedLocalCopies: movedLocalCopies)
        }

        // 3. Something stopped the rebase. Capture the conflicts, abort, and
        //    verify the repository is exactly where it was before the pull.
        let unmerged = await unmergedPaths(path: path)
        if await rebaseInProgress(path: path) {
            _ = try? await runner.run(["rebase", "--abort"], cwd: path)
        }
        let stillInProgress = await rebaseInProgress(path: path)
        if !unmerged.isEmpty || stillInProgress {
            throw PullError.mergeConflict(files: unmerged, aborted: !stillInProgress)
        }
        throw await enrichBranchMissing(PullError.classify(stderr: rebase.stderr, remote: target.remote, branch: target.branch), path: path)
    }


    // MARK: - Force pull (remote is authoritative)

    /// Outcome of a force pull (v4.1.2).
    public struct ForcePullResult: Sendable, Equatable {
        /// refs/filevault/backup/<stamp> holding the replaced HEAD (nil when
        /// there was nothing to back up, or the backup failed).
        public let backupRef: String?
        public let replacedHead: String?
        public let headAfter: String
        /// Local commits that are no longer on the branch (0 = plain catch-up).
        public let discardedCommits: Int
        /// Blocked local files preserved as "name (本地副本).ext" before the reset.
        public let movedLocalCopies: [String]

        public init(backupRef: String?, replacedHead: String?, headAfter: String,
                    discardedCommits: Int, movedLocalCopies: [String] = []) {
            self.backupRef = backupRef
            self.replacedHead = replacedHead
            self.headAfter = headAfter
            self.discardedCommits = discardedCommits
            self.movedLocalCopies = movedLocalCopies
        }
    }

    /// Make the local branch identical to the remote tip, discarding local
    /// commits and content (v4.1.2).
    ///
    /// This is the "remote is authoritative" resolution for repositories whose
    /// local history is unrelated to (or hopelessly diverged from) the remote.
    /// It is never automatic: the UI asks first, and the replaced HEAD is kept
    /// in a hidden backup ref (refs/filevault/backup/…), so a mistaken force
    /// pull stays recoverable from the History window.
    ///
    /// Pending edits are committed before anything is replaced, exactly like a
    /// rollback, so they are part of the backup too.
    public func forcePull(path: String) async throws -> ForcePullResult {
        guard isRepo(at: path) else { throw PullError.notARepository }
        try await acquireRemoteOp(path)
        defer { releaseRemoteOp(path) }
        let headRef = try await runner.run(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: path)
        let branch = headRef.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard headRef.succeeded, !branch.isEmpty else { throw PullError.detachedHead }

        let target = try await pullTarget(path: path, currentBranch: branch)

        // Preserve pending edits in history first (same rule as rollback).
        if await isDirty(path: path) {
            _ = try? await commitAll(path: path, message: "auto: 强制拉取前自动保存未提交改动")
        }
        // Fail closed: reset --hard would silently destroy edits we failed to
        // commit, so refuse instead of proceeding.
        guard !(await isDirty(path: path)) else {
            throw PullError.localChanges(detail: "")
        }
        let oldHead = try? await resolveHead(path: path)

        // Fetch first: a force pull must never touch the working tree when the
        // remote is unreachable or the branch is missing.
        let fetch = try await runNetwork(["fetch", target.remote], cwd: path)
        guard fetch.succeeded else {
            throw await enrichBranchMissing(PullError.classify(stderr: fetch.stderr, remote: target.remote, branch: target.branch), path: path)
        }
        let remoteRef = "refs/remotes/\(target.remote)/\(target.branch)"
        guard let tip = try? await runner.run(["rev-parse", "--verify", "--quiet", remoteRef], cwd: path),
              tip.succeeded else {
            throw await enrichBranchMissing(.remoteBranchMissing(remote: target.remote, branch: target.branch), path: path)
        }
        let remoteTip = tip.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remoteTip.isEmpty else {
            throw await enrichBranchMissing(.remoteBranchMissing(remote: target.remote, branch: target.branch), path: path)
        }

        // Fail closed: never discard history unless it is safely reachable from
        // a backup ref first.
        var backupRef: String?
        if let oldHead, oldHead != remoteTip {
            let ref = "refs/filevault/backup/\(Self.backupStamp())"
            let backup = try await runner.run(["update-ref", ref, oldHead], cwd: path)
            guard backup.succeeded else {
                throw GitCommandError(command: "update-ref \(ref)", exitCode: backup.exitCode,
                                      stderr: backup.stderr)
            }
            backupRef = ref
        }

        // Keep ignored local files that the remote tree would silently replace.
        var movedLocalCopies = await protectIncomingIgnoredFiles(path: path, remoteTip: remoteTip)
        var reset = try await runner.run(["reset", "--hard", remoteTip], cwd: path)
        if !reset.succeeded {
            // Ignored local files can sit exactly where the remote tree adds a
            // file; preserve them as "(本地副本)" and retry instead of failing.
            let blocked = blockedUntrackedFiles(stderr: reset.stderr)
            if !blocked.isEmpty {
                let moved = await moveBlockedFilesAside(path: path, files: blocked)
                if !moved.isEmpty {
                    movedLocalCopies = moved
                    reset = try await runner.run(["reset", "--hard", remoteTip], cwd: path)
                }
            }
        }
        guard reset.succeeded else {
            throw GitCommandError(command: "reset --hard", exitCode: reset.exitCode, stderr: reset.stderr)
        }
        // Bind the branch to the remote so the next pull/push needs no setup.
        _ = try? await runner.run(["branch", "--set-upstream-to=\(target.remote)/\(target.branch)", branch],
                                  cwd: path)
        let after = (try? await resolveHead(path: path)) ?? remoteTip
        var discarded = 0
        if let oldHead {
            discarded = await countCommits(path: path, from: remoteTip, to: oldHead)
        }
        return ForcePullResult(backupRef: backupRef, replacedHead: oldHead,
                              headAfter: after, discardedCommits: discarded,
                              movedLocalCopies: movedLocalCopies)
    }

    /// Remote/branch a pull should fast-forward from: the configured upstream
    /// when there is one, otherwise the current branch on origin (the same pair
    /// `push -u origin HEAD` would establish).
    private func pullTarget(path: String, currentBranch: String) async throws -> (remote: String, branch: String) {
        if let upstream = try? await runner.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
                                                cwd: path),
           upstream.succeeded {
            let full = upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = full.firstIndex(of: "/") {
                let remote = String(full[..<slash])
                let branch = String(full[full.index(after: slash)...])
                if !remote.isEmpty, !branch.isEmpty, branch != "HEAD" {
                    return (remote, branch)
                }
            }
        }
        if let origin = try? await runner.run(["remote", "get-url", "origin"], cwd: path),
           origin.succeeded,
           !origin.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ("origin", currentBranch)
        }
        // A repo whose only remote has another name still works. With several
        // remotes there is no safe guess: pulling a fast-forward from the wrong
        // one would change the working tree, so ask the user to set an upstream.
        let remotes = (await allRemotes(path: path)).filter { !$0.url.isEmpty }
        if remotes.count == 1 {
            return (remotes[0].name, currentBranch)
        }
        if remotes.count > 1 { throw PullError.ambiguousRemote(remotes: remotes.map(\.name)) }
        throw PullError.noRemote
    }

    /// Whether HEAD and the freshly fetched remote tip share a commit. Pull only
    /// auto-rebases related histories; two independent roots cannot be
    /// reconciled automatically in any meaningful way.
    private func historySharesAncestor(path: String) async -> Bool {
        guard await fetchHeadSHA(path: path) != nil else { return false }
        guard let r = try? await runner.run(["merge-base", "HEAD", "FETCH_HEAD"], cwd: path),
              r.succeeded else { return false }
        return !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Commits between two heads (all of HEAD when the repo had no commit yet).
    private func countCommits(path: String, from: String?, to: String) async -> Int {
        guard !to.isEmpty else { return 0 }
        let range = from.map { "\($0)..\(to)" } ?? to
        guard let r = try? await runner.run(["rev-list", "--count", range], cwd: path), r.succeeded else {
            return 0
        }
        return Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Remote tip recorded by the last fetch/pull (nil when there is none).
    private func fetchHeadSHA(path: String) async -> String? {
        guard let r = try? await runner.run(["rev-parse", "--verify", "--quiet", "FETCH_HEAD"], cwd: path),
              r.succeeded else { return nil }
        let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Paths git could not merge while the aborted rebase was half-applied.
    private func unmergedPaths(path: String) async -> [String] {
        guard let r = try? await runner.run(["diff", "--name-only", "--diff-filter=U"], cwd: path),
              r.succeeded else { return [] }
        return r.stdout.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Whether a rebase is half-applied — checked before and after aborting so
    /// a conflict can never leave the repository in a merge state, and by the
    /// commit pipeline so it never commits conflict markers (v4.1.2).
    func rebaseInProgress(path: String) async -> Bool {
        if await gitPathExists(path: path, name: "rebase-merge") { return true }
        return await gitPathExists(path: path, name: "rebase-apply")
    }

    /// Whether a merge is half-applied (MERGE_HEAD exists).
    func mergeInProgress(path: String) async -> Bool {
        await gitPathExists(path: path, name: "MERGE_HEAD")
    }

    /// Whether the repository is mid-rebase or mid-merge: the auto-commit
    /// pipeline must stay out of the way while either is true (v4.1.3).
    func operationInProgress(path: String) async -> Bool {
        if await rebaseInProgress(path: path) { return true }
        return await mergeInProgress(path: path)
    }


    /// A leftover half-applied rebase/merge (crash or force-quit) that blocks
    /// auto-commits and remote operations (v4.1.8).
    public struct InterruptedOperation: Sendable, Equatable {
        public let rebase: Bool
        public let merge: Bool
        /// A .git/index.lock older than `staleLockAge` (crash leftover).
        public let staleLock: Bool
        public var isEmpty: Bool { !rebase && !merge && !staleLock }
    }

    /// A leftover .git/index.lock older than this is considered stale: a live
    /// FileVault git command times out after 120 s, so 5 minutes means a crash.
    static let staleLockAge: TimeInterval = 5 * 60

    /// Inspect leftover rebase/merge/lock state without changing anything.
    public func interruptedOperation(path: String) async -> InterruptedOperation {
        InterruptedOperation(rebase: await rebaseInProgress(path: path),
                             merge: await mergeInProgress(path: path),
                             staleLock: await staleIndexLock(path: path))
    }

    /// Whether a stale .git/index.lock blocks commits and pulls (v4.1.9).
    public func staleIndexLock(path: String) async -> Bool {
        guard let full = await gitPathFull("index.lock", path: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: full),
              let modified = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modified) > Self.staleLockAge
    }

    /// Abort a leftover rebase/merge so commits and pulls work again. Committed
    /// history and working-tree files are preserved; only the half-applied
    /// operation's intermediate state is discarded. Returns what was cleaned
    /// (nil when nothing was pending).
    @discardableResult
    public func repairInterruptedOperation(path: String) async throws -> String? {
        try await acquireRemoteOp(path)
        defer { releaseRemoteOp(path) }
        let state = await interruptedOperation(path: path)
        guard !state.isEmpty else { return nil }
        var cleared: [String] = []
        if state.rebase {
            let r = try await runner.run(["rebase", "--abort"], cwd: path)
            guard r.succeeded else {
                throw GitCommandError(command: "rebase --abort", exitCode: r.exitCode, stderr: r.stderr)
            }
            cleared.append(NSLocalizedString("变基", comment: "repair interrupted operation"))
        }
        if await mergeInProgress(path: path) {
            let m = try await runner.run(["merge", "--abort"], cwd: path)
            guard m.succeeded else {
                throw GitCommandError(command: "merge --abort", exitCode: m.exitCode, stderr: m.stderr)
            }
            cleared.append(NSLocalizedString("合并", comment: "repair interrupted operation"))
        }
        if await staleIndexLock(path: path), let lockPath = await gitPathFull("index.lock", path: path) {
            try? FileManager.default.removeItem(atPath: lockPath)
            if !FileManager.default.fileExists(atPath: lockPath) {
                cleared.append(NSLocalizedString("过期的锁文件", comment: "repair interrupted operation"))
            }
        }
        return cleared.isEmpty ? nil
            : cleared.joined(separator: NSLocalizedString("、", comment: "repair list joiner"))
    }

    /// Resolve a path under .git (handles worktrees where it lives outside).
    private func gitPathFull(_ name: String, path: String) async -> String? {
        guard let r = try? await runner.run(["rev-parse", "--git-path", name], cwd: path), r.succeeded else {
            return nil
        }
        let p = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        return p.hasPrefix("/") ? p : (path as NSString).appendingPathComponent(p)
    }

    /// Whether a path under .git (e.g. "MERGE_HEAD") exists, including in
    /// worktrees where `rev-parse --git-path` resolves outside the folder.
    private func gitPathExists(path: String, name: String) async -> Bool {
        guard let r = try? await runner.run(["rev-parse", "--git-path", name], cwd: path), r.succeeded else {
            return false
        }
        let p = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return false }
        let full = p.hasPrefix("/") ? p : (path as NSString).appendingPathComponent(p)
        return FileManager.default.fileExists(atPath: full)
    }

    /// Current SHA of refs/remotes/<remote>/<branch> (nil when it does not exist).
    private func remoteTrackingSHA(path: String, remote: String, branch: String) async -> String? {
        let ref = "refs/remotes/" + remote + "/" + branch
        guard let r = try? await runner.run(["rev-parse", "--verify", "--quiet", ref], cwd: path),
              r.succeeded else { return nil }
        let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    // MARK: - Merge sync (keep files from both sides)

    /// Outcome of "sync remote files into the folder, keep local files".
    public struct MergeSyncResult: Sendable, Equatable {
        public let headBefore: String?
        public let headAfter: String
        /// Paths that only the remote had (now added to the local folder).
        public let addedFromRemote: Int
        /// Paths that only the local folder had (kept untouched).
        public let keptLocalOnly: Int
        /// Same path changed on both sides: the LOCAL version stays at the
        /// original path, the REMOTE version is saved next to it.
        public let remoteCopies: [RemoteCopy]
        public let backupRef: String?
        /// Commits on the local branch that the remote does not have yet, i.e.
        /// work still to be pushed after the sync (0 = nothing to push).
        public let aheadCommits: Int
        /// Blocked local files preserved as "name (本地副本).ext" while merging.
        public let movedLocalCopies: [String]
        /// Whether new commits were created (false when already in sync).
        public var didChange: Bool { headBefore != headAfter }
        /// Whether the sync has local work the remote is still missing.
        public var needsPush: Bool { aheadCommits > 0 }

        public struct RemoteCopy: Sendable, Equatable {
            /// Original path (now holds the local version).
            public let path: String
            /// Where the remote version was saved, e.g. "note (远程副本).md".
            public let copyPath: String
        }

        public init(headBefore: String?, headAfter: String, addedFromRemote: Int,
                    keptLocalOnly: Int, remoteCopies: [RemoteCopy], backupRef: String?,
                    aheadCommits: Int, movedLocalCopies: [String] = []) {
            self.headBefore = headBefore
            self.headAfter = headAfter
            self.addedFromRemote = addedFromRemote
            self.keptLocalOnly = keptLocalOnly
            self.remoteCopies = remoteCopies
            self.backupRef = backupRef
            self.aheadCommits = aheadCommits
            self.movedLocalCopies = movedLocalCopies
        }
    }

    /// Sync remote files into the local folder while keeping local files
    /// (v4.1.4).
    ///
    /// This is the "bind a remote to a folder that already has files" path and
    /// it is deliberately lossless:
    /// - remote-only paths are added to the folder;
    /// - local-only paths are kept untouched;
    /// - same path with different content keeps BOTH: the LOCAL version stays
    ///   at the original path (this is a "keep local files" sync) and the REMOTE
    ///   version is saved as "name (远程副本).ext" next to it;
    /// - modify/delete vs delete/modify keeps the surviving side.
    /// It creates a merge commit (both parents are history), the pre-merge HEAD
    /// is kept in a backup ref, and the result reports how many local commits
    /// still need pushing so the caller can finish the round trip.
    public func mergeSync(path: String) async throws -> MergeSyncResult {
        guard isRepo(at: path) else { throw PullError.notARepository }
        try await acquireRemoteOp(path)
        defer { releaseRemoteOp(path) }
        let headRef = try await runner.run(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: path)
        let branch = headRef.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard headRef.succeeded, !branch.isEmpty else { throw PullError.detachedHead }
        let target = try await pullTarget(path: path, currentBranch: branch)

        // Local-first: pending edits become a commit (fail closed when that is
        // impossible - the merge must not lose them).
        if await isDirty(path: path) {
            _ = try? await commitAll(path: path, message: "auto: 同步前自动保存未提交改动")
        }
        guard !(await isDirty(path: path)) else { throw PullError.localChanges(detail: "") }

        let fetch = try await runNetwork(["fetch", target.remote], cwd: path)
        guard fetch.succeeded else {
            throw await enrichBranchMissing(PullError.classify(stderr: fetch.stderr, remote: target.remote, branch: target.branch), path: path)
        }
        guard let remoteTip = await remoteTrackingSHA(path: path, remote: target.remote,
                                                      branch: target.branch) else {
            throw await enrichBranchMissing(.remoteBranchMissing(remote: target.remote, branch: target.branch), path: path)
        }
        // Bind the branch so later pulls/pushes need no setup.
        _ = try? await runner.run(["branch", "--set-upstream-to=" + target.remote + "/" + target.branch, branch],
                                  cwd: path)
        let oldHead = try? await resolveHead(path: path)

        // No local commits yet: just take the remote tree.
        guard let oldHead else {
            var movedLocalCopies = await protectIncomingIgnoredFiles(path: path, remoteTip: remoteTip)
            var reset = try await runner.run(["reset", "--hard", remoteTip], cwd: path)
            if !reset.succeeded {
                let blocked = blockedUntrackedFiles(stderr: reset.stderr)
                if !blocked.isEmpty {
                    let moved = await moveBlockedFilesAside(path: path, files: blocked)
                    if !moved.isEmpty {
                        movedLocalCopies = moved
                        reset = try await runner.run(["reset", "--hard", remoteTip], cwd: path)
                    }
                }
            }
            guard reset.succeeded else {
                throw GitCommandError(command: "reset --hard", exitCode: reset.exitCode, stderr: reset.stderr)
            }
            // The upstream binding above cannot work while the branch is still
            // unborn; bind it again now that the reset created the branch.
            _ = try? await runner.run(["branch", "--set-upstream-to=" + target.remote + "/" + target.branch, branch],
                                      cwd: path)
            let after = (try? await resolveHead(path: path)) ?? remoteTip
            let counts = await treeDiffCounts(path: path, old: nil, new: remoteTip)
            return MergeSyncResult(headBefore: nil, headAfter: after,
                                   addedFromRemote: counts.added, keptLocalOnly: 0,
                                   remoteCopies: [], backupRef: nil, aheadCommits: 0,
                                   movedLocalCopies: movedLocalCopies)
        }
        if oldHead == remoteTip {
            return MergeSyncResult(headBefore: oldHead, headAfter: oldHead,
                                   addedFromRemote: 0, keptLocalOnly: 0,
                                   remoteCopies: [], backupRef: nil, aheadCommits: 0)
        }
        if await isAncestor(remoteTip, of: oldHead, path: path) {
            // Already contains the remote: nothing to bring in, but local
            // commits may still need pushing.
            return MergeSyncResult(headBefore: oldHead, headAfter: oldHead,
                                   addedFromRemote: 0, keptLocalOnly: 0,
                                   remoteCopies: [], backupRef: nil,
                                   aheadCommits: await countCommits(path: path, from: remoteTip, to: oldHead))
        }
        if await isAncestor(oldHead, of: remoteTip, path: path) {
            // Local is behind: a fast-forward cannot lose local files.
            var movedLocalCopies = await protectIncomingIgnoredFiles(path: path, remoteTip: remoteTip)
            var ff = try await runner.run(["merge", "--ff-only", remoteTip], cwd: path)
            if !ff.succeeded {
                let blocked = blockedUntrackedFiles(stderr: ff.stderr)
                if !blocked.isEmpty {
                    let moved = await moveBlockedFilesAside(path: path, files: blocked)
                    if !moved.isEmpty {
                        movedLocalCopies = moved
                        ff = try await runner.run(["merge", "--ff-only", remoteTip], cwd: path)
                    }
                }
            }
            guard ff.succeeded else {
                throw GitCommandError(command: "merge --ff-only", exitCode: ff.exitCode, stderr: ff.stderr)
            }
            let after = (try? await resolveHead(path: path)) ?? remoteTip
            let counts = await treeDiffCounts(path: path, old: oldHead, new: remoteTip)
            return MergeSyncResult(headBefore: oldHead, headAfter: after,
                                   addedFromRemote: counts.added, keptLocalOnly: 0,
                                   remoteCopies: [], backupRef: nil, aheadCommits: 0,
                                   movedLocalCopies: movedLocalCopies)
        }

        // Keep the replaced HEAD recoverable before touching the working tree.
        var backupRef: String?
        let ref = "refs/filevault/backup/" + Self.backupStamp()
        let backup = try await runner.run(["update-ref", ref, oldHead], cwd: path)
        guard backup.succeeded else {
            throw GitCommandError(command: "update-ref " + ref, exitCode: backup.exitCode, stderr: backup.stderr)
        }
        backupRef = ref

        let related = await historiesRelated(oldHead, remoteTip, path: path)
        var mergeArgs = ["merge", "--no-commit", "--no-ff"]
        if !related { mergeArgs.append("--allow-unrelated-histories") }
        mergeArgs.append(remoteTip)
        var movedLocalCopies = await protectIncomingIgnoredFiles(path: path, remoteTip: remoteTip)
        var merge = try await runner.run(mergeArgs, cwd: path)
        if !merge.succeeded {
            let blocked = blockedUntrackedFiles(stderr: merge.stderr)
            if !blocked.isEmpty {
                let moved = await moveBlockedFilesAside(path: path, files: blocked)
                if !moved.isEmpty {
                    if await mergeInProgress(path: path) {
                        _ = try? await runner.run(["merge", "--abort"], cwd: path)
                    }
                    movedLocalCopies = moved
                    merge = try await runner.run(mergeArgs, cwd: path)
                }
            }
        }
        let conflicts = await unmergedPaths(path: path)
        guard merge.succeeded || !conflicts.isEmpty else {
            // Not a conflict (e.g. an untracked file in the way): undo everything.
            if await mergeInProgress(path: path) {
                _ = try? await runner.run(["merge", "--abort"], cwd: path)
            }
            throw await enrichBranchMissing(PullError.classify(stderr: merge.stderr, remote: target.remote, branch: target.branch), path: path)
        }

        // Resolve conflicts without losing either side. This mode keeps local
        // files: the local content stays at the original path, the remote
        // version is saved beside it as "name (远程副本).ext".
        var copies: [MergeSyncResult.RemoteCopy] = []
        for file in conflicts {
            let stages = await unmergedStages(path: path, file: file)
            let hasLocal = stages.contains(2)
            let hasRemote = stages.contains(3)
            if hasLocal && hasRemote {
                if let copyPath = Self.remoteCopyPath(for: file, exists: { relative in
                    FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(relative))
                }), await materializeStage(3, path: path, file: file, to: copyPath) {
                    _ = try? await runner.run(["add", "--", copyPath], cwd: path)
                    copies.append(MergeSyncResult.RemoteCopy(path: file, copyPath: copyPath))
                } else {
                    // Could not materialize the remote copy: never drop it, so
                    // abort instead of silently keeping only one side.
                    _ = try? await runner.run(["merge", "--abort"], cwd: path)
                    throw GitCommandError(command: "checkout-index (remote copy)",
                                          exitCode: -1, stderr: "could not materialize remote copy of " + file)
                }
                _ = try? await runner.run(["checkout", "--ours", "--", file], cwd: path)
                _ = try? await runner.run(["add", "--", file], cwd: path)
            } else if hasRemote {
                // Local deleted it, remote changed it: bring the remote back.
                _ = try? await runner.run(["checkout", "--theirs", "--", file], cwd: path)
                _ = try? await runner.run(["add", "--", file], cwd: path)
            } else if hasLocal {
                // Remote deleted it, local changed it: keep the local file.
                _ = try? await runner.run(["checkout", "--ours", "--", file], cwd: path)
                _ = try? await runner.run(["add", "--", file], cwd: path)
            }
        }
        _ = try? await runner.run(["add", "-A"], cwd: path)
        let commit = try await runner.run(["commit", "-m", "sync: 同步远程文件到本地（保留本地文件）"], cwd: path)
        guard commit.succeeded else {
            if await mergeInProgress(path: path) {
                _ = try? await runner.run(["merge", "--abort"], cwd: path)
            }
            throw GitCommandError(command: "commit (sync merge)", exitCode: commit.exitCode,
                                  stderr: commit.stderr)
        }
        let after = (try? await resolveHead(path: path)) ?? remoteTip
        let counts = await treeDiffCounts(path: path, old: oldHead, new: remoteTip)
        return MergeSyncResult(headBefore: oldHead, headAfter: after,
                               addedFromRemote: counts.added, keptLocalOnly: counts.deleted,
                               remoteCopies: copies, backupRef: backupRef,
                               aheadCommits: await countCommits(path: path, from: remoteTip, to: after),
                               movedLocalCopies: movedLocalCopies)
    }

    /// Files a checkout/merge refuses because the remote tree also adds them
    /// while they are untracked locally (typically ignored files such as
    /// .DS_Store). Moving them aside keeps them instead of telling the user to
    /// delete their files (v4.1.8).
    private func blockedUntrackedFiles(stderr: String) -> [String] {
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.firstIndex(where: {
            $0.contains("untracked working tree files would be overwritten")
        }) else { return [] }
        var files: [String] = []
        for line in lines[(header + 1)...] {
            if line.hasPrefix("\t") || line.hasPrefix("    ") {
                let file = line.trimmingCharacters(in: .whitespaces)
                if !file.isEmpty { files.append(file) }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
        }
        if !files.isEmpty { return files }
        // Singular form: "error: Untracked working tree file '.DS_Store' would be
        // overwritten by merge."
        if let start = stderr.range(of: "Untracked working tree file '"),
           let end = stderr.range(of: "' would be overwritten", range: start.upperBound..<stderr.endIndex) {
            let name = String(stderr[start.upperBound..<end.lowerBound])
            if !name.isEmpty { return [name] }
        }
        return []
    }

    /// Ignored, untracked local files that the incoming remote commits add or
    /// change. Git silently overwrites ignored files during checkout, so their
    /// content must be preserved BEFORE the pull/reset/merge runs (v4.1.8).
    private func protectIncomingIgnoredFiles(path: String, remoteTip: String) async -> [String] {
        guard let diff = try? await runner.run(["diff", "--name-only", "-z", "HEAD", remoteTip], cwd: path),
              diff.succeeded else { return [] }
        let incoming = Set(diff.stdout.split(separator: "\0").map(String.init))
        guard !incoming.isEmpty else { return [] }
        guard let ignored = try? await runner.run(
                ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], cwd: path),
              ignored.succeeded else { return [] }
        let blocked = ignored.stdout.split(separator: "\0").map(String.init)
            .filter { incoming.contains($0) }
        guard !blocked.isEmpty else { return [] }
        return await moveBlockedFilesAside(path: path, files: blocked)
    }

    /// Fetch the incoming branch, then protect ignored files it would overwrite.
    private func protectIncomingIgnoredFiles(path: String, remote: String,
                                             branch: String) async -> [String] {
        let fetch = try? await runNetwork(["fetch", remote, branch], cwd: path)
        guard fetch?.succeeded == true,
              let tip = await remoteTrackingSHA(path: path, remote: remote, branch: branch) else {
            return []
        }
        return await protectIncomingIgnoredFiles(path: path, remoteTip: tip)
    }

    /// Move blocked local files aside, keeping their content. Returns the paths
    /// where they were preserved (relative to the repo root).
    private func moveBlockedFilesAside(path: String, files: [String]) async -> [String] {
        let fm = FileManager.default
        var moved: [String] = []
        for file in files {
            let src = (path as NSString).appendingPathComponent(file)
            guard fm.fileExists(atPath: src) else { continue }
            guard let copy = Self.localCopyPath(for: file, exists: { relative in
                fm.fileExists(atPath: (path as NSString).appendingPathComponent(relative))
            }) else { continue }
            let dst = (path as NSString).appendingPathComponent(copy)
            try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            do {
                try fm.moveItem(atPath: src, toPath: dst)
                moved.append(copy)
            } catch {
                continue
            }
        }
        return moved
    }

    /// "name (本地副本).ext" — a unique sibling path for a blocked local file.
    static func localCopyPath(for file: String, exists: (String) -> Bool) -> String? {
        let ns = file as NSString
        let dir = ns.deletingLastPathComponent
        let base = ns.lastPathComponent as NSString
        let ext = base.pathExtension
        let stem = base.deletingPathExtension
        func candidate(_ index: Int) -> String {
            let suffix = index == 1
                ? NSLocalizedString(" (本地副本)", comment: "blocked local file copy suffix")
                : String(format: NSLocalizedString(" (本地副本 %d)", comment: "blocked local file copy suffix"), index)
            let name = ext.isEmpty ? stem + suffix : stem + suffix + "." + ext
            return dir.isEmpty ? name : dir + "/" + name
        }
        var index = 1
        while exists(candidate(index)) {
            index += 1
            if index > 99 { return nil }
        }
        return candidate(index)
    }

    /// "name (远程副本).ext" - a unique sibling path for the remote version.
    static func remoteCopyPath(for file: String, exists: (String) -> Bool) -> String? {
        let ns = file as NSString
        let dir = ns.deletingLastPathComponent
        let base = ns.lastPathComponent as NSString
        let ext = base.pathExtension
        let stem = base.deletingPathExtension
        func candidate(_ index: Int) -> String {
            let suffix = index == 1
                ? NSLocalizedString(" (远程副本)", comment: "sync conflict copy suffix")
                : String(format: NSLocalizedString(" (远程副本 %d)", comment: "sync conflict copy suffix"), index)
            let name = ext.isEmpty ? stem + suffix : stem + suffix + "." + ext
            return dir.isEmpty ? name : dir + "/" + name
        }
        var index = 1
        while exists(candidate(index)) {
            index += 1
            if index > 99 { return nil }
        }
        return candidate(index)
    }

    /// Write one merge stage (2 = local, 3 = remote) to destination, binary-safe.
    private func materializeStage(_ stage: Int, path: String, file: String,
                                 to destination: String) async -> Bool {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("fv-sync-" + UUID().uuidString.prefix(8),
                                                              isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let prefix = tmp.path + "/"
        guard let r = try? await runner.run(["checkout-index", "--stage=" + String(stage), "--force",
                                             "--prefix=" + prefix, "--", file], cwd: path),
              r.succeeded else { return false }
        let produced = tmp.appendingPathComponent(file)
        guard fm.fileExists(atPath: produced.path) else { return false }
        let dest = (path as NSString).appendingPathComponent(destination)
        try? fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        try? fm.removeItem(atPath: dest)
        do {
            try fm.moveItem(at: produced, to: URL(fileURLWithPath: dest))
            return true
        } catch {
            return false
        }
    }

    /// Unmerged stage numbers (1 = base, 2 = local, 3 = remote) of one path.
    private func unmergedStages(path: String, file: String) async -> Set<Int> {
        guard let r = try? await runner.run(["ls-files", "-u", "--", file], cwd: path), r.succeeded else {
            return []
        }
        var stages = Set<Int>()
        for line in r.stdout.split(separator: "\n") {
            let head = line.split(separator: "\t", maxSplits: 1).first ?? line
            if let stage = head.split(separator: " ").last.flatMap({ Int($0) }) {
                stages.insert(stage)
            }
        }
        return stages
    }

    /// Added / deleted file counts between two trees (nil = empty tree).
    private func treeDiffCounts(path: String, old: String?, new: String?) async -> (added: Int, deleted: Int) {
        guard let old, let new else {
            let tip = old ?? new
            guard let tip else { return (0, 0) }
            guard let r = try? await runner.run(["ls-tree", "-r", "--name-only", tip], cwd: path),
                  r.succeeded else { return (0, 0) }
            let count = r.stdout.split(separator: "\n").filter { !$0.isEmpty }.count
            return old == nil ? (count, 0) : (0, count)
        }
        guard let r = try? await runner.run(["diff", "--name-status", old, new], cwd: path),
              r.succeeded else { return (0, 0) }
        var added = 0
        var deleted = 0
        for line in r.stdout.split(separator: "\n") {
            switch line.first {
            case "A": added += 1
            case "D": deleted += 1
            default: break
            }
        }
        return (added, deleted)
    }

    /// Whether candidate is an ancestor of descendant.
    private func isAncestor(_ candidate: String, of descendant: String, path: String) async -> Bool {
        guard let r = try? await runner.run(["merge-base", "--is-ancestor", candidate, descendant],
                                            cwd: path) else { return false }
        return r.exitCode == 0
    }

    /// Whether the two commits share any history at all.
    private func historiesRelated(_ a: String, _ b: String, path: String) async -> Bool {
        guard let r = try? await runner.run(["merge-base", a, b], cwd: path), r.succeeded else { return false }
        return !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
