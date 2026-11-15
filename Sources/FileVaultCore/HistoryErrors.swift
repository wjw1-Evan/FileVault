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
            let reason = stderr.isEmpty ? NSLocalizedString("未知错误", comment: "history error") : stderr
            return String(format: NSLocalizedString("回滚失败：%@", comment: "history error"), reason)
        }
    }
}
