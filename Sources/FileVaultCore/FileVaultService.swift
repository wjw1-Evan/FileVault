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
    public private(set) var recovery: RecoveryService!
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
    /// Periodic safety sweep: guarantees changes are committed even when an
    /// FSEvents notification is missed (sleep/wake, dropped events) (v4.2.4).
    public let sweepInterval: TimeInterval
    private var sweepTask: Task<Void, Never>?

    public init(configDirectory: URL? = nil, locator: GitLocator = SystemGitLocator(),
                sweepInterval: TimeInterval = 120) {
        self.configStore = ConfigStore(directory: configDirectory)
        self.envGuard = GitEnvGuard(locator: locator)
        self.sweepInterval = sweepInterval
    }

    deinit {
        sweepTask?.cancel()
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
        recovery = RecoveryService(repoManager: repos, history: history)
        commitEngine.onCommitFailure = { [weak self] repoPath, reason in
            self?.onFailure(NSLocalizedString("自动提交失败", comment: "notification title"),
                            "\((repoPath as NSString).lastPathComponent)：\(reason)")
        }
        commitEngine.onLargeFilesExcluded = { [weak self] repoPath, files in
            let name = (repoPath as NSString).lastPathComponent
            let shown = files.prefix(3).joined(separator: "、")
            let more = files.count > 3
                ? String(format: NSLocalizedString(" 等 %d 个文件", comment: "list more"), files.count)
                : ""
            self?.onFailure(NSLocalizedString("大文件未纳入版本管理", comment: "notification title"),
                            String(format: NSLocalizedString("%@：%@%@ 超过远程单文件上限，已自动排除、不会同步；需要备份请拆分文件或移出受保护文件夹",
                                                             comment: "large file excluded"), name, shown, more))
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
        // v4.2.4: periodic safety sweep. FSEvents can miss changes (sleep/wake,
        // event queue overflow, watcher restarts); without this the change would
        // stay uncommitted until the next edit.
        let interval = sweepInterval
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(interval, 1) * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.sweepOnce()
            }
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

    /// One safety-sweep pass: commit any dirty (unpaused) root. Exposed so tests
    /// and the UI can trigger it deterministically (v4.2.4).
    public func sweepOnce() async {
        guard let repoManager, let commitEngine else { return }
        for root in rootsSnapshot() {
            // Self-heal watching: an external disk that disappears and comes
            // back, or a watch stream that stopped, must start watching again
            // without the user touching the folder (v4.2.7).
            if FileManager.default.fileExists(atPath: root) {
                if let watcher = watchers[root] {
                    if !watcher.isRunning { startWatching(watcher, path: root) }
                } else {
                    try? await attachRoot(path: root, paused: pause.isPaused(root: root))
                }
            }
            if pause.isPaused(root: root) { continue }
            let entries = (try? await repoManager.status(path: root)) ?? []
            if !entries.isEmpty {
                await commitEngine.runCommitPipeline(repoPath: root)
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
        fireStateChange()
    }

    /// Stop watching and forget a root (repos on disk are left untouched).
    public func removeRoot(path: String) async {
        let p = resolved(path)
        lock.lock()
        watchers[p]?.stop()
        watchers.removeValue(forKey: p)
        roots.removeAll { $0 == p }
        lock.unlock()
        commitEngine.unregisterRoot(p)
        var cfg = configStore.load()
        cfg.roots.removeAll { $0.path == p }
        configStore.save(cfg)
        fireStateChange()
    }

    /// Re-point a managed root at its new location (folder moved/renamed, or an
    /// external disk that mounted under a different path) (v4.2.5).
    ///
    /// The repository lives inside the folder, so moving the folder keeps the
    /// full history; only the watched path and the config entry change. Nothing
    /// is re-initialised when a .git moved with the folder.
    public func relocateRoot(from oldPath: String, to newPath: String) async throws {
        let old = resolved(oldPath)
        var new = newPath
        if let r = try? URL(fileURLWithPath: newPath).resolvingSymlinksInPath() { new = r.path }
        guard FileManager.default.fileExists(atPath: new) else {
            throw FileVaultServiceError.rootMissing
        }
        guard new != old else { return }

        var cfg = configStore.load()
        guard let idx = cfg.roots.firstIndex(where: { resolved($0.path) == old }) else {
            // The old entry is already gone (e.g. removed while the disk was
            // away): just add the new location.
            try await addRoot(path: new)
            return
        }
        guard !cfg.roots.contains(where: { resolved($0.path) == new }) else {
            throw FileVaultServiceError.rootAlreadyManaged
        }
        let paused = cfg.roots[idx].paused

        // Stop watching the old path first: its watcher would otherwise fire on
        // a folder that no longer exists.
        lock.lock()
        watchers[old]?.stop()
        watchers.removeValue(forKey: old)
        roots.removeAll { $0 == old }
        lock.unlock()
        commitEngine.unregisterRoot(old)
        pause.setPaused(false, forRoot: old)

        // Attach the new path (adopts the .git that moved with the folder).
        try await attachRoot(path: new, paused: paused)

        cfg = configStore.load()
        if let i = cfg.roots.firstIndex(where: { resolved($0.path) == old }) {
            cfg.roots[i].path = new
        } else {
            cfg.roots.append(ManagedRoot(path: new, paused: paused))
        }
        configStore.save(cfg)
        fireStateChange()
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
        // v4.2: syncing is the app's only remote mode — a repo that already has
        // a remote but still carries the old "auto-push off" flag is switched on
        // so an upgraded install keeps syncing without any user action.
        if await repoManager.remoteURL(path: p) != nil {
            let autoPush = await repoManager.autoPushEnabled(path: p)
            if !autoPush {
                await repoManager.setAutoPush(path: p, enabled: true)
                await sync.enqueuePush(repoPath: p)
            }
        }
        if paused {
            pause.setPaused(true, forRoot: p)
        }
        let w = WatcherEngine(rootPath: p, source: FSEventsChangeSource())
        lock.lock()
        watchers[p] = w
        if !roots.contains(p) { roots.append(p) }
        lock.unlock()
        commitEngine.registerRoot(p)
        startWatching(w, path: p)
    }

    /// Start (or restart) one watcher stream for a root.
    private func startWatching(_ watcher: WatcherEngine, path: String) {
        watcher.start(onActivityPaths: { [weak self] paths in
            self?.commitEngine.handleActivity(root: path, paths: paths)
        })
    }

    // MARK: - Runtime controls & UI snapshots

    public func setGlobalPaused(_ p: Bool) async {
        pause.setGlobalPaused(p)
        fireStateChange()
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
        fireStateChange()
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
    case rootAlreadyManaged
    public var errorDescription: String? {
        switch self {
        case .rootMissing:
            return NSLocalizedString("文件夹不存在或不可访问", comment: "service error")
        case .rootAlreadyManaged:
            return NSLocalizedString("这个文件夹已经在受保护列表里了", comment: "service error")
        }
    }
}
