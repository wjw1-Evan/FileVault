import Foundation

/// Detects auth-related git failures and classifies user guidance (v2.2.3).
public enum AuthClassifier {
    private static let patterns: [String] = [
        "authentication failed",
        "403",
        "401",
        "could not read username",
        "could not read password",
        "terminal prompts disabled",
        "invalid username or password",
        "access denied",
        "unauthorized",
        "credential",
        "fatal: could not read from remote repository",
    ]

    /// Whether a git failure looks like an auth/credential problem.
    public static func isAuthRelated(_ stderr: String) -> Bool {
        let low = stderr.lowercased()
        return patterns.contains { low.contains($0) }
    }

    /// Human guidance for an auth-related failure.
    public static func guidance() -> String {
        "身份验证失败或已过期——请在设置中重新保存访问令牌（或检查 SSH 密钥/gh 登录状态）"
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

    /// One probe pass over all repos that have a remote.
    public func checkAll(rootsProvider: @escaping @Sendable () -> [String]) async {
        for root in rootsProvider() {
            for r in repos.firstLevelFolders(root: root) {
                let hasRemote = await repos.remoteURL(path: r.path) != nil
                guard hasRemote else {
                    lock.lock(); alerted.remove(r.path); lock.unlock()
                    continue
                }
                await AuthMonitor.ProbeLimiter.shared.enter()
                let conn = await sync.testConnectivity(repoPath: r.path)
                await AuthMonitor.ProbeLimiter.shared.exit()
                lock.lock()
                let alreadyAlerted = alerted.contains(r.path)
                if !conn.ok {
                    if !alreadyAlerted {
                        alerted.insert(r.path)
                    }
                } else {
                    alerted.remove(r.path)
                }
                lock.unlock()
                if !conn.ok && !alreadyAlerted {
                    let message = AuthClassifier.isAuthRelated(conn.detail)
                        ? AuthClassifier.guidance() + "（" + conn.detail + "）"
                        : "远程仓库连接失败（" + conn.detail + "）"
                    onAuthIssue(r.path, message)
                }
            }
        }
    }

    /// Whether a repo is currently in a notified-failure episode.
    public func isAlerted(repoPath: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return alerted.contains(repoPath)
    }
}
