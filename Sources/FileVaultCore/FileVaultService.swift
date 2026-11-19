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
    /// How often the sweep also checks the remote for new commits (v4.2.17).
    public let remoteSyncInterval: TimeInterval
    private var lastRemoteSync: [String: Date] = [:]
    private let remoteSyncLock = NSLock()
    /// Startup attach failures (see attachError(root:)) (v4.2.26).
    private var attachErrors: [String: String] = [:]
    private let attachErrorLock = NSLock()
    private var authMonitorTask: Task<Void, Never>?

    public init(configDirectory: URL? = nil, locator: GitLocator = SystemGitLocator(),
                sweepInterval: TimeInterval = 120,
                remoteSyncInterval: TimeInterval = 300) {
        self.configStore = ConfigStore(directory: configDirectory)
        self.envGuard = GitEnvGuard(locator: locator)
        self.sweepInterval = sweepInterval
        self.remoteSyncInterval = remoteSyncInterval
    }

    deinit {
        sweepTask?.cancel()
        authMonitorTask?.cancel()
    }

    /// True once `start()` has built the git-backed services. The UI must not
    /// touch `repoManager`/`history`/… before this is true: a failed git setup
    /// (offline first launch) leaves them nil, and an implicitly-unwrapped nil
    /// used to crash the app as soon as someone opened "添加文件夹" (v4.2.26).
    public var isReady: Bool {
        repoManager != nil && commitEngine != nil && sync != nil
            && history != nil && recovery != nil
    }

    /// The folders the user configured, INCLUDING ones that are not attached
    /// right now (external disk unplugged, folder moved, another live instance
    /// owns it). The UI lists these so a protected folder never seems to
    /// disappear, and so it can be relocated/removed from Settings (v4.2.26).
    public func configuredRoots() -> [ManagedRoot] {
        configStore.load().roots
    }

    /// Whether the folder currently has a live watcher (attached successfully).
    public func isAttached(root: String) -> Bool {
        let p = resolved(root)
        lock.lock(); defer { lock.unlock() }
        return watchers[p] != nil
    }

    /// Readable reason why a configured folder could not be attached, if any.
    /// Cleared on a successful attach so a replugged disk heals silently.
    public func attachError(root: String) -> String? {
        let p = resolved(root)
        attachErrorLock.lock(); defer { attachErrorLock.unlock() }
        return attachErrors[p]
    }

    private func setAttachError(_ message: String?, for root: String) {
        let p = resolved(root)
        attachErrorLock.lock()
        if let message {
            attachErrors[p] = message
        } else {
            attachErrors.removeValue(forKey: p)
        }
        attachErrorLock.unlock()
    }

    /// Ask observers to refresh after a change that bypassed the commit/sync
    /// pipelines (file restore, rollback, backup restore) (v4.2.26).
    public func notifyStateChanged() {
        fireStateChange()
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
        repos.onNestedRepoExcluded = { [weak self] repoPath, dir in
            let name = (repoPath as NSString).lastPathComponent
            self?.onFailure(NSLocalizedString("嵌套仓库未纳入版本管理", comment: "notification title"),
                            String(format: NSLocalizedString(
                                "%@：%@ 是没有提交的独立 Git 仓库，已跳过；请先在里面完成首次提交",
                                comment: "nested repo excluded"), name, dir))
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
        switch configStore.lastLoadIssue {
        case .recoveredFromBackup:
            onFailure(NSLocalizedString("配置文件损坏，已从备份恢复", comment: "notification title"),
                      NSLocalizedString("受保护文件夹列表已从 config.backup.json 恢复；请确认列表是否完整。",
                                        comment: "config recovery"))
        case .unreadable:
            onFailure(NSLocalizedString("配置文件无法读取", comment: "notification title"),
                      NSLocalizedString("配置文件与备份都无法读取，本次以空列表启动（磁盘上的仓库没有被删除）；如列表为空，请重新添加文件夹。",
                                        comment: "config recovery"))
        case nil:
            break
        }
        applyGeneral(cfg.general)
        for root in cfg.roots {
            // One moved/deleted folder must not brick startup: skip the bad
            // root and keep the rest of the vault working. It stays in the
            // config so the user can reconnect it from Settings.
            do {
                try await attachRoot(path: root.path, paused: root.paused,
                                     announceReinitialisation: true)
            } catch {
                if ProcessInfo.processInfo.environment["FV_DEBUG"] != nil {
                    print("[FV_DEBUG] attachRoot skipped \(root.path): \(error)")
                }
                // v4.2.26: a folder that cannot be mounted must not silently
                // vanish from the app. Remember the reason for the UI and tell
                // the user once per launch; it stays in the protected list.
                let reason = error.localizedDescription
                setAttachError(reason, for: root.path)
                onFailure(
                    NSLocalizedString("受保护文件夹暂时无法打开", comment: "notification title"),
                    String(format: NSLocalizedString("%@：%@；它仍在受保护列表中，可从设置里重新定位或移除。",
                                                     comment: "attach failure"),
                           (root.path as NSString).lastPathComponent, reason))
            }
        }
        // Catch up changes made just before the last quit: the 5 s debounce may
        // not have fired, and no FSEvents event will arrive for them now. Commit
        // dirty roots once at startup (v4.2.15).
        Task { [weak self] in
            await self?.sweepOnce()
        }
        // v2.2.3: periodic auth/connectivity probing with dedup notifications.
        authMonitor = AuthMonitor(repos: repos, sync: sync)
        authMonitor?.onAuthIssue.handler = { [weak self] repoPath, message in
            self?.onFailure(NSLocalizedString("远程仓库身份验证失败", comment: "notification title"),
                            "\((repoPath as NSString).lastPathComponent)：\(message)")
        }
        let rootsForAuth = rootsSnapshot()
        // Keep the task handle so deinit can stop the loop instead of leaking
        // the whole service graph forever (v4.2.26).
        authMonitorTask = Task { [weak self] in
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
        // Roots that failed to attach at startup (external disk unplugged,
        // another live instance, transient error) are retried here, so they
        // recover without restarting the app (v4.2.9).
        let attachedNow = rootsSnapshot()
        for cfgRoot in configStore.load().roots {
            let root = resolved(cfgRoot.path)
            guard !attachedNow.contains(root),
                  FileManager.default.fileExists(atPath: root) else { continue }
            // The config may have changed since this loop started (the root
            // was removed from Settings mid-sweep): never re-attach what the
            // user just unprotected (v4.2.31).
            guard isStillConfigured(root) else { continue }
            do {
                // Same announcement rule as startup and the self-heal loop
                // below: a configured folder that lost its .git while it was
                // unattached must not come back as a silently empty history
                // (v4.2.31; the v4.2.8 invariant).
                try await attachRoot(path: root, paused: pause.isPaused(root: root),
                                     announceReinitialisation: true)
                if isStillConfigured(root) {
                    setAttachError(nil, for: root)
                } else {
                    // Removed while the attach was in flight: undo it, or the
                    // sweep would leave a live watcher that keeps committing
                    // (and pushing) an unprotected folder (v4.2.31).
                    await removeRoot(path: root)
                }
            } catch {
                // Keep the reason so Settings can explain why the folder is
                // listed but not protected right now (v4.2.26).
                setAttachError(error.localizedDescription, for: root)
            }
        }
        // Snapshot under the service lock: `watchers` is mutated by
        // addRoot/removeRoot/relocateRoot on other threads, and an unlocked
        // read here raced those writes (v4.2.31; the section lives in a
        // plain function — NSLock is unavailable from async contexts under
        // the Swift 6 language mode).
        let watchersNow = watchersSnapshot()
        for root in rootsSnapshot() {
            // The loop list is a snapshot and its body awaits: a root removed
            // from Settings while an EARLIER iteration was committing must not
            // be resurrected here — the stale watchersNow entry is stopped (so
            // !isRunning restarts it) and the direct commit below would commit
            // an unprotected folder (v4.2.31, second-loop counterpart of the
            // guard above).
            guard isStillConfigured(root) else { continue }
            // Self-heal watching: an external disk that disappears and comes
            // back, or a watch stream that stopped, must start watching again
            // without the user touching the folder (v4.2.7).
            if FileManager.default.fileExists(atPath: root) {
                if let watcher = watchersNow[root] {
                    if !watcher.isRunning { startWatching(watcher, path: root) }
                } else {
                    try? await attachRoot(path: root, paused: pause.isPaused(root: root),
                                          announceReinitialisation: true)
                    // Removed while that attach was in flight: undo it, same
                    // rule as the unattached-roots loop above (v4.2.31).
                    if !isStillConfigured(root) {
                        await removeRoot(path: root)
                    }
                }
            }
            if pause.isPaused(root: root) { continue }
            // Serialize with the debounce pipeline and restore/rollback paths:
            // the sweep used to call the pipeline directly, so a commit could
            // race another commit of the same repo (v4.2.26).
            await commitEngine.commitSerialized(repoPath: root)
            // Periodic remote sync: pull new commits made on other machines
            // (and push our own), every remoteSyncInterval (v4.2.17).
            if await repoManager.remoteURL(path: root) != nil, remoteSyncDue(root) {
                markRemoteSynced(root)
                await sync.syncWithRemote(repoPath: root)
            }
        }
    }

    /// Whether a root is still present in the CURRENT config snapshot. A
    /// sweep may have loaded a stale one; removals made while it runs must win
    /// (v4.2.31).
    func isStillConfigured(_ root: String) -> Bool {
        configStore.load().roots.contains { resolved($0.path) == root }
    }

    private func remoteSyncDue(_ root: String) -> Bool {
        remoteSyncLock.lock(); defer { remoteSyncLock.unlock() }
        guard let last = lastRemoteSync[root] else { return true }
        return Date().timeIntervalSince(last) >= remoteSyncInterval
    }

    private func markRemoteSynced(_ root: String) {
        remoteSyncLock.lock(); defer { remoteSyncLock.unlock() }
        lastRemoteSync[root] = Date()
    }

    /// Drop the periodic-sync bookkeeping of a removed/relocated root.
    private func forgetRemoteSyncState(_ root: String) {
        remoteSyncLock.lock(); defer { remoteSyncLock.unlock() }
        lastRemoteSync.removeValue(forKey: root)
    }

    // MARK: - Root lifecycle

    /// Register + prepare + watch a root folder.
    ///
    /// `remoteURL` lets the one-step sheet bind the remote BEFORE the first
    /// commit, so an oversized file is excluded from the very first version
    /// instead of entering history and making every push fail (v4.2.26).
    public func addRoot(path: String, remoteURL: String? = nil) async throws {
        guard isReady else { throw FileVaultServiceError.environmentNotReady }
        let p = resolved(path)
        guard FileManager.default.fileExists(atPath: p) else {
            throw FileVaultServiceError.rootMissing
        }
        // Nested/overlapping roots would put one git repo inside another: the
        // outer repo records the inner one as an embedded repo, both watchers
        // fire, and a clone of either gets an empty directory. Refuse with a
        // readable explanation instead (v4.2.26).
        for existing in configStore.load().roots.map({ resolved($0.path) }) where existing != p {
            if p.hasPrefix(existing + "/") || existing.hasPrefix(p + "/") {
                throw FileVaultServiceError.rootOverlaps(existing)
            }
        }
        let trimmedRemote = remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await attachRoot(path: p, paused: false,
                             remoteURL: (trimmedRemote?.isEmpty ?? true) ? nil : trimmedRemote)
        setAttachError(nil, for: p)
        var cfg = configStore.load()
        if !cfg.roots.contains(where: { $0.path == p }) {
            cfg.roots.append(ManagedRoot(path: p))
            saveConfig(cfg)
        }
        fireStateChange()
    }

    /// Stop watching and forget a root (repos on disk are left untouched).
    public func removeRoot(path: String) async {
        let p = resolved(path)
        // Persist the removal FIRST, before the awaits below: a safety sweep
        // running concurrently re-checks the config before re-attaching an
        // unattached root, so a root whose removal is still mid-teardown must
        // no longer be resurrectable (v4.2.31).
        var cfg = configStore.load()
        cfg.roots.removeAll { $0.path == p }
        saveConfig(cfg)
        detachWatcherUnderLock(p)
        commitEngine?.unregisterRoot(p)
        // Pending debounce fires for a forgotten folder would re-enqueue pushes
        // for a removed repo or notify about it (v4.2.27). unregisterRoot also
        // drops any scheduled auto-commit retry for it (v4.2.31).
        debouncer?.cancel(key: p)
        repoManager?.releaseInstanceLock(path: p)
        // Forgetting a folder must forget its runtime state too: a leftover
        // pause flag made a re-added folder look unpaused in the UI while the
        // commit pipeline skipped it forever (v4.2.26). A push loop / backoff /
        // failed status must not keep running for a folder that is gone.
        pause.setPaused(false, forRoot: p)
        setAttachError(nil, for: p)
        forgetRemoteSyncState(p)
        if let sync { await sync.reset(repoPath: p) }
        fireStateChange()
    }

    /// Re-point a managed root at its new location (folder moved/renamed, or an
    /// external disk that mounted under a different path) (v4.2.5).
    ///
    /// The repository lives inside the folder, so moving the folder keeps the
    /// full history; only the watched path and the config entry change. Nothing
    /// is re-initialised when a .git moved with the folder.
    public func relocateRoot(from oldPath: String, to newPath: String) async throws {
        guard isReady else { throw FileVaultServiceError.environmentNotReady }
        let old = resolved(oldPath)
        let new = resolved(newPath)
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
        // Same nesting rule as addRoot: relocating INTO or AROUND another
        // protected folder would create a repo inside a repo (v4.2.26).
        for other in cfg.roots.map({ resolved($0.path) }) where other != old && other != new {
            if new.hasPrefix(other + "/") || other.hasPrefix(new + "/") {
                throw FileVaultServiceError.rootOverlaps(other)
            }
        }
        let paused = cfg.roots[idx].paused

        // Stop watching the old path first: its watcher would otherwise fire on
        // a folder that no longer exists.
        detachWatcherUnderLock(old)
        commitEngine.unregisterRoot(old)
        debouncer.cancel(key: old)
        repoManager.releaseInstanceLock(path: old)
        pause.setPaused(false, forRoot: old)
        forgetRemoteSyncState(old)
        if let sync { await sync.reset(repoPath: old) }

        // Attach the new path (adopts the .git that moved with the folder).
        // Announce reinit: the relocate dialog promises history is kept, so a
        // .git that did not survive the move must produce a readable notice
        // instead of a silently empty history (v4.2.27).
        try await attachRoot(path: new, paused: paused, announceReinitialisation: true)

        cfg = configStore.load()
        if let i = cfg.roots.firstIndex(where: { resolved($0.path) == old }) {
            cfg.roots[i].path = new
        } else {
            cfg.roots.append(ManagedRoot(path: new, paused: paused))
        }
        saveConfig(cfg)
        fireStateChange()
    }

    /// Attach an existing root: prepare its repo and start its watcher.
    ///
    /// The root is only registered once preparation succeeded, so a missing or
    /// unwritable folder can never appear as "attached but unwatched".
    private func attachRoot(path: String, paused: Bool, remoteURL: String? = nil,
                            announceReinitialisation: Bool = false) async throws {
        let p = resolved(path)
        let alreadyAttached = isWatchedUnderLock(p)
        if alreadyAttached {
            if paused { pause.setPaused(true, forRoot: p) }
            setAttachError(nil, for: p)
            return
        }
        guard FileManager.default.fileExists(atPath: p) else {
            throw FileVaultServiceError.rootMissing
        }
        // Defensive: the sweep retries attachRoot from a background task, so it
        // must fail readably (not trap) if the git services are not built yet.
        guard isReady else { throw FileVaultServiceError.environmentNotReady }
        // v4.0: the managed root itself is the one repo.
        let hadRepo = FileManager.default.fileExists(
            atPath: (p as NSString).appendingPathComponent(".git"))
        let contentsBefore = (try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []
        _ = try await repoManager.ensureRepo(at: p, remoteURL: remoteURL)
        // Two copies of the app must not watch/commit the same folder: only the
        // first live instance owns it (v4.2.9).
        guard repoManager.acquireInstanceLock(path: p) else {
            throw FileVaultServiceError.managedByAnotherInstance
        }
        if announceReinitialisation, !hadRepo, !contentsBefore.isEmpty {
            // A configured root silently losing its .git would otherwise come
            // back as an EMPTY history with no explanation (v4.2.8).
            onFailure(NSLocalizedString("受保护文件夹被重新初始化", comment: "notification title"),
                      String(format: NSLocalizedString("%@：.git 不见了（可能被删除或移动），已重新初始化为空历史；如果之前推送过远程，请在设置里重新填写远程地址以恢复同步",
                                                       comment: "repo reinitialised"),
                             (p as NSString).lastPathComponent))
        }
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
        adoptWatcherUnderLock(w, root: p)
        commitEngine.registerRoot(p)
        setAttachError(nil, for: p)
        startWatching(w, path: p)
    }

    /// Start (or restart) one watcher stream for a root.
    private func startWatching(_ watcher: WatcherEngine, path: String) {
        watcher.start(onActivityPaths: { [weak self] paths in
            self?.commitEngine.handleActivity(root: path, paths: paths)
        })
    }

    // MARK: - Runtime controls & UI snapshots

    public func setRootPaused(_ p: Bool, root: String) async {
        pause.setPaused(p, forRoot: resolved(root))
        var cfg = configStore.load()
        if let idx = cfg.roots.firstIndex(where: { $0.path == resolved(root) }) {
            cfg.roots[idx].paused = p
            saveConfig(cfg)
        }
        fireStateChange()
        if !p, let commitEngine {
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
        saveConfig(cfg)
        applyGeneral(cfg.general)
    }

    /// Persist the config and surface a write failure instead of silently
    /// pretending the change was stored (v4.2.25).
    private func saveConfig(_ cfg: AppConfig) {
        guard !configStore.save(cfg) else { return }
        onFailure(NSLocalizedString("配置未能保存", comment: "config failure"),
                  NSLocalizedString("设置已在本次运行中生效，但配置文件无法写入（磁盘已满或没有写入权限），重启后可能丢失这次修改。",
                                    comment: "config failure"))
    }

    public func commitAllNow() async {
        guard let commitEngine else { return }
        for r in rootsSnapshot() {
            await commitEngine.commitAllDirty(root: r)
        }
    }

    public func rootsSnapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return roots
    }

    // MARK: - Synchronous lock sections (v4.2.31)
    //
    // Short critical sections that never await; plain functions keep the
    // async callers free of the "unavailable from asynchronous contexts"
    // Swift 6 error (same pattern as AuthMonitor/CommitEngine/RepoManager
    // in this round).

    private func watchersSnapshot() -> [String: WatcherEngine] {
        lock.lock(); defer { lock.unlock() }
        return watchers
    }

    private func isWatchedUnderLock(_ p: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return watchers[p] != nil
    }

    private func adoptWatcherUnderLock(_ w: WatcherEngine, root p: String) {
        lock.lock()
        watchers[p] = w
        if !roots.contains(p) { roots.append(p) }
        lock.unlock()
    }

    private func detachWatcherUnderLock(_ p: String) {
        lock.lock()
        watchers[p]?.stop()
        watchers.removeValue(forKey: p)
        roots.removeAll { $0 == p }
        lock.unlock()
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

    /// URL(fileURLWithPath:) is infallible and resolvingSymlinksInPath() is
    /// non-throwing — the old `try?` bound nothing and always succeeded
    /// (the compiler flagged the pointless effect marker, v4.2.31).
    func resolved(_ path: String) -> String {
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

public enum FileVaultServiceError: LocalizedError {
    case rootMissing
    case rootAlreadyManaged
    case managedByAnotherInstance
    /// Git setup failed, so no git-backed service exists (v4.2.26).
    case environmentNotReady
    /// The folder nests one of the protected folders (or contains one): a repo
    /// inside a repo breaks both (v4.2.26).
    case rootOverlaps(String)
    public var errorDescription: String? {
        switch self {
        case .environmentNotReady:
            return NSLocalizedString("Git 环境尚未就绪：等自动安装完成后再试；若一直失败，可在主面板查看原因。",
                                     comment: "service error")
        case .rootMissing:
            return NSLocalizedString("文件夹不存在或不可访问", comment: "service error")
        case .rootAlreadyManaged:
            return NSLocalizedString("这个文件夹已经在受保护列表里了", comment: "service error")
        case .managedByAnotherInstance:
            return NSLocalizedString("这个文件夹正被另一个 FileVault 实例管理", comment: "service error")
        case .rootOverlaps(let other):
            return String(format: NSLocalizedString("这个文件夹与已受保护的「%@」重叠：不能嵌套保护，请只保留外层或里层其中一个",
                                                    comment: "service error"), other)
        }
    }
}
