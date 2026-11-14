import Foundation

/// macOS keychain credential storage via `git credential-osxkeychain`
/// (v2.1.0 per-repo authentication). Tokens live ONLY in the keychain.
public enum CredentialStore {
    public enum CredentialError: Error, LocalizedError {
        case helperUnavailable
        case storeFailed(String)
        case eraseFailed(String)

        public var errorDescription: String? {
            switch self {
            case .helperUnavailable: return "git credential-osxkeychain 不可用（请确认 git 安装完整）"
            case .storeFailed(let m): return "凭证写入钥匙串失败: " + m
            case .eraseFailed(let m): return "凭证擦除失败: " + m
            }
        }
    }

    public static func isAvailable(runner: GitRunner) async -> Bool {
        // osxkeychain helper presence (bundled with Apple git).
        guard let r = try? await runner.run(["credential-osxkeychain"], timeout: 5) else { return false }
        return r.exitCode != 127
    }

    /// Store username/password for a repo URL in the user keychain.
    public static func store(runner: GitRunner, url: String, username: String, password: String) async throws {
        // `git credential approve` routes through ALL configured helpers with
        // proper URL matching (raw helper calls bypass URL matching).
        let input = "url=" + url + "\nusername=" + username + "\npassword=" + password + "\n"
        let r = try await runner.run(["credential", "approve"], timeout: 10, stdin: input)
        guard r.succeeded else { throw CredentialError.storeFailed(r.stderr) }
    }

    /// Read stored credentials (host+path match). Returns username/password.
    public static func fill(runner: GitRunner, url: String) async -> (username: String, password: String)? {
        let input = "url=" + url + "\n"
        // GIT_TERMINAL_PROMPT=0: never hang on an interactive username prompt.
        guard let r = try? await runner.run(["credential", "fill"], timeout: 15, stdin: input,
                                            env: ["GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "echo", "SSH_ASKPASS": "echo"]),
              r.succeeded else { return nil }
        var user: String?
        var pass: String?
        for line in r.stdout.split(separator: "\n") {
            if line.hasPrefix("username=") { user = String(line.dropFirst(9)) }
            if line.hasPrefix("password=") { pass = String(line.dropFirst(9)) }
        }
        guard let user, let pass else { return nil }
        return (user, pass)
    }

    /// Remove stored credentials for a repo URL.
    public static func erase(runner: GitRunner, url: String) async throws {
        let input = "url=" + url + "\n"
        let r = try await runner.run(["credential", "reject"], timeout: 10, stdin: input)
        guard r.succeeded else { throw CredentialError.eraseFailed(r.stderr) }
    }
}
