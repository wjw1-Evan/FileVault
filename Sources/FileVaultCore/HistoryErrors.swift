import Foundation

/// History browsing / rollback failures (FR-10, v3.3.1).
///
/// Previously `restoreFile`/`resetRepo` ignored git's exit code, so restoring a
/// file that never existed in the target commit looked like a success and a
/// reset to a bogus hash silently did nothing.
public enum HistoryError: Error, LocalizedError, Equatable {
    case invalidPath(String)
    case fileNotInCommit(file: String, hash: String)
    case commitNotFound(String)
    case resetFailed(stderr: String)
    case exportFailed(file: String)
    case invalidTagName(String)
    case directoryNotInCommit(directory: String, hash: String)
    case restoreFailed(stderr: String)
    /// A directory sits at the path a file must be restored to (v4.2.14).
    case restoreTargetIsDirectory(file: String)
    /// Rolling back would delete files that are NOT under version control
    /// (ignored/untracked), e.g. a .env inside a folder restored away (v4.2.16).
    case rollbackWouldDeleteUntracked(directory: String, files: [String])
    /// Rolling back with `git reset --hard` would silently overwrite files that
    /// are currently ignored/untracked but tracked in the target version: their
    /// content is in no commit, so it would be lost forever (v4.2.26).
    case rollbackWouldOverwriteIgnored(files: [String])
    /// Restoring one file would overwrite an ignored/untracked file at that path
    /// (same data-loss shape as above) (v4.2.26).
    case restoreWouldOverwriteIgnored(file: String)
    /// A pull/rebase/merge (or another restore) currently owns the repository.
    case repositoryBusy

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let file):
            return String(format: NSLocalizedString("路径不合法：%@（不能是绝对路径或包含 ..）",
                                                   comment: "history error"), file)
        case .fileNotInCommit(let file, let hash):
            return String(format: NSLocalizedString("该版本（%@）里没有文件 %@，无法恢复",
                                                   comment: "history error"), hash, file)
        case .commitNotFound(let hash):
            return String(format: NSLocalizedString("找不到提交 %@，可能已被清理",
                                                   comment: "history error"), hash)
        case .resetFailed(let stderr):
            return stderr.isEmpty ? NSLocalizedString("未知错误", comment: "history error") : stderr
        case .exportFailed(let file):
            return String(format: NSLocalizedString("无法打开 %@（版本内容缺失或不可读）", comment: "history error"), file)
        case .invalidTagName(let name):
            return String(format: NSLocalizedString("标签名不合法：%@（不能包含空格或 ~ ^ : ? * [ 等字符）",
                                                   comment: "history error"), name)
        case .directoryNotInCommit(let directory, let hash):
            return String(format: NSLocalizedString("该版本（%@）里没有文件夹 %@，无法恢复",
                                                   comment: "history error"), hash, directory)
        case .restoreFailed(let stderr):
            let reason = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return reason.isEmpty ? NSLocalizedString("未知错误", comment: "history error") : reason
        case .restoreTargetIsDirectory(let file):
            return String(format: NSLocalizedString("「%@」现在是一个文件夹，请先把它改名或移走再恢复",
                                                    comment: "history error"), file)
        case .repositoryBusy:
            return NSLocalizedString("正在与远程同步（拉取/合并）或执行另一个恢复操作，请稍后再试",
                                     comment: "history error")
        case .rollbackWouldOverwriteIgnored(let files):
            let names = files.prefix(3).joined(separator: "、")
            let more = files.count > 3
                ? String(format: NSLocalizedString(" 等 %d 个文件", comment: "history error"), files.count)
                : ""
            return String(format: NSLocalizedString("回滚会覆盖未纳入版本管理（被忽略）的文件：%@%@；请先把它们移走或改名后再回滚",
                                                    comment: "history error"), names, more)
        case .restoreWouldOverwriteIgnored(let file):
            return String(format: NSLocalizedString("「%@」当前是被忽略、未纳入版本管理的文件，恢复会覆盖它；请先把它改名或移走再恢复",
                                                    comment: "history error"), file)
        case .rollbackWouldDeleteUntracked(let directory, let files):
            let names = files.prefix(3).joined(separator: "、")
            let more = files.count > 3
                ? String(format: NSLocalizedString(" 等 %d 个文件", comment: "history error"), files.count)
                : ""
            return String(format: NSLocalizedString("回滚会删除文件夹 %@ 里未纳入版本管理的文件：%@%@；请先移走它们或把它们纳入版本管理后再回滚",
                                                    comment: "history error"),
                          directory, names, more)
        }
    }
}
