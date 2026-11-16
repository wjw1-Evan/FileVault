import Foundation

public extension SyncManager {
    /// Connectivity outcome for FR-17.
    struct ConnectivityResult: Sendable {
        public var ok: Bool
        public var detail: String
    }

    /// Verify the remote is reachable and credentials work (FR-17).
    /// Uses `git ls-remote origin HEAD` — supports local paths, SSH and HTTPS remotes.
    func testConnectivity(repoPath: String) async -> ConnectivityResult {
        guard let remote = await repoManager.defaultRemoteName(path: repoPath) else {
            return ConnectivityResult(ok: false, detail: NSLocalizedString("未配置远程仓库", comment: "connectivity"))
        }
        do {
            let r = try await repoManager.runner.run(["ls-remote", remote, "HEAD"], cwd: repoPath, timeout: 20)
            if r.succeeded {
                return ConnectivityResult(ok: true, detail: NSLocalizedString("连接成功", comment: "connectivity"))
            }
            // Use the WHOLE condensed stderr, not its last line: SSH auth
            // failures end with a hint line; the actual reason
            // (Permission denied (publickey)) is earlier, so the UI and
            // AuthMonitor could not classify a real auth problem (v4.2.26).
            let condensed = PullError.condense(r.stderr)
            let reason = condensed.isEmpty
                ? NSLocalizedString("未知错误", comment: "connectivity")
                : condensed
            return ConnectivityResult(ok: false, detail: reason)
        } catch {
            return ConnectivityResult(ok: false, detail: NSLocalizedString("连接超时或无法执行 git", comment: "connectivity"))
        }
    }
}

public extension RepoManager {
    /// Why reading/writing .gitignore failed (readable, never silent).
    enum GitignoreError: Error, LocalizedError {
        /// The existing file is not valid UTF-8: saving an empty draft over it
        /// would silently destroy the user's ignore rules (v4.2.26).
        case notUTF8(path: String)
        case readFailed(path: String, reason: String)
        case writeFailed(path: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .notUTF8(let path):
                return String(format: NSLocalizedString("无法以 UTF-8 读取 %@；为避免覆盖原有规则，已取消编辑，请用文本编辑器处理。",
                                                        comment: "gitignore error"), path)
            case .readFailed(let path, let reason):
                return String(format: NSLocalizedString("读取 %@ 失败：%@", comment: "gitignore error"), path, reason)
            case .writeFailed(let path, let reason):
                return String(format: NSLocalizedString("保存 %@ 失败：%@（规则未改动）", comment: "gitignore error"), path, reason)
            }
        }
    }

    /// Read the current .gitignore content (FR-14 editing support).
    ///
    /// Throws instead of returning "" so the editor can never show an empty
    /// draft and then overwrite the user's real rules on save (v4.2.26).
    func readGitignore(path: String) throws -> String {
        let file = (path as NSString).appendingPathComponent(".gitignore")
        guard FileManager.default.fileExists(atPath: file) else { return "" }
        guard let data = FileManager.default.contents(atPath: file) else {
            throw GitignoreError.readFailed(path: file, reason: NSLocalizedString("文件不可读", comment: "gitignore error"))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitignoreError.notUTF8(path: file)
        }
        return text
    }

    /// Save the .gitignore content (FR-14 editing support). Throws on failure so
    /// the UI can keep the sheet open and show the reason (v4.2.26).
    func saveGitignore(path: String, content: String) throws {
        let file = (path as NSString).appendingPathComponent(".gitignore")
        do {
            try content.write(toFile: file, atomically: true, encoding: .utf8)
        } catch {
            throw GitignoreError.writeFailed(path: file, reason: error.localizedDescription)
        }
    }
}
