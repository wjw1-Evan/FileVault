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
        let hasRemote = await repoManager.remoteURL(path: repoPath) != nil
        guard hasRemote else {
            return ConnectivityResult(ok: false, detail: NSLocalizedString("未配置远程仓库", comment: "connectivity"))
        }
        do {
            let r = try await repoManager.runner.run(["ls-remote", "origin", "HEAD"], cwd: repoPath, timeout: 20)
            if r.succeeded {
                return ConnectivityResult(ok: true, detail: NSLocalizedString("连接成功", comment: "connectivity"))
            }
            let reason = r.stderr.split(separator: "\n").last.map(String.init)
                ?? NSLocalizedString("未知错误", comment: "connectivity")
            return ConnectivityResult(ok: false, detail: reason)
        } catch {
            return ConnectivityResult(ok: false, detail: NSLocalizedString("连接超时或无法执行 git", comment: "connectivity"))
        }
    }
}

public extension RepoManager {
    /// Read the current .gitignore content (FR-14 editing support).
    func gitignore(path: String) -> String {
        let file = (path as NSString).appendingPathComponent(".gitignore")
        return (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
    }

    /// Save the .gitignore content (FR-14 editing support).
    func saveGitignore(path: String, content: String) {
        let file = (path as NSString).appendingPathComponent(".gitignore")
        try? content.write(toFile: file, atomically: true, encoding: .utf8)
    }
}
