import Foundation

/// Orchestrates debounced auto-commit per subfolder repo (FR-04/05/12/13).
public final class CommitEngine: @unchecked Sendable {
    public let repoManager: RepoManager
    public let debouncer: Debouncer
    public let pause: PauseController
    /// Called after a successful auto-commit with (repoPath, hash, message).
    public var onCommit: (@Sendable (String, String, String) -> Void)?

    private let inFlight = NSLock()
    private var busyKeys: Set<String> = []
    private var recheckKeys: Set<String> = []

    public init(repoManager: RepoManager, debouncer: Debouncer, pause: PauseController) {
        self.repoManager = repoManager
        self.debouncer = debouncer
        self.pause = pause
    }

    /// Called by WatcherEngine via the service: debounce-touch the repo (FR-04).
    public func handleActivity(root: String, subfolder: String) {
        if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
            print("[FV_DEBUG] t=\(Int(Date().timeIntervalSince1970) % 1000) activity root=\(root) sub=\(subfolder)")
        }
        let key = (root as NSString).appendingPathComponent(subfolder)
        debouncer.touch(key)
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
        guard !pause.isPaused(root: (repoPath as NSString).deletingLastPathComponent) else { return }
        let entries = (try? await repoManager.status(path: repoPath)) ?? []
        if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
            print("[FV_DEBUG] status entries=\(entries.count)")
        }
        guard !entries.isEmpty else { return }
        let excluded = await repoManager.excludeLargeFiles(path: repoPath)
        do {
            let hash = try await repoManager.commitAll(path: repoPath)
            if !hash.isEmpty {
                onCommit?(repoPath, hash, Self.describe(entries: entries, excluded: excluded))
            }
        } catch {
            if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
                print("[FV_DEBUG] commit error: \(error)")
            }
        }
    }

    /// Full check: commit every dirty repo under a root (used on resume / manual flush).
    public func commitAllDirty(root: String) async {
        let folders = repoManager.firstLevelFolders(root: root)
        for f in folders {
            await runCommitPipeline(repoPath: f.path)
        }
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
