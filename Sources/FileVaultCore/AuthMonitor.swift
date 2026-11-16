import Foundation

/// Detects auth-related git failures and classifies user guidance (v2.2.3).
public enum AuthClassifier {
    private static let patterns: [String] = [
        "authentication failed",
        "authentication required",
        "could not read username",
        "could not read password",
        "terminal prompts disabled",
        "invalid username or password",
        "access denied",
        "unauthorized",
        "credential",
        "fatal: could not read from remote repository",
        // Status codes only in their HTTP context (v4.1.1): a bare "401" also
        // matches branch names and URL segments, which mislabelled network
        // failures and missing branches as bad credentials.
        "http 401", "http 403",
        "error: 401", "error: 403",
        "returned error: 401", "returned error: 403",
    ]

    /// Whether a git failure looks like an auth/credential problem.
    public static func isAuthRelated(_ stderr: String) -> Bool {
        let low = stderr.lowercased()
        return patterns.contains { low.contains($0) }
    }

    /// Human guidance for an auth-related failure.
    public static func guidance() -> String {
        NSLocalizedString("身份验证失败或已过期——请在设置中重新保存访问令牌（或检查 SSH 密钥/gh 登录状态）", comment: "auth guidance")
    }
}

/// Periodically probes every repo with a remote; notifies on NEW auth/connectivity
/// issues and stays quiet until the repo recovers (no notification spam).
public final class AuthMonitor: @unchecked Sendable {
    public let repos: RepoManager
    public let sync: SyncManager
    public let interval: TimeInterval
    /// (repoPath, message) on each NEW connectivity/auth issue episode.
    public nonisolated let onAuthIssue = EventCallbackBox()
    private var alerted: Set<String> = []
    private let lock = NSLock()
    /// Global cooperative-safe probe limiter: bounds concurrent probes across
    /// ALL monitor instances WITHOUT blocking pool threads (a semaphore wait
    /// would starve the Swift cooperative pool — audit v2.4.3).
    private actor ProbeLimiter {
        static let shared = ProbeLimiter()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var active = 0
        private let max = 2
        func enter() async {
            if active < max {
                active += 1
                return
            }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                waiting.append(cont)
            }
        }
        func exit() {
            active = Swift.max(0, active - 1)
            if !waiting.isEmpty {
                waiting.removeFirst().resume()
                active += 1
            }
        }
    }

    public init(repos: RepoManager, sync: SyncManager, interval: TimeInterval = 6 * 3600) {
        self.repos = repos
        self.sync = sync
        self.interval = interval
    }

    /// Long-running probe loop (call from a detached Task at service start).
    /// The FIRST probe is deferred: probing during the startup burst saturates
    /// the libdispatch thread pool with blocked ls-remotes (audit v2.2.4).
    public func runLoop(rootsProvider: @escaping @Sendable () -> [String],
                        initialDelay: TimeInterval = 60) async {
        try? await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000))
        while !Task.isCancelled {
            await checkAll(rootsProvider: rootsProvider)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// One probe pass over all managed roots that have a remote.
    ///
    /// v4.0: each managed root is one repo, so there is nothing to enumerate
    /// below it — the probe set is exactly the configured roots.
    public func checkAll(rootsProvider: @escaping @Sendable () -> [String]) async {
        for repo in rootsProvider() {
            let hasRemote = await repos.remoteURL(path: repo) != nil
            guard hasRemote else {
                lock.lock(); alerted.remove(repo); lock.unlock()
                continue
            }
            await AuthMonitor.ProbeLimiter.shared.enter()
            let conn = await sync.testConnectivity(repoPath: repo)
            await AuthMonitor.ProbeLimiter.shared.exit()
            lock.lock()
            let alreadyAlerted = alerted.contains(repo)
            if !conn.ok {
                if !alreadyAlerted {
                    alerted.insert(repo)
                }
            } else {
                alerted.remove(repo)
            }
            lock.unlock()
            if !conn.ok && !alreadyAlerted {
                let message = AuthClassifier.isAuthRelated(conn.detail)
                    ? String(format: NSLocalizedString("%@（%@）", comment: "auth guidance detail"),
                             AuthClassifier.guidance(), conn.detail)
                    : String(format: NSLocalizedString("远程仓库连接失败（%@）", comment: "auth monitor"),
                             conn.detail)
                onAuthIssue(repo, message)
            }
        }
    }

    /// Whether a repo is currently in a notified-failure episode.
    public func isAlerted(repoPath: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return alerted.contains(repoPath)
    }
}
