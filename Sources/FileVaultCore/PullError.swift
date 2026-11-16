import Foundation

/// Why a pull failed, stated in terms a normal user can act on (v4.1.1).
///
/// Before this type existed, `RepoManager.pull` wrapped every failure in a
/// `GitCommandError`. That struct did not conform to `LocalizedError`, so the
/// settings window rendered Foundation's generic text
/// ("The operation couldn't be completed. (FileVaultCore.GitCommandError error 1.)").
/// The pull command also omitted the branch argument (`git pull --ff-only origin`),
/// so any repository without an upstream ref — e.g. a fresh FileVault repo whose
/// first push never succeeded — failed before git even fetched anything.
public enum PullError: Error, LocalizedError, Equatable {
    /// The folder has no remote configured at all.
    case noRemote
    /// Several remotes and no upstream: pulling from a guessed remote could
    /// fast-forward the working tree from the wrong place, so we refuse.
    case ambiguousRemote
    /// The protected folder is not a git repository (moved, deleted, or its
    /// disk is not mounted any more).
    case notARepository
    /// HEAD is detached, so there is no branch to fast-forward.
    case detachedHead
    /// The remote has no branch with the local branch's name (never pushed yet).
    case remoteBranchMissing(remote: String, branch: String)
    /// No common ancestor at all: a new local repo bound to a remote that
    /// already carries a different history.
    case unrelatedHistories
    /// Both sides changed the same file while auto-rebasing. FileVault always
    /// aborts the rebase (so no conflict markers can ever be auto-committed) and
    /// reports the paths instead of leaving the repository half-merged.
    case mergeConflict(files: [String], aborted: Bool)
    case authenticationFailed(detail: String)
    case networkFailed(detail: String)
    case remoteUnavailable(detail: String)
    case localChanges(detail: String)
    case failed(detail: String)

    public var errorDescription: String? {
        switch self {
        case .noRemote:
            return NSLocalizedString("这个文件夹还没有绑定远程仓库，无法拉取", comment: "pull error")
        case .ambiguousRemote:
            return NSLocalizedString("仓库有多个远程，无法确定从哪个拉取", comment: "pull error")
        case .notARepository:
            return NSLocalizedString("这个文件夹已经不是 Git 仓库（可能被移动、删除，或磁盘未挂载）",
                                     comment: "pull error")
        case .detachedHead:
            return NSLocalizedString("仓库当前不在任何分支上，无法拉取", comment: "pull error")
        case .remoteBranchMissing(let remote, let branch):
            return String(format: NSLocalizedString("远程仓库 %@ 还没有 %@ 分支，无法拉取", comment: "pull error"),
                          remote, branch)
        case .unrelatedHistories:
            return NSLocalizedString("远程仓库与本地历史互不相关，不能快进合并", comment: "pull error")
        case .mergeConflict(_, let aborted):
            return aborted
                ? NSLocalizedString("本地与远程改动了同一个文件，自动合并已中止（仓库已恢复原状）",
                                    comment: "pull error")
                : NSLocalizedString("本地与远程改动了同一个文件，自动合并失败且未能自动恢复",
                                    comment: "pull error")
        case .authenticationFailed:
            return NSLocalizedString("身份验证失败或已过期，无法拉取远程仓库", comment: "pull error")
        case .networkFailed:
            return NSLocalizedString("网络连接失败，无法访问远程仓库", comment: "pull error")
        case .remoteUnavailable:
            return NSLocalizedString("无法访问远程仓库（地址有误或没有权限）", comment: "pull error")
        case .localChanges:
            return NSLocalizedString("本地未提交的改动阻碍了拉取", comment: "pull error")
        case .failed(let detail):
            if detail.isEmpty {
                return String(format: NSLocalizedString("拉取失败：%@", comment: "pull error"),
                              NSLocalizedString("未知错误", comment: "pull error"))
            }
            return String(format: NSLocalizedString("拉取失败：%@", comment: "pull error"), detail)
        }
    }

    /// What the user can do about it — shown in the failure alert.
    ///
    /// FileVault deliberately never merges remote history on its own (PRD: a
    /// pull wizard handles conflicts), so the suggestion names the terminal
    /// commands that match the git configuration FileVault itself wrote.
    public var recoverySuggestion: String? {
        switch self {
        case .noRemote:
            return NSLocalizedString("在设置里填写远程仓库地址（留空表示仅本地），保存并连通后再拉取。",
                                     comment: "pull recovery")
        case .ambiguousRemote:
            return NSLocalizedString("在终端执行 git branch --set-upstream-to=<远程>/<分支> 指定上游后再试。",
                                     comment: "pull recovery")
        case .notARepository:
            return NSLocalizedString("确认文件夹还在原位置、磁盘已挂载；若文件夹已被删除，请在设置里移除它。",
                                     comment: "pull recovery")
        case .detachedHead:
            return NSLocalizedString("在终端执行 git switch main 回到主分支后再试。",
                                     comment: "pull recovery")
        case .remoteBranchMissing(let remote, let branch):
            return String(format: NSLocalizedString("先把本地分支推送上去：点「立即推送」，或在终端执行 git push -u %@ %@。",
                                                    comment: "pull recovery"), remote, branch)
        case .unrelatedHistories:
            return NSLocalizedString("这个远程仓库已经有一套自己的历史。若以远程为准，先备份文件夹，再在终端执行 git fetch origin，然后 git reset --hard 远程分支；若以本地为准，需要强制推送（会覆盖远程历史）。",
                                     comment: "pull recovery")
        case .mergeConflict(let files, let aborted):
            let names = Self.fileList(files)
            return aborted
                ? String(format: NSLocalizedString("这次冲突涉及：%@。请在终端执行 git pull --rebase 手动解决冲突后再推送。",
                                                   comment: "pull recovery"), names)
                : String(format: NSLocalizedString("这次冲突涉及：%@。请先在终端执行 git rebase --abort 恢复仓库，再手动处理。",
                                                   comment: "pull recovery"), names)
        case .authenticationFailed:
            return AuthClassifier.guidance()
        case .networkFailed:
            return NSLocalizedString("检查网络或代理设置后重试。", comment: "pull recovery")
        case .remoteUnavailable:
            return NSLocalizedString("核对设置里的远程地址；私有仓库请确认访问令牌有该仓库的读写权限。",
                                     comment: "pull recovery")
        case .localChanges:
            return NSLocalizedString("等自动提交完成（通常 5 秒）后重试。", comment: "pull recovery")
        case .failed:
            return nil
        }
    }

    /// Raw git output, for diagnostics and tests. Never shown verbatim.
    public var technicalDetail: String? {
        switch self {
        case .authenticationFailed(let detail), .networkFailed(let detail),
             .remoteUnavailable(let detail), .localChanges(let detail), .failed(let detail):
            return detail
        case .mergeConflict(let files, _):
            return files.isEmpty ? nil : files.joined(separator: ", ")
        case .noRemote, .ambiguousRemote, .notARepository, .detachedHead,
             .remoteBranchMissing, .unrelatedHistories:
            return nil
        }
    }

    /// "a.md、b.md、c.md 等 5 个文件" — capped so an alert stays readable.
    static func fileList(_ files: [String], limit: Int = 3) -> String {
        guard !files.isEmpty else { return NSLocalizedString("未知文件", comment: "pull conflict files") }
        let shown = files.prefix(limit).joined(separator: "、")
        guard files.count > limit else { return shown }
        return String(format: NSLocalizedString("%@ 等 %d 个文件", comment: "pull conflict files"),
                      shown, files.count)
    }

    // MARK: - Classification

    /// Whether git refused because the two histories cannot be fast-forwarded.
    /// The caller then checks for a common ancestor: related histories are
    /// auto-rebased, unrelated ones are refused.
    public static func isDivergence(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return ["not possible to fast-forward",
                "diverging branches",
                "non-fast-forward",
                "refusing to merge unrelated histories"].contains { text.contains($0) }
    }

    /// Map stderr to a case without asking git anything else.
    ///
    /// Order matters (v4.1.1 review):
    /// 1. Explicit connectivity wording first — an SSH failure
    ///    ("connect to host … Connection refused") also carries git's generic
    ///    "Could not read from remote repository", which would otherwise be
    ///    reported as an authentication problem.
    /// 2. Unreachable/unknown remote next: a private repo answers with
    ///    "repository '<url>' not found", and the message names permissions.
    /// 3. A missing remote branch before authentication, so a branch named
    ///    "sprint-401" is not mistaken for an HTTP 401.
    /// 4. Authentication: `AuthClassifier` only treats 401/403 as auth when
    ///    they appear in their HTTP context, so arbitrary stderr cannot trip it.
    /// 5. Remaining connectivity wording ("unable to access", which git also
    ///    prints around HTTP auth failures) is checked after auth.
    public static func classify(stderr: String, remote: String, branch: String) -> PullError {
        let text = stderr.lowercased()
        let detail = condense(stderr)

        if explicitNetworkMarkers.contains(where: { text.contains($0) }) {
            return .networkFailed(detail: detail)
        }
        let unavailablePatterns = [
            "repository not found", "does not appear to be a git repository",
            "no such remote", "not a git repository",
        ]
        // git words an unknown repo as "repository '<url>' not found", so the
        // two words have to be checked together (not as one contiguous phrase).
        if unavailablePatterns.contains(where: { text.contains($0) })
            || (text.contains("repository") && text.contains("not found")) {
            return .remoteUnavailable(detail: detail)
        }
        if text.contains("couldn't find remote ref") || text.contains("couldn't find remote branch") {
            return .remoteBranchMissing(remote: remote, branch: branch)
        }
        if AuthClassifier.isAuthRelated(stderr) {
            return .authenticationFailed(detail: detail)
        }
        if broadNetworkMarkers.contains(where: { text.contains($0) }) {
            return .networkFailed(detail: detail)
        }
        let localChangePatterns = [
            "would be overwritten", "commit your changes or stash", "your local changes",
            "cannot pull with rebase", "unstaged changes", "uncommitted changes",
        ]
        if localChangePatterns.contains(where: { text.contains($0) }) {
            return .localChanges(detail: detail)
        }
        return .failed(detail: detail)
    }

    /// Unambiguous connectivity failures — checked before auth on purpose.
    private static let explicitNetworkMarkers = [
        "could not resolve host", "connection refused", "connection timed out",
        "operation timed out", "network is unreachable", "connection reset",
        "failed to connect", "could not connect", "no route to host",
        "connection closed", "early eof", "rpc failed", "ssl", "tls",
        "proxy", "ssh: connect to host",
    ]

    /// "unable to access" also wraps HTTP authentication errors, so it is only
    /// consulted after auth has been ruled out.
    private static let broadNetworkMarkers = ["unable to access"]

    /// One readable line from git's multi-line stderr: drop hint lines, squash
    /// whitespace and cap the length so a status label cannot explode.
    public static func condense(_ stderr: String, limit: Int = 400) -> String {
        let lines = stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("hint:") }
        var text = lines.joined(separator: " ")
        if text.count > limit {
            text = String(text.prefix(limit)) + "…"
        }
        return text
    }
}
