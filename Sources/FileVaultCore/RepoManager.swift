import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Manages the repo that IS a managed root folder: init/adopt, status, commit,
/// remote config, log, rollback.
///
/// v4.0: the managed root is exactly one repository. Everything under it —
/// loose files at the root, nested folders, hidden folders except .git and
/// whatever .gitignore excludes — is versioned together.
public final class RepoManager: @unchecked Sendable {
    public let runner: GitRunner

    /// A nested repo could not be staged (unborn HEAD) and was excluded via
    /// info/exclude so auto-commit of the outer repo keeps working (v4.2.27).
    public var onNestedRepoExcluded: (@Sendable (String, String) -> Void)?

    /// Serializes remote operations (pull / sync / force-pull) per folder: two
    /// rebases on the same repo would fight over the index. The wait is async
    /// (no thread blocking) and bounded.
    private let remoteOpLock = NSLock()
    private var remoteOpsBusy: Set<String> = []

    public init(runner: GitRunner) {
        self.runner = runner
    }

    /// Serializes LOCAL working-tree mutations (commit pipeline, restore,
    /// rollback, directory restore) per folder. Without it a restore's
    /// `status → commit → checkout` can interleave with the 5-second auto-commit
    /// pipeline: index.lock collisions, a checkout that already applied but a
    /// commit that failed, or interleaved commits (v4.2.26).
    private let localOpLock = NSLock()
    private var localOpsBusy: Set<String> = []

    /// Try to take the local-mutation slot without waiting. Background work
    /// (auto-commit pipeline) uses this and simply retries later.
    func tryAcquireLocalOp(_ path: String) -> Bool {
        localOpLock.lock(); defer { localOpLock.unlock() }
        guard !localOpsBusy.contains(path) else { return false }
        localOpsBusy.insert(path)
        return true
    }

    /// Take the local-mutation slot, waiting for a short operation to finish.
    func acquireLocalOp(_ path: String) async throws {
        let deadline = Date().addingTimeInterval(60)
        while true {
            if tryAcquireLocalOp(path) { return }
            if Date() > deadline { throw PullError.busy }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func releaseLocalOp(_ path: String) {
        localOpLock.lock()
        localOpsBusy.remove(path)
        localOpLock.unlock()
    }

    /// Whether a local mutation (restore/rollback/commit) currently owns the repo.
    public func localOperationInProgress(path: String) -> Bool {
        localOpLock.lock(); defer { localOpLock.unlock() }
        return localOpsBusy.contains(path)
    }

    /// Synchronous try-claim for the remote-op slot (v4.2.31): the lock
    /// section never awaits, so it lives in a plain function — calling
    /// NSLock directly from the async poll loop below is an error under the
    /// Swift 6 language mode.
    private func tryAcquireRemoteOp(_ path: String) -> Bool {
        remoteOpLock.lock()
        if !remoteOpsBusy.contains(path) {
            remoteOpsBusy.insert(path)
            remoteOpLock.unlock()
            return true
        }
        remoteOpLock.unlock()
        return false
    }

    /// Wait for the folder's remote-operation slot (throws `busy` after 60 s,
    /// which only happens if a previous operation is genuinely stuck).
    func acquireRemoteOp(_ path: String) async throws {
        let deadline = Date().addingTimeInterval(60)
        while true {
            if tryAcquireRemoteOp(path) { return }
            if Date() > deadline { throw PullError.busy }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func releaseRemoteOp(_ path: String) {
        remoteOpLock.lock()
        remoteOpsBusy.remove(path)
        remoteOpLock.unlock()
    }

    /// True while a pull/rebase/merge owns the repo (used by restore/rollback to
    /// refuse instead of racing the remote operation).
    func remoteOperationInProgress(path: String) -> Bool {
        remoteOpLock.lock(); defer { remoteOpLock.unlock() }
        return remoteOpsBusy.contains(path)
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
    ///
    /// `remoteURL` (when the user binds one in the same step) is written into
    /// the repo BEFORE the first commit so the large-file ceiling is known while
    /// the first version is built (v4.2.26).
    @discardableResult
    public func ensureRepo(at path: String, remoteURL: String? = nil) async throws -> RepoSetupResult {
        if isRepo(at: path) {
            return RepoSetupResult(created: false, adopted: true)
        }
        try await createRepo(at: path, remoteURL: remoteURL)
        return RepoSetupResult(created: true, adopted: false)
    }

    /// Create a new repo in an existing folder: init + gitignore + identity + initial commit.
    func createRepo(at path: String, remoteURL: String? = nil) async throws {
        // git init -b main
        _ = try await runner.run(["init", "-b", "main"], cwd: path)
        injectGitignore(into: path)
        // Local identity so auto-commits always work (never touches user's global config).
        _ = try? await runner.run(["config", "user.name", "FileVault"], cwd: path)
        _ = try? await runner.run(["config", "user.email", "filevault@localhost"], cwd: path)
        // Bind the remote BEFORE the first commit. The commit pipeline derives the
        // single-file ceiling from the remote; without it a 100 MiB+ blob lands in
        // the very first commit, can never be pushed to github.com, and no future
        // commit can fix that history (v4.2.26). Only the config is written here —
        // no network call, the fetch/merge happens in SyncManager.configureRemote.
        var threshold: UInt64 = 0
        if let remoteURL, !remoteURL.isEmpty {
            let add = try await runner.run(["remote", "add", "origin", remoteURL], cwd: path)
            if add.succeeded {
                threshold = GitHubLimits.effectiveThreshold(remoteURL: remoteURL)
            }
        }
        // Initial commit when working tree is not empty.
        let entries = try await status(path: path)
        if !entries.isEmpty {
            if threshold > 0 {
                _ = await excludeLargeFiles(path: path, threshold: threshold, entries: entries)
            }
            // A transiently failed initial commit (index.lock, disk full) used
            // to report "添加成功" while the repo had zero versions and no
            // immediate feedback. Retry once, then surface the failure to the
            // add flow (v4.2.27).
            do {
                _ = try await commitAll(path: path, message: "auto: 初始版本")
            } catch {
                try? await Task.sleep(nanoseconds: 200_000_000)
                _ = try await commitAll(path: path, message: "auto: 初始版本")
            }
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
        // -z (NUL separated) keeps unusual file names intact: without it git
        // C-quotes names containing newlines/quotes, and a rename whose NEW name
        // contains " -> " would be split at the wrong place (v4.2.10).
        let r = try await runner.run(["status", "--porcelain", "-z", "--untracked-files=all"], cwd: path)
        // A failed status is NOT "no changes": callers use this result for
        // fail-closed decisions (refuse reset --hard on a dirty tree, back up
        // edits before a rollback). Reporting [] here silently turned a locked
        // index or an unreadable repo into "clean" and let force-pull discard
        // uncommitted work (v4.2.25).
        guard r.succeeded else {
            throw GitCommandError(command: "status", exitCode: r.exitCode, stderr: r.stderr)
        }
        let records = r.stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var entries: [StatusEntry] = []
        var i = 0
        while i < records.count {
            let record = records[i]
            i += 1
            guard record.count >= 4 else { continue }
            let xy = String(record.prefix(2))
            let p = String(record.dropFirst(3))
            guard let change = Self.change(fromXY: xy) else { continue }
            if xy.contains("R") || xy.contains("C") {
                // With -z the ORIGINAL path follows as the next NUL record.
                let original = i < records.count ? records[i] : ""
                i += 1
                entries.append(StatusEntry(change: change, path: p,
                                           originalPath: original.isEmpty ? nil : original))
            } else {
                entries.append(StatusEntry(change: change, path: p, originalPath: nil))
            }
        }
        return entries
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
    ///
    /// Throws when git cannot read the status: "unknown" must never be treated
    /// as "clean" (v4.2.25).
    public func isDirty(path: String) async throws -> Bool {
        try await !status(path: path).isEmpty
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
            // A nested repository is the user's own repo, not ours: never write
            // our folder marker (or anything else) inside it (v4.2.26).
            var isInsideNestedRepo = false
            for i in 1...max(1, comps.count) {
                let prefix = comps.prefix(i).joined(separator: "/")
                let candidate = (path as NSString).appendingPathComponent(prefix)
                if fm.fileExists(atPath: (candidate as NSString).appendingPathComponent(".git")) {
                    isInsideNestedRepo = true
                    break
                }
            }
            guard !isInsideNestedRepo else { continue }
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
            if let r = try? await runner.run(["check-ignore", "-q", "--", rel], cwd: path), r.exitCode == 0 {
                continue
            }
            let markerRel = rel + "/" + Self.emptyFolderMarker
            if let r = try? await runner.run(["check-ignore", "-q", "--", markerRel], cwd: path), r.exitCode == 0 {
                continue
            }
            let children = (try? fm.contentsOfDirectory(atPath: full)) ?? []
            // A folder with real content is committed through that content;
            // only folders whose entries are all ignored need a marker.
            var versionable = false
            for child in children {
                let childRel = rel + "/" + child
                if let r = try? await runner.run(["check-ignore", "-q", "--", childRel], cwd: path), r.exitCode == 0 {
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
        // A failed add must surface its real reason (permission denied, index
        // locked, disk full). It used to be ignored, and the following commit
        // then failed with a misleading "nothing to commit" (v4.2.26).
        var add = try await runner.run(["add", "-A"], cwd: path)
        // A nested repo whose HEAD is unborn (fresh `git init`, no commits)
        // cannot be staged as a gitlink: `add -A` exits 128 with "does not have
        // a commit checked out", so auto-commit stopped for the WHOLE outer
        // repo. Exclude it via info/exclude and retry once (v4.2.27).
        if !add.succeeded, add.stderr.contains("does not have a commit checked out") {
            var nested: String?
            let parts = add.stderr.split(separator: "'")
            if parts.count >= 2 { nested = String(parts[1]) }
            if let dir = nested {
                _ = appendExcludeRule(path: path, section: Self.nestedRepoMarkerComment,
                                      rule: Self.escapedExcludeRule(dir))
                add = try await runner.run(["add", "-A"], cwd: path)
                onNestedRepoExcluded?(path, dir)
            }
        }
        guard add.succeeded else {
            throw GitCommandError(command: "add -A", exitCode: add.exitCode, stderr: add.stderr)
        }
        // A dirty nested repository (or a change that is entirely ignored) makes
        // status report an entry while nothing can actually be staged. Committing
        // that would fail with "nothing to commit" on every pipeline run, which
        // the UI reported as a permanent auto-commit failure (v4.2.26).
        var staged = try await runner.run(["diff", "--cached", "--name-only", "-z"], cwd: path)
        // v4.2.27: a TRACKED file that grew past the remote's single-file
        // ceiling would be staged by add -A and committed — that blob can never
        // be pushed (GitHub rejects it permanently), and the deterministic
        // rejection message cannot be remedied by moving the file out. Unstage
        // oversized staged paths (the working-tree file stays untouched) when
        // the remote has a known ceiling; the marker rule keeps the UI warning
        // and the notification one-time (see excludeLargeFiles).
        if staged.succeeded, !staged.stdout.isEmpty {
            let threshold = GitHubLimits.effectiveThreshold(remoteURL: await remoteURL(path: path))
            if threshold > 0 {
                // Direct size check (not just marker rules): restore/rollback
                // backup commits and any caller that skips excludeLargeFiles
                // must not slip an oversized blob into history either.
                let fm = FileManager.default
                for p in staged.stdout.split(separator: "\0").map(String.init).filter({ !$0.isEmpty }) {
                    let abs = (path as NSString).appendingPathComponent(p)
                    guard fm.fileExists(atPath: abs),
                          let attrs = try? fm.attributesOfItem(atPath: abs),
                          let size = attrs[.size] as? UInt64, size > threshold else { continue }
                    _ = try? await runner.run(["reset", "-q", "--", p], cwd: path)
                    // Record it so the UI warning and one-time notification
                    // apply here too (appendExcludeRule dedupes).
                    _ = appendExcludeRule(path: path, section: Self.largeFileMarkerComment,
                                          rule: Self.escapedExcludeRule(p))
                }
                staged = try await runner.run(["diff", "--cached", "--name-only", "-z"], cwd: path)
            }
        }
        if staged.succeeded, staged.stdout.isEmpty { return "" }
        let stats = try await stagedStats(path: path)
        let msg = message ?? Self.buildCommitMessage(entries: entries, additions: stats.additions, deletions: stats.deletions)
        // --no-verify: hooks are for commits a human initiates. A background
        // snapshot commit must not be vetoed (auto-commit cannot be disabled by
        // design) or blocked for 30 s by a lint hook (v4.2.27).
        var args = ["commit", "--no-verify", "-m", msg]
        // Adopted repos may lack identity config; provide overrides on failure.
        let c = try await runner.run(args, cwd: path)
        if !c.succeeded, c.stderr.contains("tell me who you are") {
            args = ["-c", "user.name=FileVault", "-c", "user.email=filevault@localhost",
                    "commit", "--no-verify", "-m", msg]
            let retry = try await runner.run(args, cwd: path)
            if retry.succeeded { return try await resolveHeadAndReturn(path: path) }
            // The retry failed for a DIFFERENT reason (hook, disk full, …):
            // report THAT failure, not the identity error that triggered the
            // retry (v4.2.27).
            throw GitCommandError(command: "commit", exitCode: retry.exitCode, stderr: retry.stderr)
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
            let raw = (nameCounts[entry.displayName] ?? 0) > 1 ? entry.path : entry.displayName
            return Self.subjectLabel(raw)
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

    /// A file/folder name as shown in a commit subject: single line, no control
    /// characters, bounded length (a name with a newline must not split the
    /// subject; an extremely long name must not flood the history) (v4.2.11).
    static func subjectLabel(_ raw: String, limit: Int = 60) -> String {
        let flattened = raw.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
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
        // Canonical remote is "origin" (README: the address lives in the standard
        // remote.origin.url so terminal git stays compatible). When the repo has no
        // origin but its branch upstream points at another remote, update THAT one:
        // otherwise pull/push would keep using the old address while the UI says the
        // new one was saved (v4.2.26).
        let hasOrigin = (try? await runner.run(["remote", "get-url", "origin"], cwd: path))?.succeeded ?? false
        let remote: String
        if hasOrigin {
            remote = "origin"
        } else if let upstreamRemote = await upstreamRemoteName(path: path) {
            remote = upstreamRemote
        } else {
            remote = "origin"
        }
        let old = try? await runner.run(["remote", "get-url", remote], cwd: path)
        let oldURL = old?.succeeded == true
            ? old?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        if let oldURL, oldURL == url {
            // Same remote: still undo a previous "clear remote" (app-side sync
            // disabled flag), otherwise re-saving the same address would leave
            // the folder silently unsynced (v4.2.26).
            await setRemoteDisabled(path: path, disabled: false)
            let info = await remoteBranchInfo(path: path, remote: remote)
            return RemoteChange(changed: false, isReplacement: false, fetchSucceeded: true,
                                remoteBranchExists: info.exists, remoteCommitCount: info.count,
                                needsDecision: false)
        }

        let write: GitResult
        if oldURL != nil {
            write = try await runner.run(["remote", "set-url", remote, url], cwd: path)
        } else {
            write = try await runner.run(["remote", "add", remote, url], cwd: path)
        }
        // A swallowed git failure here made the UI say "saved" while the push
        // kept going to the old URL (v4.2.26).
        guard write.succeeded else {
            throw GitCommandError(command: "remote " + (oldURL != nil ? "set-url" : "add"),
                                  exitCode: write.exitCode, stderr: write.stderr)
        }
        // Saving an address is an explicit "sync this folder" intent: undo a
        // previous "clear remote" (which only disables app-side syncing).
        await setRemoteDisabled(path: path, disabled: false)
        // Guarantee the default fetch refspec: a hand-edited/imported remote may
        // lack it, which would keep remote-tracking refs empty and make pulls
        // look like "branch missing" forever (v4.1.7).
        await ensureFetchRefspec(path: path, remote: remote)

        if oldURL != nil {
            // The old remote's refs and upstream are meaningless for the new one.
            _ = try? await runner.run(["branch", "--unset-upstream"], cwd: path)
            await deleteRemoteTrackingRefs(path: path, remote: remote)
        }

        // Read the new remote (an empty repo fetches fine and has no refs).
        let fetch = try? await runner.run(["fetch", "--prune", remote], cwd: path,
                                          timeout: Self.networkTimeout)
        let info = await remoteBranchInfo(path: path, remote: remote)
        var needsDecision = false
        if info.exists {
            let remoteRef = "refs/remotes/\(remote)/" + info.branch
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

    /// Remote name the current branch's upstream points at, if configured.
    private func upstreamRemoteName(path: String) async -> String? {
        guard let r = try? await runner.run(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], cwd: path),
            r.succeeded else { return nil }
        let full = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = full.firstIndex(of: "/") else { return nil }
        let name = String(full[..<slash])
        return name.isEmpty ? nil : name
    }

    /// (exists on the remote, commit count, branch) for the checked-out branch.
    private func remoteBranchInfo(path: String, remote: String) async -> (exists: Bool, count: Int, branch: String) {
        let headRef = try? await runner.run(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: path)
        let branch = headRef?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !branch.isEmpty else { return (false, 0, "") }
        let ref = "refs/remotes/" + remote + "/" + branch
        guard let r = try? await runner.run(["rev-list", "--count", ref], cwd: path), r.succeeded else {
            return (false, 0, branch)
        }
        let count = Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return (count > 0, count, branch)
    }

    /// Make sure a remote has the standard fetch refspec (hand-edited remotes
    /// or imported configs may lack it).
    private func ensureFetchRefspec(path: String, remote: String) async {
        let current = try? await runner.run(["config", "--local", "--get-all",
                                             "remote." + remote + ".fetch"], cwd: path)
        if current?.succeeded == true,
           !(current?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return
        }
        _ = try? await runner.run(["config", "--local", "--add",
                                   "remote." + remote + ".fetch",
                                   "+refs/heads/*:refs/remotes/" + remote + "/*"], cwd: path)
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

    /// Stored intent: the user pressed "clear remote" in the app. Deleting the
    /// git remote itself would throw away config the user may rely on in a
    /// terminal, so app-side syncing is disabled instead; saving an address or
    /// choosing a sync remote clears the flag again (v4.2.26).
    private static let remoteDisabledKey = "filevault.remotedisabled"

    func remoteDisabled(path: String) async -> Bool {
        let r = try? await runner.run(["config", "--local", "--get", Self.remoteDisabledKey],
                                      cwd: path)
        guard let r, r.succeeded else { return false }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    @discardableResult
    private func setRemoteDisabled(path: String, disabled: Bool) async -> Bool {
        let r: GitResult?
        if disabled {
            r = try? await runner.run(["config", "--local", Self.remoteDisabledKey, "true"],
                                      cwd: path)
        } else {
            r = try? await runner.run(["config", "--local", "--unset", Self.remoteDisabledKey],
                                      cwd: path)
        }
        // --unset exits 5 when the key is absent: that is success for us.
        return r?.succeeded == true || (!disabled && r?.exitCode == 5)
    }

    /// Effective remote URL — the source of truth is the repo's OWN git config
    /// (v2.2.4): prefers `origin`, falls back to any remote the user configured
    /// in their own source-control tooling (terminal / VS Code / Xcode).
    public func remoteURL(path: String) async -> String? {
        if await remoteDisabled(path: path) { return nil }
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

    /// Stop syncing this folder from the app.
    ///
    /// v4.2.26: it used to delete only "origin", so when the repo's sync remote
    /// had another name (or an upstream pointed elsewhere) `remoteURL` still
    /// found a remote and the app kept pulling/pushing while the UI said "仅本地".
    /// Deleting the user's remotes would break their terminal workflow, so the
    /// intent is recorded and every sync path consults it.
    public func clearRemote(path: String) async throws {
        guard await setRemoteDisabled(path: path, disabled: true) else {
            throw GitCommandError(command: "config remote-disabled", exitCode: 1,
                                  stderr: NSLocalizedString("无法更新本仓库的同步设置", comment: "git error"))
        }
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
    public func log(path: String, max: Int = 50, skip: Int = 0) async throws -> [CommitInfo] {
        var args = ["log", "--pretty=format:%H%x00%h%x00%s%x00%aI", "-n", String(max)]
        if skip > 0 { args.append("--skip=\(skip)") }
        let r = try await runner.run(args, cwd: path)
        // An unborn HEAD is genuinely empty; any OTHER failure (index.lock,
        // corrupted .git, unreadable disk) used to render as "还没有提交历史"
        // while data was actually there but unreadable (v4.2.27).
        guard r.succeeded else {
            if r.exitCode == 128, r.stderr.contains("does not have any commits yet") {
                return []
            }
            throw GitCommandError(command: "log", exitCode: r.exitCode, stderr: r.stderr)
        }
        // One formatter for the whole batch: constructing ISO8601DateFormatter
        // per line used to dominate log() time on 100-entry pages (v4.2.28).
        let f = ISO8601DateFormatter()
        return r.stdout.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\u{0}")
            guard parts.count == 4, !parts[0].isEmpty, !parts[3].isEmpty else { return nil }
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
        // Serialize local mutations and stay out of a running pull/rebase: a
        // restore that interleaved with the auto-commit pipeline or a rebase left
        // the repo half-updated (checkout applied but commit failed) (v4.2.26).
        try await acquireRemoteOp(path)
        defer { releaseRemoteOp(path) }
        try await acquireLocalOp(path)
        defer { releaseLocalOp(path) }
        guard !(await operationInProgress(path: path)) else { throw HistoryError.repositoryBusy }
        // The path must exist in that version, otherwise git checkout fails with
        // a generic "pathspec did not match" message.
        let exists = try await runner.run(["cat-file", "-e", "\(hash):\(file)"], cwd: path)
        guard exists.succeeded else {
            throw HistoryError.fileNotInCommit(file: file, hash: String(hash.prefix(7)))
        }
        // The path may be a tree in that version (restoring a "file" that is a
        // folder) or a directory may now sit where the file must go; both would
        // otherwise fail with a raw checkout message (v4.2.14).
        let type = try await runner.run(["cat-file", "-t", "\(hash):\(file)"], cwd: path)
        if type.succeeded,
           type.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "tree" {
            throw HistoryError.fileNotInCommit(file: file, hash: String(hash.prefix(7)))
        }
        let full = (path as NSString).appendingPathComponent(file)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue {
            throw HistoryError.restoreTargetIsDirectory(file: file)
        }
        let wasMissing = !FileManager.default.fileExists(atPath: full)
        // Never lose data: snapshot pending changes before rewriting the file.
        // A failed status aborts the restore instead of assuming a clean tree.
        let dirty = try await status(path: path)
        if !dirty.isEmpty {
            _ = try await commitAll(path: path, message: "backup: 恢复前自动保存未提交改动")
        }
        // Checkout silently overwrites a file that is currently ignored (its
        // content lives in no commit, the "backup:" commit above cannot save it).
        // Refuse so the user can move it aside instead of losing it (v4.2.26).
        if try await isIgnoredUntracked(file: file, path: path) {
            throw HistoryError.restoreWouldOverwriteIgnored(file: file)
        }
        // GitRunner runs with --literal-pathspecs: "a[1].txt" cannot also
        // rewrite "a1.txt" (v4.2.26).
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
        // Serialize with pulls/rebases and local mutations (v4.2.26).
        try await acquireRemoteOp(path)
        defer { releaseRemoteOp(path) }
        try await acquireLocalOp(path)
        defer { releaseLocalOp(path) }
        guard !(await operationInProgress(path: path)) else { throw HistoryError.repositoryBusy }
        let verify = try await runner.run(["rev-parse", "--verify", "\(hash)^{commit}"], cwd: path)
        guard verify.succeeded else {
            throw HistoryError.commitNotFound(hash)
        }
        let dirty = try await status(path: path)
        if !dirty.isEmpty {
            _ = try await commitAll(path: path, message: "backup: 回滚前自动保存未提交改动")
        }
        // `git reset --hard` overwrites/deletes untracked files that sit where the
        // target version has a tracked file. Ignored ones are in no commit, so the
        // hidden backup ref could not recover their content: refuse instead of
        // silently losing it (v4.2.26).
        let conflicts = try await ignoredFilesInTheWay(ofTarget: hash, path: path)
        if !conflicts.isEmpty {
            throw HistoryError.rollbackWouldOverwriteIgnored(files: conflicts)
        }
        let head = try await runner.run(["rev-parse", "HEAD"], cwd: path)
        guard head.succeeded else {
            throw HistoryError.resetFailed(
                stderr: NSLocalizedString("无法读取当前版本，回滚前的备份点未写入", comment: "reset error"))
        }
        let headHash = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headHash.isEmpty else {
            throw HistoryError.resetFailed(
                stderr: NSLocalizedString("无法读取当前版本，回滚前的备份点未写入", comment: "reset error"))
        }
        // The promised safety net is only real if this ref exists: a swallowed
        // failure made "找不回被回滚的版本" possible on a full disk / locked refs.
        // A short random suffix keeps two rollbacks in the same second apart.
        let backupRef = "refs/filevault/backup/\(Self.backupStamp())-\(UUID().uuidString.prefix(4))"
        let backup = try await runner.run(["update-ref", backupRef, headHash], cwd: path)
        guard backup.succeeded else {
            throw HistoryError.resetFailed(
                stderr: NSLocalizedString("无法写入回滚前的备份点（refs/filevault/backup），本次回滚已取消",
                                          comment: "reset error"))
        }
        let r = try await runner.run(["reset", "--hard", hash], cwd: path)
        guard r.succeeded else {
            throw HistoryError.resetFailed(stderr: r.stderr)
        }
    }

    /// Whether `file` currently exists as an ignored, untracked file.
    func isIgnoredUntracked(file: String, path: String) async throws -> Bool {
        let r = try await runner.run(["ls-files", "-z", "--others", "--ignored", "--exclude-standard",
                                      "--", file], cwd: path)
        // Fail closed: an unreadable index means "unknown", not "safe" —
        // proceeding could overwrite content that exists in no commit (v4.2.27).
        guard r.succeeded else {
            throw GitCommandError(command: "ls-files --others --ignored",
                                  exitCode: r.exitCode, stderr: r.stderr)
        }
        if !r.stdout.isEmpty { return true }
        // ls-files pathspec matching is case-sensitive even on case-insensitive
        // volumes, so an ignored "Notes.txt" on disk does not show up when asked
        // for "notes.txt" — and `git checkout -- notes.txt` would silently
        // overwrite it (its content exists in no commit). check-ignore folds
        // case per gitignore rules, so use it as the case-variant signal, gated
        // on the path existing on disk and not being tracked under its exact
        // name (v4.2.27).
        guard FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(file)) else {
            return false
        }
        let ignored = try await runner.run(["check-ignore", "-q", "--", file], cwd: path)
        guard ignored.exitCode == 0 else { return false }
        let tracked = try await runner.run(["ls-files", "-z", "--", file], cwd: path)
        guard tracked.succeeded else { return true } // unknown → refuse, never risk it
        return tracked.stdout.isEmpty
    }

    /// Files in the target commit's tree that currently exist on disk as
    /// ignored/untracked files (directly or as a blocking path component).
    /// `git reset --hard` would silently overwrite them (v4.2.26).
    func ignoredFilesInTheWay(ofTarget hash: String, path: String) async throws -> [String] {
        let tree = try await runner.run(["ls-tree", "-r", "--name-only", "-z", hash], cwd: path)
        guard tree.succeeded else {
            throw GitCommandError(command: "ls-tree", exitCode: tree.exitCode, stderr: tree.stderr)
        }
        let targets = tree.stdout.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
        return try await ignoredConflicts(targetPaths: targets, path: path)
    }

    /// Intersection of `targetPaths` with the currently ignored/untracked
    /// files, compared case-insensitively: on case-insensitive volumes (macOS
    /// default) "notes.txt" and "Notes.txt" name the same disk file, so the old
    /// exact-match comparison missed case variants and reset/checkout silently
    /// destroyed ignored content that exists in no commit (v4.2.27). Returns
    /// disk names.
    func ignoredConflicts(targetPaths: [String], path: String) async throws -> [String] {
        let ignored = try await runner.run(["ls-files", "-z", "--others", "--ignored", "--exclude-standard"],
                                           cwd: path)
        guard ignored.succeeded else {
            throw GitCommandError(command: "ls-files --others --ignored", exitCode: ignored.exitCode,
                                  stderr: ignored.stderr)
        }
        let candidates = ignored.stdout.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
        guard !candidates.isEmpty, !targetPaths.isEmpty else { return [] }
        let folded = Set(targetPaths.map { $0.lowercased() })
        return candidates.filter { candidate in
            let f = candidate.lowercased()
            if folded.contains(f) { return true }
            // An ignored FILE blocking a directory the target version needs.
            let prefix = f + "/"
            return folded.contains { $0.hasPrefix(prefix) }
        }.sorted()
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
        // Pulls/merges/repairs also mutate the working tree and index: take the
        // local-mutation slot so the auto-commit pipeline cannot interleave.
        try await acquireLocalOp(path)
        defer { releaseLocalOp(path) }
        let headRef = try await runner.run(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: path)
        let branch = headRef.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard headRef.succeeded, !branch.isEmpty else { throw PullError.detachedHead }

        let target = try await pullTarget(path: path, currentBranch: branch)

        // Local-first: pending edits become a commit before the working tree is
        // touched (same rule as rollback). Otherwise a pull can refuse on dirty
        // files, or a rebase would start with an unstaged state.
        // A status failure (locked index, unreadable repo) aborts BEFORE the
        // working tree is touched, rather than pulling over unbacked-up edits.
        if try await isDirty(path: path) {
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
                    // Append, don't replace: copies preserved by the earlier
                    // protection pass must stay in the report (v4.2.28).
                    movedLocalCopies += moved
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
                // A blocked checkout can leave the rebase machinery half-started;
                // retrying without aborting would fail with "previous rebase in
                // progress" and strand the repo mid-rebase. Abort first (same
                // order as the merge path) (v4.2.28).
                if await rebaseInProgress(path: path) {
                    _ = try? await runner.run(["rebase", "--abort"], cwd: path)
                }
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
        // Pulls/merges/repairs also mutate the working tree and index: take the
        // local-mutation slot so the auto-commit pipeline cannot interleave.
        try await acquireLocalOp(path)
        defer { releaseLocalOp(path) }
        let headRef = try await runner.run(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: path)
        let branch = headRef.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard headRef.succeeded, !branch.isEmpty else { throw PullError.detachedHead }

        let target = try await pullTarget(path: path, currentBranch: branch)

        // Preserve pending edits in history first (same rule as rollback).
        // Fail closed: a status failure means "unknown", and reset --hard would
        // silently destroy edits we failed to commit, so refuse instead of
        // proceeding (v4.2.25).
        do {
            if try await isDirty(path: path) {
                _ = try? await commitAll(path: path, message: "auto: 强制拉取前自动保存未提交改动")
            }
            guard try !(await isDirty(path: path)) else {
                throw PullError.localChanges(detail: "")
            }
        } catch let error as PullError {
            throw error
        } catch {
            throw PullError.localChanges(detail: (error as? GitCommandError)?.stderr ?? "")
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
            // Same random suffix as resetRepo: two force-pulls in the same
            // second would otherwise overwrite each other's backup ref, leaving
            // the pushed-aside HEAD unreferenced and gc-able (v4.2.27).
            let ref = "refs/filevault/backup/\(Self.backupStamp())-\(UUID().uuidString.prefix(4))"
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
        if await remoteDisabled(path: path) { throw PullError.noRemote }
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

    /// Remote/branch a push should target (v4.2.25): the configured upstream
    /// when there is one, otherwise origin, otherwise the only configured
    /// remote — the same choice a pull makes. The old code hard-coded "origin",
    /// so an adopted repo whose remote is named differently could pull fine but
    /// never push ("'origin' does not appear to be a git repository").
    public func pushTarget(path: String, currentBranch: String) async throws -> (remote: String, branch: String) {
        try await pullTarget(path: path, currentBranch: currentBranch)
    }

    /// Name of the remote a connectivity probe should use: the upstream's
    /// remote when configured, else origin, else the only/first remote.
    public func defaultRemoteName(path: String) async -> String? {
        // App-side sync stop: probing a disabled remote would let "测试连接"
        // report success for a repo the app no longer syncs, and could make
        // AuthMonitor probe a remote the sync paths never use (v4.2.27).
        if await remoteDisabled(path: path) { return nil }
        let names = await allRemotes(path: path).map(\.name)
        guard !names.isEmpty else { return nil }
        if let upstream = try? await runner.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
                                                cwd: path),
           upstream.succeeded {
            let full = upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = full.firstIndex(of: "/") {
                let remote = String(full[..<slash])
                if names.contains(remote) { return remote }
            }
        }
        if names.contains("origin") { return "origin" }
        // Multi-remote without upstream is ambiguous exactly like pullTarget:
        // guessing sorted()[0] could probe a remote the app never syncs (v4.2.27).
        return names.count == 1 ? names[0] : nil
        // NOTE: callers that need *some* name must use pullTarget/pushTarget
        // instead of guessing (v4.2.27).
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
        guard let r = try? await runner.run(["diff", "--name-only", "-z", "--diff-filter=U"], cwd: path),
              r.succeeded else { return [] }
        return r.stdout.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
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

    /// PID of ANOTHER live FileVault instance currently managing this folder
    /// (two copies of the app must never commit/push the same repo) (v4.2.9).
    public func foreignInstancePID(path: String) -> Int32? {
        let file = (Self.gitDirectory(forRepoAt: path) as NSString)
            .appendingPathComponent("filevault-instance.pid")
        guard let raw = try? String(contentsOfFile: file, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, pid != getpid() else { return nil }
        return isProcessAlive(pid) ? pid : nil
    }

    /// Take the per-folder instance lock. Returns false when another LIVE
    /// FileVault instance owns it; a stale lock from a crashed run is taken over.
    @discardableResult
    public func acquireInstanceLock(path: String) -> Bool {
        if foreignInstancePID(path: path) != nil { return false }
        let file = (Self.gitDirectory(forRepoAt: path) as NSString)
            .appendingPathComponent("filevault-instance.pid")
        // Fail closed: when the lock cannot be written (weird .git layout, read-
        // only repo) a second instance must not believe it owns the folder.
        // Read-back check: two instances racing `write` could each believe they
        // own the folder (last writer wins); after writing, the file must really
        // name THIS process (v4.2.28).
        do {
            try Data(String(getpid()).utf8).write(to: URL(fileURLWithPath: file))
        } catch {
            return false
        }
        guard let raw = try? String(contentsOfFile: file, encoding: .utf8),
              raw.trimmingCharacters(in: .whitespacesAndNewlines) == String(getpid()) else {
            return false
        }
        return true
    }

    /// Release the instance lock only when this process owns it.
    public func releaseInstanceLock(path: String) {
        let file = (Self.gitDirectory(forRepoAt: path) as NSString)
            .appendingPathComponent("filevault-instance.pid")
        guard let raw = try? String(contentsOfFile: file, encoding: .utf8),
              raw.trimmingCharacters(in: .whitespacesAndNewlines) == String(getpid()) else { return }
        try? FileManager.default.removeItem(atPath: file)
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Absolute git directory of a repo, resolving a `.git` FILE (worktrees and
    /// linked checkouts) and a linked worktree's `commondir`. Everything that
    /// must live inside the repository (info/exclude, the instance lock) goes
    /// through here instead of hard-coding "<repo>/.git/…" (v4.2.25).
    static func gitDirectory(forRepoAt path: String) -> String {
        let dotGit = (path as NSString).appendingPathComponent(".git")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dotGit),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let content = try? String(contentsOfFile: dotGit, encoding: .utf8) else {
            return dotGit
        }
        let first = content.split(separator: "\n").first.map(String.init) ?? ""
        let prefix = "gitdir:"
        guard first.hasPrefix(prefix) else { return dotGit }
        var dir = first.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        if !dir.hasPrefix("/") { dir = (path as NSString).appendingPathComponent(dir) }
        dir = (dir as NSString).standardizingPath
        // Linked worktrees keep their own gitdir; shared files (info/exclude)
        // live in the common directory pointed to by "commondir".
        let commonFile = (dir as NSString).appendingPathComponent("commondir")
        if let shared = try? String(contentsOfFile: commonFile, encoding: .utf8) {
            var common = shared.trimmingCharacters(in: .whitespacesAndNewlines)
            if !common.hasPrefix("/") { common = (dir as NSString).appendingPathComponent(common) }
            return (common as NSString).standardizingPath
        }
        return dir
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
        // Pulls/merges/repairs also mutate the working tree and index: take the
        // local-mutation slot so the auto-commit pipeline cannot interleave.
        try await acquireLocalOp(path)
        defer { releaseLocalOp(path) }
        let headRef = try await runner.run(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: path)
        let branch = headRef.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard headRef.succeeded, !branch.isEmpty else { throw PullError.detachedHead }
        let target = try await pullTarget(path: path, currentBranch: branch)

        // Local-first: pending edits become a commit (fail closed when that is
        // impossible - the merge must not lose them).
        do {
            if try await isDirty(path: path) {
                _ = try? await commitAll(path: path, message: "auto: 同步前自动保存未提交改动")
            }
            guard try !(await isDirty(path: path)) else { throw PullError.localChanges(detail: "") }
        } catch let error as PullError {
            throw error
        } catch {
            throw PullError.localChanges(detail: (error as? GitCommandError)?.stderr ?? "")
        }

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
        // Same random suffix as resetRepo/forcePull: two merge-syncs in the
        // same second would otherwise overwrite each other's backup ref,
        // leaving the pushed-aside HEAD unreferenced and gc-able (v4.2.28).
        var backupRef: String?
        let ref = "refs/filevault/backup/\(Self.backupStamp())-\(UUID().uuidString.prefix(4))"
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
                    // This copy must reach the remote: if the file name happens to
                    // match a .gitignore pattern (e.g. ".env"), a plain add fails
                    // silently and the "remote version kept" promise is a lie
                    // (v4.2.26). -f is deliberate: it is FileVault-generated data.
                    let added = try await runner.run(["add", "-f", "--", copyPath], cwd: path)
                    guard added.succeeded else {
                        throw HistoryError.restoreFailed(stderr: added.stderr)
                    }
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
        let commit = try await runner.run(["commit", "--no-verify", "-m", "sync: 同步远程文件到本地（保留本地文件）"], cwd: path)
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

    /// Names of the configured remotes (for choosing which one to sync with).
    public func remoteNames(path: String) async -> [String] {
        await allRemotes(path: path).map(\.name)
    }

    /// Point the current branch's upstream at `remote` (used when several
    /// remotes exist and a pull needs an explicit choice). Works even when the
    /// remote branch does not exist yet: the next push -u creates it.
    public func setUpstreamRemote(path: String, remote: String) async throws {
        let head = try await runner.run(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: path)
        let branch = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.succeeded, !branch.isEmpty else { throw PullError.detachedHead }
        let r1 = try await runner.run(["config", "branch." + branch + ".remote", remote], cwd: path)
        guard r1.succeeded else {
            throw GitCommandError(command: "config branch.remote", exitCode: r1.exitCode, stderr: r1.stderr)
        }
        let r2 = try await runner.run(["config", "branch." + branch + ".merge", "refs/heads/" + branch],
                                      cwd: path)
        guard r2.succeeded else {
            throw GitCommandError(command: "config branch.merge", exitCode: r2.exitCode, stderr: r2.stderr)
        }
        // Choosing the sync remote is an explicit sync intent (v4.2.26).
        await setRemoteDisabled(path: path, disabled: false)
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
                // The copy must stay out of version control. It holds content
                // the user deliberately ignored (often secrets); without a rule
                // the next auto-commit would add it and push it to the remote
                // (v4.2.25).
                _ = appendExcludeRule(path: path, section: Self.preservedCopyMarkerComment,
                                      rule: Self.escapedExcludeRule(copy))
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
            guard let r = try? await runner.run(["ls-tree", "-r", "--name-only", "-z", tip], cwd: path),
                  r.succeeded else { return (0, 0) }
            let count = r.stdout.split(separator: "\0").filter { !$0.isEmpty }.count
            return old == nil ? (count, 0) : (0, count)
        }
        guard let r = try? await runner.run(["diff", "--name-status", "-z", old, new], cwd: path),
              r.succeeded else { return (0, 0) }
        let fields = r.stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var added = 0
        var deleted = 0
        var i = 0
        while i < fields.count {
            let status = fields[i]
            i += 1
            guard let first = status.first else { continue }
            // Renames/copies carry two path fields; a plain change carries one.
            i += (first == "R" || first == "C") ? 2 : 1
            switch first {
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
        // -z keeps unusual names (newlines/quotes) intact (v4.2.10).
        guard let r = try? await runner.run(["ls-files", "-z"], cwd: path), r.succeeded else { return [] }
        return r.stdout.split(separator: "\0").map(String.init).filter { !$0.isEmpty }.sorted()
    }

    // MARK: - Large file protection (FR-12)

    public static let largeFileMarkerComment = "# filevault-excluded-large-file"
    /// Section for nested repos excluded because they could not be staged
    /// (unborn-HEAD gitlink staging exits 128): auto-commit of the outer repo
    /// must keep working (v4.2.27).
    public static let nestedRepoMarkerComment = "# filevault-excluded-nested-repo"
    /// Section for local copies preserved while syncing. They hold content the
    /// user deliberately ignored, so they must stay ignored (never committed to
    /// a remote) (v4.2.25).
    public static let preservedCopyMarkerComment = "# filevault-preserved-copy"

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
        for e in entries where e.change != .deleted {
            let abs = (path as NSString).appendingPathComponent(e.path)
            if let attrs = try? fm.attributesOfItem(atPath: abs),
               let size = attrs[.size] as? UInt64, size > threshold {
                // Escape glob characters and original rule and verify with git itself: a raw rule
                // like "a[1].bin" matches nothing, so the file was still added,
                // pushed (and rejected) while the user was told it was excluded.
                let rule = Self.escapedExcludeRule(e.path)
                // For tracked files the rule is bookkeeping only (gitignore
                // never applies to tracked files; commitAll unstages them
                // after add -A). Notify only when the rule is NEW, or a file
                // that stays oversized would re-notify on every pipeline run.
                let pre = try? await runner.run(["check-ignore", "-q", "--", e.path], cwd: path)
                let alreadyIgnored = pre?.exitCode == 0
                _ = appendExcludeRule(path: path, section: Self.largeFileMarkerComment, rule: rule)
                if e.change == .added {
                    if let check = try? await runner.run(["check-ignore", "-q", "--", e.path], cwd: path),
                       check.exitCode == 0 {
                        excluded.append(e.path)
                    }
                } else {
                    // Tracked-oversized: notify only when the rule is NEW.
                    if !alreadyIgnored, let check = try? await runner.run(["check-ignore", "-q", "--", e.path], cwd: path),
                       check.exitCode == 0 {
                        excluded.append(e.path)
                    }
                }
            }
        }
        return excluded
    }

    /// Paths that were auto-excluded because they exceed the remote's single
    /// file limit (recorded in .git/info/exclude). They are NOT versioned, so
    /// the UI must say so instead of leaving them silently unprotected (v4.2.6).
    public func excludedLargeFiles(path: String) -> [String] {
        let file = (Self.gitDirectory(forRepoAt: path) as NSString).appendingPathComponent("info/exclude")
        guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        var rules: [String] = []
        var section: String?
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Only our large-file section; preserved-copy rules are not "backup
            // failures" and must not be shown as such.
            if trimmed.hasPrefix("# filevault-") {
                section = trimmed
                continue
            }
            guard section == Self.largeFileMarkerComment,
                  !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let rule = Self.unescapedExcludeRule(trimmed)
            // Only report rules whose file still exists: a deleted/moved file
            // kept the warning "N 个大文件未同步" alive forever (v4.2.27).
            if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(rule)) {
                rules.append(rule)
            }
        }
        return rules
    }

    /// Make a repo-relative path a literal gitignore pattern. Wildcards would
    /// otherwise turn "a[1].bin" / "what?.txt" into patterns that match nothing
    /// (v4.2.25).
    public static func escapedExcludeRule(_ raw: String) -> String {
        var out = ""
        for ch in raw {
            if "*?[]\\".contains(ch) {
                out.append("\\")
            }
            out.append(ch)
        }
        if out.hasPrefix("#") || out.hasPrefix("!") { out = "\\" + out }
        // Trailing spaces are stripped by gitignore unless escaped.
        var trailing = 0
        for ch in out.reversed() {
            if ch == " " { trailing += 1 } else { break }
        }
        if trailing > 0 {
            out = String(out.dropLast(trailing)) + String(repeating: "\\ ", count: trailing)
        }
        return out
    }

    /// Best-effort display form of a stored exclude rule.
    public static func unescapedExcludeRule(_ rule: String) -> String {
        var out = ""
        var escaped = false
        for ch in rule {
            if escaped {
                out.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Append a rule to <gitdir>/info/exclude under the given section marker.
    /// Duplicates are detected per LINE (the old substring test let "big.bin"
    /// suppress "big.bin2"). Returns whether the rule is on disk afterwards.
    @discardableResult
    private func appendExcludeRule(path: String, section: String, rule: String) -> Bool {
        let file = URL(fileURLWithPath: Self.gitDirectory(forRepoAt: path))
            .appendingPathComponent("info/exclude")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let lines = current.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.contains(rule) { return true }
        var out = current
        if !current.isEmpty && !current.hasSuffix("\n") { out += "\n" }
        if !lines.contains(section) { out += section + "\n" }
        out += rule + "\n"
        do {
            try out.write(to: file, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
