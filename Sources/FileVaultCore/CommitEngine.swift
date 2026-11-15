import Foundation

/// Orchestrates the debounced auto-commit of ONE managed root repo (FR-04/05/12/13).
///
/// v4.0: the debounce key is the root path itself; every change under the root
/// (root-level files, nested folders, anything not ignored) is committed together.
public final class CommitEngine: @unchecked Sendable {
    public let repoManager: RepoManager
    public let debouncer: Debouncer
    public let pause: PauseController
    /// Called after a successful auto-commit with (repoPath, hash, message).
    public var onCommit: (@Sendable (String, String, String) -> Void)?
    /// Called when the auto-commit pipeline fails with (repoPath, errorDescription).
    public var onCommitFailure: (@Sendable (String, String) -> Void)?
    /// Effective large-file ceiling for a repo (FR-12, v3.1.3).
    ///
    /// There is no local threshold anymore: the value comes from the remote
    /// (github.com → 100 MiB, other remotes → no known limit, i.e. `0`). The
    /// remote is the only place that can actually refuse a push, so its value
    /// is authoritative and the pipeline never invents one.
    public func effectiveThreshold(for repoPath: String) async -> UInt64 {
        let remote = await repoManager.remoteURL(path: repoPath)
        return GitHubLimits.effectiveThreshold(remoteURL: remote)
    }

    private let inFlight = NSLock()
    private var busyKeys: Set<String> = []
    private var recheckKeys: Set<String> = []

    public init(repoManager: RepoManager, debouncer: Debouncer, pause: PauseController) {
        self.repoManager = repoManager
        self.debouncer = debouncer
        self.pause = pause
    }

    /// Called by WatcherEngine via the service: debounce-touch the root repo (FR-04).
    public func handleActivity(root: String) {
        if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
            print("[FV_DEBUG] t=\(Int(Date().timeIntervalSince1970) % 1000) activity root=\(root)")
        }
        debouncer.touch(root)
    }

    /// Debounce fired: run the commit pipeline for the repo at key (FR-04).
    public func commit(forKey key: String) {
        inFlight.lock()
        if busyKeys.contains(key) {
            // Self-heal: signal a re-check instead of dropping the signal.
            recheckKeys.insert(key)
            inFlight.unlock()
            return
        }
        busyKeys.insert(key)
        inFlight.unlock()
        Task.detached { [weak self] in
            guard let self else { return }
            await self.runCommitPipeline(repoPath: key)
            self.inFlight.lock()
            self.busyKeys.remove(key)
            let again = self.recheckKeys.remove(key) != nil
            self.inFlight.unlock()
            if again {
                self.commit(forKey: key)
                return
            }
        }
    }

    /// The commit pipeline: pause check -> status -> large file exclude -> add -> commit.
    public func runCommitPipeline(repoPath: String) async {
        if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
            print("[FV_DEBUG] t=\(Int(Date().timeIntervalSince1970) % 1000) pipeline enter \(repoPath)")
        }
        // v4.0: the repo IS the root, so the pause scope is the repo path itself.
        guard !pause.isPaused(root: repoPath) else { return }
        let entries = (try? await repoManager.status(path: repoPath)) ?? []
        if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
            print("[FV_DEBUG] status entries=\(entries.count)")
        }
        guard !entries.isEmpty else { return }
        // Reuse the single status pass for large-file checks and the commit
        // (was 3 git-status invocations per commit, now 1). Excluded files are
        // filtered out so the commit message reflects what is actually committed.
        let threshold = await effectiveThreshold(for: repoPath)
        let excluded = await repoManager.excludeLargeFiles(path: repoPath, threshold: threshold, entries: entries)
        let excludedSet = Set(excluded)
        let committable = entries.filter { !excludedSet.contains($0.path) }
        do {
            guard !committable.isEmpty else { return }
            let hash = try await repoManager.commitAll(path: repoPath, knownEntries: committable)
            if !hash.isEmpty {
                onCommit?(repoPath, hash, Self.describe(entries: entries, excluded: excluded))
            }
        } catch {
            if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
                print("[FV_DEBUG] commit error: \(error)")
            }
            onCommitFailure?(repoPath, (error as? GitCommandError)?.errorDescription ?? String(describing: error))
        }
    }

    /// Full check: commit the root repo if it is dirty (used on resume / manual flush).
    public func commitAllDirty(root: String) async {
        await runCommitPipeline(repoPath: root)
    }

    /// Human-readable one-line description for logging/UI.
    static func describe(entries: [StatusEntry], excluded: [String]) -> String {
        var text = "\(entries.count) changes"
        if !excluded.isEmpty {
            text += ", \(excluded.count) large file(s) excluded"
        }
        return text
    }
}
