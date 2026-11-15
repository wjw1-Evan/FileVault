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
    /// Multicast observers of state changes (UI windows auto-refresh, v2.6.5).
    private let stateListenersLock = NSLock()
    private var stateListeners: [UUID: @Sendable () -> Void] = [:]
    /// Unified failure events for UI notifications (FR-18).
    public let onFailure = EventCallbackBox()
    public let sshChecker = SshKeyChecker()
    var debouncer: Debouncer!
    public private(set) var authMonitor: AuthMonitor?
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
        // A bundled/downloaded git is self-contained: it needs GIT_EXEC_PATH and
        // the templates dir exported, or its commands misbehave (forExecutable
        // detects that layout and adds them).
        let runner = GitRunner.forExecutable(det.gitPath)
        let repos = RepoManager(runner: runner)
        repoManager = repos
        debouncer = Debouncer(quietInterval: 5, maxWait: 60) { [weak self] key in
            self?.commitEngine.commit(forKey: key)
        }
        commitEngine = CommitEngine(repoManager: repos, debouncer: debouncer!, pause: pause)
        sync = SyncManager(repoManager: repos)
        history = HistoryService(repoManager: repos)
        commitEngine.onCommitFailure = { [weak self] repoPath, reason in
            self?.onFailure(NSLocalizedString("自动提交失败", comment: "notification title"),
                            "\((repoPath as NSString).lastPathComponent)：\(reason)")
        }
        sync.onPushFailure.handler = { [weak self] repoPath, reason in
            self?.onFailure(NSLocalizedString("推送失败", comment: "notification title"),
                            "\((repoPath as NSString).lastPathComponent)：\(reason)")
        }
        // Event-driven UI refresh: any sync transition or commit event notifies observers.
        sync.onStatusChange.handler = { [weak self] _, _ in
            self?.fireStateChange()
        }
        commitEngine.onCommit = { [weak self] repoPath, _, _ in
            guard let self else { return }
            fireStateChange()
            Task { await self.sync.enqueuePush(repoPath: repoPath) }
        }
        // Load configured roots, ensure repos, start watchers.
        let cfg = configStore.load()
        applyGeneral(cfg.general)
        for root in cfg.roots {
            // One moved/deleted folder must not brick startup: skip the bad
            // root and keep the rest of the vault working. It stays in the
            // config so the user can reconnect it from Settings.
            do {
                try await attachRoot(path: root.path, paused: root.paused)
            } catch {
                if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
                    print("[FV_DEBUG] attachRoot skipped \(root.path): \(error)")
                }
            }
        }
        // v2.2.3: periodic auth/connectivity probing with dedup notifications.
        authMonitor = AuthMonitor(repos: repos, sync: sync)
        authMonitor?.onAuthIssue.handler = { [weak self] repoPath, message in
            self?.onFailure(NSLocalizedString("远程仓库身份验证失败", comment: "notification title"),
                            "\((repoPath as NSString).lastPathComponent)：\(message)")
        }
        let rootsForAuth = rootsSnapshot()
        Task { [weak self] in
            await self?.authMonitor?.runLoop(rootsProvider: { [weak self] in self?.rootsSnapshot() ?? rootsForAuth })
        }
        // FR-19: weekly gc maintenance, deferred out of the cold-start path.
        let rootsForMaintenance = rootsSnapshot()
        Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            for root in rootsForMaintenance {
                await repoManager.runMaintenanceIfNeeded(path: root)
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
        lock.lock()
        watchers[p]?.stop()
        watchers.removeValue(forKey: p)
        roots.removeAll { $0 == p }
        lock.unlock()
        var cfg = configStore.load()
        cfg.roots.removeAll { $0.path == p }
        configStore.save(cfg)
    }

    /// Attach an existing root: prepare its repo and start its watcher.
    ///
    /// The root is only registered once preparation succeeded, so a missing or
    /// unwritable folder can never appear as "attached but unwatched".
    private func attachRoot(path: String, paused: Bool) async throws {
        let p = resolved(path)
        lock.lock()
        let alreadyAttached = watchers[p] != nil
        lock.unlock()
        if alreadyAttached {
            if paused { pause.setPaused(true, forRoot: p) }
            return
        }
        guard FileManager.default.fileExists(atPath: p) else {
            throw FileVaultServiceError.rootMissing
        }
        // v4.0: the managed root itself is the one repo.
        _ = try await repoManager.ensureRepo(at: p)
        if paused {
            pause.setPaused(true, forRoot: p)
        }
        let w = WatcherEngine(rootPath: p, source: FSEventsChangeSource())
        lock.lock()
        watchers[p] = w
        if !roots.contains(p) { roots.append(p) }
        lock.unlock()
        w.start(onActivity: { [weak self] in
            self?.commitEngine.handleActivity(root: p)
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

    /// Start with FR-01 auto-install: when git is missing, run the installer
    /// once and retry start (testable via the GitInstalling seam).
    public func startWithAutoInstall(installer: GitInstalling) async throws {
        do {
            try await start()
        } catch {
            _ = try await installer.install()
            try await start()
        }
    }

    /// Apply general settings to runtime components (v1.3.0 complete settings).
    public func applyGeneral(_ g: GeneralSettings) {
        debouncer?.setQuietInterval(TimeInterval(g.debounceSeconds))
        // v3.1.3: no large-file threshold to push down — the commit pipeline
        // resolves it from each repo's remote on every run.
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

    public func rootsSnapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return roots
    }

    // MARK: - State change observers (multicast, v2.6.5)

    /// Register an additional state-change observer. Returns a token for
    /// `removeStateListener`. The legacy single `onStateChange` closure keeps
    /// working alongside these.
    @discardableResult
    public func addStateListener(_ listener: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        stateListenersLock.lock()
        stateListeners[token] = listener
        stateListenersLock.unlock()
        return token
    }

    public func removeStateListener(_ token: UUID) {
        stateListenersLock.lock()
        stateListeners[token] = nil
        stateListenersLock.unlock()
    }

    /// Fan a state change out to every observer. All internal emitters go
    /// through here so windows subscribed via `addStateListener` see them too.
    func fireStateChange() {
        onStateChange?()
        stateListenersLock.lock()
        let listeners = Array(stateListeners.values)
        stateListenersLock.unlock()
        listeners.forEach { $0() }
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
