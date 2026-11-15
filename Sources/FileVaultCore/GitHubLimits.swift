import Foundation

/// GitHub repository file-size ceilings and remote-aware threshold resolution
/// (FR-12, v3.1.3).
///
/// GitHub's pre-receive hook rejects a push as soon as one blob exceeds
/// 100 MiB, and only warns above 50 MiB. FileVault's user-facing threshold
/// defaults to 200 MB, which is fine for self-hosted remotes but guarantees a
/// failed push on github.com. The commit pipeline therefore resolves the
/// threshold per repository: github.com is capped at the hard limit, every
/// other remote keeps the user's configured value.
public enum GitHubLimits {
    /// GitHub warns (but still accepts) blobs above this size.
    public static let warnBytes: UInt64 = 50 * 1024 * 1024
    /// GitHub rejects the whole push when a single blob exceeds this size.
    public static let blockBytes: UInt64 = 100 * 1024 * 1024
    /// Largest single file Git LFS accepts (Free/Pro plans).
    public static let lfsMaxBytes: UInt64 = 2 * 1024 * 1024 * 1024
    /// Repository size GitHub recommends staying under.
    public static let repoRecommendedBytes: UInt64 = 1 * 1024 * 1024 * 1024
    /// Repository size GitHub hard-caps.
    public static let repoHardBytes: UInt64 = 5 * 1024 * 1024 * 1024

    /// Host component of a Git remote URL.
    ///
    /// Understands `https://`, `http://`, `ssh://` and scp-like
    /// `git@host:path` forms, strips credentials and ports, and returns nil for
    /// local paths (`/tmp/bare.git`, `file:///...`) so they are never mistaken
    /// for GitHub. Only the exact `github.com` / `www.github.com` hosts match the
    /// built-in limits; GitHub Enterprise custom domains stay on the user
    /// threshold for now.
    public static func remoteHost(_ url: String?) -> String? {
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        var authority: Substring
        if let scheme = raw.range(of: "://") {
            authority = raw[scheme.upperBound...]
            if let slash = authority.firstIndex(of: "/") { authority = authority[..<slash] }
        } else if let colon = raw.firstIndex(of: ":") {
            // scp-like syntax: [user@]host:path
            authority = raw[..<colon]
        } else {
            return nil
        }
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        if let colon = authority.firstIndex(of: ":") { authority = authority[..<colon] }
        let host = authority.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty, !host.contains("/") else { return nil }
        return host
    }

    /// Whether a remote points at github.com (the only host with built-in limits).
    public static func isGitHubRemote(_ url: String?) -> Bool {
        guard let host = remoteHost(url) else { return false }
        return host == "github.com" || host == "www.github.com"
    }

    /// Per-repo single-file ceiling derived from the remote (v3.1.3).
    ///
    /// There is no local threshold setting: github.com repos inherit GitHub's
    /// 100 MiB hard limit, and every other remote (GitLab, self-hosted, network
    /// drive) or no remote has no known single-file ceiling, returned as `0`
    /// which means "do not exclude anything". The remote value always wins, so
    /// the UI simply mirrors what the remote will accept.
    public static func effectiveThreshold(remoteURL: String?) -> UInt64 {
        isGitHubRemote(remoteURL) ? blockBytes : 0
    }
}
