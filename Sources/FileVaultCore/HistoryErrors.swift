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
            return "路径不合法：\(file)（不能是绝对路径或包含 ..）"
        case .fileNotInCommit(let file, let hash):
            return "该版本（\(hash)）里没有文件 \(file)，无法恢复"
        case .commitNotFound(let hash):
            return "找不到提交 \(hash)，可能已被清理"
        case .resetFailed(let stderr):
            return "回滚失败：\(stderr.isEmpty ? "未知错误" : stderr)"
        }
    }
}
