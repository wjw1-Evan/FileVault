import Foundation

/// Per-repo credential storage for HTTPS remotes (v2.1.0; v4.0.2 rework).
///
/// Tokens NEVER go into git config: they are handed to a git credential helper.
/// Preferred backend is Apple's `git credential-osxkeychain` (Keychain). A Mac
/// without Xcode / Command Line Tools has no such helper — our bundled git cannot
/// ship Apple's binary — so we fall back to git's own `store` helper pointed at a
/// 0600 file that only the current user can read.
public enum CredentialStore {
    public enum CredentialError: Error, LocalizedError {
        case helperUnavailable
        case storeFailed(String)
        case eraseFailed(String)

        public var errorDescription: String? {
            switch self {
            case .helperUnavailable:
                return NSLocalizedString("本机凭证库不可用（请确认 git 安装完整）", comment: "credential error")
            case .storeFailed(let m):
                return String(format: NSLocalizedString("凭证写入本机凭证库失败：%@", comment: "credential error"), m)
            case .eraseFailed(let m):
                return String(format: NSLocalizedString("凭证擦除失败：%@", comment: "credential error"), m)
            }
        }
    }

    /// Where the helper ends up keeping the secret.
    public enum CredentialBackend: Equatable, Sendable {
        /// Apple keychain helper (system git / Xcode / Command Line Tools).
        case keychain
        /// Built-in `store` helper writing a 0600 file at the given path.
        case file(String)
        /// No helper could be configured.
        case unavailable

        public var isPrivateFile: Bool {
            if case .file = self { return true }
            return false
        }
    }

    /// ~/Library/Application Support/FileVault/git-credentials (fallback only).
    public static var defaultStoreFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("FileVault/git-credentials")
    }

    public static func isAvailable(runner: GitRunner) async -> Bool {
        // osxkeychain helper presence (bundled with Apple git).
        guard let r = try? await runner.run(["credential-osxkeychain"], timeout: 5) else { return false }
        return r.exitCode != 127
    }

    /// Make sure the repository has a usable credential helper, configuring one
    /// when absent. An existing user helper (gh, custom) is respected untouched.
    ///
    /// Why this matters: choosing "username + access token" used to store nothing
    /// because no helper was configured — `git credential approve` had nowhere
    /// to write. This is the missing half of FR-06's PAT mode.
    @discardableResult
    public static func prepare(runner: GitRunner, repoPath: String,
                               storeFile: URL? = nil) async -> CredentialBackend {
        if let existing = try? await runner.run(["config", "--local", "--get-all", "credential.helper"],
                                                cwd: repoPath),
           existing.succeeded {
            // Latest non-empty value wins; "" entries are the reset markers git
            // uses to drop inherited helpers.
            let values = existing.stdout.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if let value = values.last {
                if value.contains("store") {
                    return .file(storePath(fromHelperValue: value) ?? "")
                }
                return .keychain
            }
        }

        // The user explicitly picked "username + access token" for this repo:
        // take over the helper chain so an inherited gh/custom helper cannot
        // shadow (or swallow) the token. An empty value resets the inherited list.
        if await isAvailable(runner: runner) {
            await installHelper(["", "osxkeychain"], runner: runner, repoPath: repoPath)
            return .keychain
        }

        // No keychain helper on this Mac: private file via git's own store helper.
        let file = storeFile ?? defaultStoreFile
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        // Quote the path: "Application Support" contains a space.
        let value = "store --file=\"" + file.path + "\""
        guard await installHelper(["", value], runner: runner, repoPath: repoPath) else {
            return .unavailable
        }
        return .file(file.path)
    }

    /// Store username/password for a repo URL through the configured helpers.
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

    /// Replace this repo's helper list with the given values (first entry resets
    /// inherited helpers). Returns false when git rejects the configuration.
    private static func installHelper(_ values: [String], runner: GitRunner, repoPath: String) async -> Bool {
        guard let first = values.first else { return false }
        guard let reset = try? await runner.run(["config", "--local", "--replace-all", "credential.helper", first],
                                                cwd: repoPath), reset.succeeded else { return false }
        for value in values.dropFirst() {
            guard let add = try? await runner.run(["config", "--local", "--add", "credential.helper", value],
                                                  cwd: repoPath), add.succeeded else { return false }
        }
        return true
    }

    /// Pull the path out of a configured store --file=... helper value.
    static func storePath(fromHelperValue value: String) -> String? {
        guard let range = value.range(of: "--file=") else { return nil }
        var path = String(value[range.upperBound...])
        if path.hasPrefix("\"") {
            path.removeFirst()
            if path.hasSuffix("\"") { path.removeLast() }
        }
        return path.isEmpty ? nil : path
    }
}
