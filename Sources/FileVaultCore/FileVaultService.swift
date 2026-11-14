import Foundation

/// Composition root wiring all core services (app UI + smoke self-check).
public final class FileVaultService: @unchecked Sendable {
    public let configStore: ConfigStore
    public let envGuard: GitEnvGuard
    public let pause = PauseController()
    public private(set) var detection: GitDetection?
    public private(set) var repoManager: RepoManager!
    public private(set) var commitEngine: CommitEngine!
    public private(set) var sync: SyncManager!
    public private(set) var history: HistoryService!
    public private(set) var watchers: [String: WatcherEngine] = [:]
    private var roots: [String] = []
    public var onStateChange: (@Sendable () -> Void)?
    /// Unified failure events for UI notifications (FR-18).
    public let onFailure = EventCallbackBox()
    public let sshChecker = SshKeyChecker()
    var debouncer: Debouncer!
    private let lock = NSLock()

    public init(configDirectory: URL? = nil, locator: GitLocator = SystemGitLocator()) {
        self.configStore = ConfigStore(directory: configDirectory)
        self.envGuard = GitEnvGuard(locator: locator)
    }

    /// Detect git, build services, load roots, ensure repos, start watchers.
    public func start() async throws {
        let det: GitDetection
        switch await envGuard.detect() {
        case .success(let d):
            det = d
        case .failure(let e):
            throw e
        }
        detection = det
        let runner = GitRunner(gitExecutable: det.gitPath)
        let repos = RepoManager(runner: runner)
        repoManager = repos
        debouncer = Debouncer(quietInterval: 5, maxWait: 60) { [weak self] key in
            self?.commitEngine.commit(forKey: key)
        }
        commitEngine = CommitEngine(repoManager: repos, debouncer: debouncer!, pause: pause)
        sync = SyncManager(repoManager: repos)
        history = HistoryService(repoManager: repos)
        commitEngine.onCommitFailure = { [weak self] repoPath, reason in
            self?.onFailure("自动提交失败", "\((repoPath as NSString).lastPathComponent)：\(reason)")
        }
        sync.onPushFailure.handler = { [weak self] repoPath, reason in
            self?.onFailure("推送失败", "\((repoPath as NSString).lastPathComponent)：\(reason)")
        }
        // Event-driven UI refresh: any sync transition or commit event notifies observers.
        sync.onStatusChange.handler = { [weak self] _, _ in
            self?.onStateChange?()
        }
        commitEngine.onCommit = { [weak self] repoPath, _, _ in
            guard let self else { return }
            onStateChange?()
            Task { await self.sync.enqueuePush(repoPath: repoPath) }
        }
        // Load configured roots, ensure repos, start watchers.
        let cfg = configStore.load()
        applyGeneral(cfg.general)
        for root in cfg.roots {
            try await attachRoot(path: root.path, paused: root.paused)
        }
        // FR-19: weekly gc maintenance, deferred out of the cold-start path.
        let rootsForMaintenance = rootsSnapshot()
        Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            for root in rootsForMaintenance {
                for repo in repoManager.firstLevelFolders(root: root) {
                    let p = repo.path
                    await repoManager.runMaintenanceIfNeeded(path: p)
                }
            }
        }
    }

    // MARK: - Root lifecycle

    /// Register + prepare + watch a root folder.
    public func addRoot(path: String) async throws {
        var p = path
        if let r = try? URL(fileURLWithPath: path).resolvingSymlinksInPath() { p = r.path }
        guard FileManager.default.fileExists(atPath: p) else {
            throw FileVaultServiceError.rootMissing
        }
        try await attachRoot(path: p, paused: false)
        var cfg = configStore.load()
        if !cfg.roots.contains(where: { $0.path == p }) {
            cfg.roots.append(ManagedRoot(path: p))
            configStore.save(cfg)
        }
    }

    /// Stop watching and forget a root (repos on disk are left untouched).
    public func removeRoot(path: String) async {
        let p = resolved(path)
        watchers[p]?.stop()
        watchers.removeValue(forKey: p)
        roots.removeAll { $0 == p }
        var cfg = configStore.load()
        cfg.roots.removeAll { $0.path == p }
        configStore.save(cfg)
    }

    /// Attach an existing root: ensure repos and start its watcher.
    private func attachRoot(path: String, paused: Bool) async throws {
        let p = resolved(path)
        if paused {
            pause.setPaused(true, forRoot: p)
        }
        guard watchers[p] == nil else { return }
        _ = try await repoManager.ensureRepos(root: p)
        roots.append(p)
        let w = WatcherEngine(rootPath: p, source: FSEventsChangeSource())
        watchers[p] = w
        w.start(onActivity: { [weak self] subfolder in
            self?.commitEngine.handleActivity(root: p, subfolder: subfolder)
        }, onRootStructureChanged: { [weak self] in
            guard let self else { return }
            Task { await self.rescanRoot(p) }
        })
    }

    // MARK: - Runtime controls & UI snapshots

    public func setGlobalPaused(_ p: Bool) async {
        pause.setGlobalPaused(p)
        // FR-13: resuming triggers a full check so paused changes get committed.
        if !p {
            await commitAllNow()
        }
    }

    public func setRootPaused(_ p: Bool, root: String) async {
        pause.setPaused(p, forRoot: resolved(root))
        var cfg = configStore.load()
        if let idx = cfg.roots.firstIndex(where: { $0.path == resolved(root) }) {
            cfg.roots[idx].paused = p
            configStore.save(cfg)
        }
        if !p {
            await commitEngine.commitAllDirty(root: resolved(root))
        }
    }

    /// Apply general settings to runtime components (v1.3.0 complete settings).
    public func applyGeneral(_ g: GeneralSettings) {
        debouncer?.setQuietInterval(TimeInterval(g.debounceSeconds))
        commitEngine?.largeFileThreshold = UInt64(g.largeFileThresholdMB) * 1024 * 1024
    }

    /// Mutate and persist general settings, then apply them at runtime.
    public func updateGeneral(_ mutate: (inout GeneralSettings) -> Void) {
        var cfg = configStore.load()
        mutate(&cfg.general)
        configStore.save(cfg)
        applyGeneral(cfg.general)
    }

    public func commitAllNow() async {
        for r in rootsSnapshot() {
            await commitEngine.commitAllDirty(root: r)
        }
    }

    public func rescanRoot(_ root: String) async {
        guard watchers[root] != nil else { return }
        _ = try? await repoManager.ensureRepos(root: root)
        onStateChange?()
    }

    public func rootsSnapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return roots
    }

    public func watcher(for root: String) -> WatcherEngine? {
        lock.lock(); defer { lock.unlock() }
        return watchers[root]
    }

    func resolved(_ path: String) -> String {
        if let r = try? URL(fileURLWithPath: path).resolvingSymlinksInPath() { return r.path }
        return path
    }
}

public enum FileVaultServiceError: LocalizedError {
    case rootMissing
    public var errorDescription: String? { "根目录不存在或不可访问" }
}
