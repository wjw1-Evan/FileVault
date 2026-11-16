import AppKit
import SwiftUI
import FileVaultCore

/// One protected folder row in the menu.
///
/// v4.0: the protected folder IS the repository, so a root carries its own
/// sync status and there is no nested repo list anymore.
struct RootMenuEntry: Identifiable, Equatable {
    let id: String       // path
    let name: String
    let path: String
    let status: SyncStatus
}

/// Root observable state: menu bar data, window actions, update flow and
/// diagnostics. Replaces the former AppDelegate (v3.0.0 SwiftUI migration).
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    static let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    // `Self.bundleVersion` is avoided in initializers (covariant Self limitation).

    let notificationService = NotificationService()
    var service: FileVaultService?
    lazy var updateChecker = UpdateChecker(currentVersion: Self.bundleVersion, fetcher: HttpReleaseFetcher())

    @Published var rootCount = 0
    @Published var roots: [RootMenuEntry] = []
    @Published var envReady = false
    /// FR-01: why the automatic git setup failed (mirror ladder exhausted, offline …).
    /// Kept so the dashboard/settings can show a concrete reason instead of a dead end.
    @Published var gitSetupError: String?
    @Published var statusLine = NSLocalizedString("正在加载…", comment: "menu state")
    @Published var version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

    /// Update progress (FR-20): non-nil while an update transaction runs.
    /// v3.1.7: rendered inline in the menu — no progress window is opened.
    @Published var updateActivity: UpdateActivity?

    /// Result of the last finished update attempt, shown in the menu until the
    /// next check starts (replaces the old "已是最新版本" / failure alerts).
    @Published var updateNotice: String?

    /// Programmatic window opener (onboarding + diagnostics), captured from
    /// the SwiftUI environment once the MenuBarExtra label renders.
    var openWindowHandler: ((String) -> Void)?

    /// --render-* diagnostic request (open a window, capture PNG, exit).
    struct RenderRequest {
        let sceneID: String
        let windowTitle: String
        let outPath: String
    }
    var renderRequest: RenderRequest?

    private var statusCache: [String: SyncStatus] = [:]
    private var timer: Timer?
    private var updateCheckStarted = false

    // Internal for unit tests; the app uses `shared`.
    init(service: FileVaultService? = nil) {
        if let service { self.service = service }
    }

    // MARK: - Lifecycle

    /// Restore the previous bundle when a freshly installed update keeps
    /// failing to start (third launch attempt). Returns true when a rollback
    /// was performed (the caller must stop starting services).
    private func recoverFromFailedUpdateIfNeeded() -> Bool {
        let configDirectory = ConfigStore.defaultDirectory
        guard let marker = UpdateGuard.consumeLaunch(configDirectory: configDirectory),
              UpdateGuard.shouldRollback(marker) else {
            return false
        }
        guard let source = UpdateGuard.rollbackSource(for: Bundle.main.bundleURL) else {
            // Nothing to roll back to (the .old copy was cleaned or never
            // existed). Clear the marker instead of re-entering this branch on
            // every launch — otherwise a FUTURE update would be treated as a
            // crash loop and rolled back on its very first start (v4.2.25).
            UpdateGuard.markHealthy(configDirectory: configDirectory)
            return false
        }
        let fm = FileManager.default
        let bundle = Bundle.main.bundleURL
        let failed = bundle.deletingLastPathComponent()
            .appendingPathComponent(bundle.lastPathComponent + ".failed")
        try? fm.removeItem(at: failed)
        do {
            try fm.moveItem(at: bundle, to: failed)
            try fm.moveItem(at: source, to: bundle)
        } catch {
            if fm.fileExists(atPath: failed.path), !fm.fileExists(atPath: bundle.path) {
                try? fm.moveItem(at: failed, to: bundle)
            }
            UpdateGuard.markHealthy(configDirectory: configDirectory)
            return false
        }
        UpdateGuard.markHealthy(configDirectory: configDirectory)
        // Relaunch the restored version after this process exits.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1 && /usr/bin/open " + SelfUpdater.shellQuoted(bundle.path)]
        try? relaunch.run()
        notificationService.notifyFailure(
            NSLocalizedString("已回滚到上一版本", comment: "update notification"),
            String(format: NSLocalizedString("新版本连续 3 次未能正常启动，已自动恢复到 v%@",
                                             comment: "update notification"),
                   marker.previousVersion))
        NSApp.terminate(nil)
        return true
    }

    func start() {
        guard service == nil else { return }
        // v3.3.0: if the previous update never reached a healthy startup, put
        // the old bundle back instead of crash-looping forever.
        if recoverFromFailedUpdateIfNeeded() { return }
        let svc = FileVaultService()
        service = svc
        notificationService.setup()
        svc.onFailure.handler = { [weak self] title, body in
            self?.notificationService.notifyFailure(title, body)
        }
        // FR-01: git 自动准备（内嵌 / 多镜像下载）的进度写进菜单状态行，
        // 用户能看到"正在下载 git（ghfast.top 加速）…"而不是干等。
        svc.envGuard.onInstallProgress = { [weak self] stage, _, mirror in
            let text: String
            switch stage {
            case .resolving:
                text = NSLocalizedString("准备下载 git…", comment: "git install status")
            case .downloading:
                text = String(format: NSLocalizedString("正在下载 git（%@）…", comment: "git install status"),
                              NSLocalizedString(mirror, comment: "git mirror name"))
            case .verifying:
                text = NSLocalizedString("正在校验 git 安装包…", comment: "git install status")
            case .extracting:
                text = NSLocalizedString("正在解压 git…", comment: "git install status")
            case .validating:
                text = NSLocalizedString("正在验证 git…", comment: "git install status")
            case .ready:
                text = NSLocalizedString("git 已就绪", comment: "git install status")
            }
            Task { @MainActor in self?.statusLine = text }
        }
        Task { [weak self] in
            do {
                try await svc.startWithAutoInstall(installer: svc.envGuard)
            } catch {
                // Surface the real reason (which mirrors failed, timeouts) instead of a
                // generic "install failed" — FR-01 must never dead-end the user.
                let detail = error.localizedDescription
                let body = (detail.isEmpty || !detail.contains("git"))
                    ? NSLocalizedString("自动安装未完成：请安装 Xcode Command Line Tools 后重启应用。",
                                        comment: "git setup notification")
                    : detail
                self?.notificationService.notifyFailure(
                    NSLocalizedString("Git 环境未就绪", comment: "git setup notification"), body)
                self?.gitSetupError = body
            }
            // The new build reached a working state → confirm the update.
            UpdateGuard.markHealthy(configDirectory: ConfigStore.defaultDirectory)
            await self?.refresh()
            await self?.runOnboardingIfNeeded()
        }
        // Login-launch self-healing: updates replace the bundle, which
        // invalidates ad-hoc SMAppService registration — re-register on intent.
        if LaunchAtLogin.available {
            let want = svc.configStore.load().general.launchAtLoginRequested
            let enabledNow = LaunchAtLogin.isEnabled
            if want && !enabledNow {
                try? LaunchAtLogin.setEnabled(true)
            } else if enabledNow && !want {
                svc.updateGeneral { $0.launchAtLoginRequested = true }
            }
        }
        // FR-20: silent update check shortly after launch (respects the toggle).
        // v3.1.2: a FAILED check retries after 10 minutes — one-shot checks
        // starved updates on flaky networks (the stuck-at-2.6.4 machine).
        if !updateCheckStarted {
            updateCheckStarted = true
            scheduleUpdateCheck(delay: UpdateCheckSchedule.launchDelay)
        }
        svc.onStateChange = { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        // Slow fallback timer covers missed events.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func runOnboardingIfNeeded() async {
        guard let svc = service else { return }
        if svc.configStore.load().roots.isEmpty, !UserDefaults.standard.bool(forKey: "fv.onboarded") {
            UserDefaults.standard.set(true, forKey: "fv.onboarded")
            // v4.2.18: first run goes straight to the one-step add folder
            // sheet instead of the settings page.
            quickAddRequested = true
            openWindowHandler?("dashboard")
        }
    }

    /// Re-enabling "自动检查更新" resumes checking right away instead of
    /// waiting for the next idle poll (v3.1.4).
    func resumeUpdateChecksIfEnabled() {
        guard let svc = service, svc.configStore.load().general.autoCheckUpdates else { return }
        Task { [weak self] in await self?.checkForUpdate(silent: true) }
    }

    /// Recurring update check: 20s after launch, then hourly — and 10 minutes
    /// after a FAILED check (flaky networks must not starve updates).
    ///
    /// v3.1.4: the chain is never broken. A tick that finds auto-checking
    /// disabled reschedules itself instead of returning, so flipping the setting
    /// back on resumes checks without relaunching the app.
    private func scheduleUpdateCheck(delay: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, let svc = service else { return }
            let enabled = svc.configStore.load().general.autoCheckUpdates
            if UpdateCheckSchedule.shouldCheck(autoCheckEnabled: enabled) {
                await checkForUpdate(silent: true)
            }
            let nextDelay = UpdateCheckSchedule.nextDelay(afterFailed: lastUpdateCheckFailed,
                                                          autoCheckEnabled: enabled)
            scheduleUpdateCheck(delay: nextDelay)
        }
    }

    // MARK: - Refresh (menu bar + shared status data)

    func refresh() async {
        guard let svc = service else { return }
        var newRoots: [RootMenuEntry] = []
        // Rebuild the cache every pass: a removed folder used to leave its old
        // .failed state behind, so the menu bar kept a warning icon and the
        // status line kept "推送失败" for a folder that no longer exists.
        var newStatusCache: [String: SyncStatus] = [:]
        let rootPaths = svc.rootsSnapshot()
        notificationService.enabled = svc.configStore.load().general.notificationsEnabled
        for root in rootPaths {
            // v4.0: one repo per protected folder — no subfolder enumeration.
            let st = await svc.sync.status(for: root)
            newStatusCache[root] = st
            newRoots.append(RootMenuEntry(id: root,
                                          name: (root as NSString).lastPathComponent,
                                          path: root,
                                          status: st))
        }
        roots = newRoots
        statusCache = newStatusCache
        rootCount = rootPaths.count
        envReady = svc.detection != nil
        let failed = newStatusCache.values.contains(.failed)
        let state: String
        if failed {
            state = NSLocalizedString("推送失败", comment: "menu state")
        } else if !envReady {
            state = NSLocalizedString("Git 未就绪", comment: "menu state")
        } else {
            state = NSLocalizedString("正常", comment: "menu state")
        }
        // Short enough for a single menu line (v3.1.5: the version lives in
        // 「关于 FileVault」 and the dashboard, not in the menu headline).
        let units = String(format: NSLocalizedString("%d 个文件夹", comment: "menu state"), rootCount)
        statusLine = units + " · " + state
    }

    /// SF Symbol for the overall state (FR-08). Always a visible glyph.
    nonisolated static func statusSymbol(envReady: Bool, statuses: [SyncStatus]) -> String {
        if !envReady || statuses.contains(.failed) { return "exclamationmark.triangle" }
        if statuses.contains(.pendingPush) || statuses.contains(.pushing) { return "arrow.up.arrow.down.circle" }
        return "clock.arrow.circlepath"
    }

    var menuIcon: String {
        Self.statusSymbol(envReady: envReady, statuses: Array(statusCache.values))
    }

    /// Menu identity data (replaces the former AppDelegate.menuSignature).
    nonisolated static func menuSignature(service: FileVaultService, statuses: [String: SyncStatus]) -> String {
        var parts: [String] = []
        parts.append(service.detection == nil ? "noenv" : "env")
        parts.append(String(service.rootsSnapshot().count))
        for root in service.rootsSnapshot() {
            parts.append(root + ":" + (statuses[root]?.rawValue ?? "none"))
        }
        return parts.joined(separator: "|")
    }

    // MARK: - Menu actions

    func commitAllNow() {
        Task { [weak self] in
            guard let self, let svc = service else { return }
            await svc.commitAllNow()
            await refresh()
        }
    }

    func openPath(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "FileVault",
            .applicationVersion: version,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func open(_ sceneID: String) {
        // v4.2.20: 历史 and 恢复 share one window; remember which tab to show.
        switch sceneID {
        case "history":
            recordsTab = .history
            openWindowHandler?("records")
        case "recovery":
            recordsTab = .recover
            openWindowHandler?("records")
        default:
            openWindowHandler?(sceneID)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Update flow (FR-20)

    /// Last silent check failed → surfaced in the menu so flaky networks are
    /// visible instead of silently starving updates (v3.1.2).
    @Published var lastUpdateCheckFailed = false
    /// Set by the menu bar to open the dashboard's quick-add sheet (v4.2.18).
    @Published var quickAddRequested = false
    /// Shared 历史与恢复 window: which tab to show (v4.2.20).
    @Published var recordsTab: RecordsTab = .recover

    /// Guards against overlapping checks (timer tick + manual menu item +
    /// toggling the setting back on used to be able to race).
    private var updateCheckInFlight = false

    /// True while a check or install owns the update flow (drives the menu row).
    var isUpdating: Bool { updateActivity != nil || updateCheckInFlight }

    func checkForUpdate(silent: Bool) async {
        guard service != nil, !updateCheckInFlight else { return }
        updateCheckInFlight = true
        updateNotice = nil
        // v3.1.7: progress and outcome live in the menu, not in a panel.
        if !silent { updateActivity = UpdateActivity(phase: .checking) }
        defer {
            updateCheckInFlight = false
            updateActivity = nil
        }
        let offer: ReleaseInfo?
        do {
            offer = try await updateChecker.check()
            lastUpdateCheckFailed = false
        } catch {
            lastUpdateCheckFailed = true
            // Background failures already get the standing "将在后台重试" line;
            // only a check the user asked for needs the reason spelled out.
            updateNotice = silent ? nil : UpdateStatus.failed(error.localizedDescription)
            return
        }
        guard let offer else {
            // A persistent "已是最新版本" line after every silent hourly check
            // would just be menu clutter.
            updateNotice = silent ? nil : UpdateStatus.upToDate(version)
            return
        }
        // v2.4.0: automatic install — silent self-updating with menu progress.
        notificationService.notifyFailure(
            NSLocalizedString("发现新版本", comment: "update notification"),
            String(format: NSLocalizedString("FileVault %@ 正在自动更新，完成后将自动重启。",
                                             comment: "update notification"), offer.version))
        await installUpdate(offer: offer)
    }

    /// No-op under swift run / .build/debug binaries: replacing an unbundled
    /// executable is impossible, so the menu says so instead of silently
    /// pretending to update (v3.1.7).
    private func installUpdate(offer: ReleaseInfo) async {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            updateNotice = UpdateStatus.developmentBuild
            return
        }
        updateActivity = UpdateActivity(phase: .downloading)
        do {
            let zip = try await UpdateDownloader.download(info: offer) { [weak self] fraction, received, total in
                Task { @MainActor in
                    self?.updateActivity = UpdateActivity(
                        phase: .downloading, fraction: fraction,
                        detail: ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                            + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                }
            }
            updateActivity = UpdateActivity(phase: .verifying)
            do {
                try SelfUpdater.verify(zipURL: zip, expectedSHA256: offer.sha256)
            } catch {
                try? FileManager.default.removeItem(at: zip)
                throw error
            }
            updateActivity = UpdateActivity(phase: .installing)
            try SelfUpdater.replace(bundleURL: Bundle.main.bundleURL, newZipURL: zip, relaunch: false)
            // The extracted bundle is in place; the zip is no longer needed
            // (each successful update used to leave ~22 MB in /tmp).
            try? FileManager.default.removeItem(at: zip)
            // Arm crash-loop detection: the marker is cleared once the new
            // build reaches a working startup (see start()).
            UpdateGuard.beginUpdate(configDirectory: ConfigStore.defaultDirectory,
                                    previousVersion: version,
                                    newVersion: offer.version)
            updateActivity = UpdateActivity(phase: .restarting)
            // Relaunch via a detached helper AFTER we exit: open issued while
            // the old instance is still alive would only activate it (v2.6.6).
            let bundlePath = Bundle.main.bundleURL.path
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1 && /usr/bin/open " + SelfUpdater.shellQuoted(bundlePath)]
            try? relaunch.run()
            try? await Task.sleep(nanoseconds: 600_000_000)
            NSApp.terminate(nil)
            exit(0)
        } catch {
            updateActivity = nil
            updateNotice = UpdateStatus.failed(error.localizedDescription)
        }
    }

    // MARK: - Diagnostics (--open-ui / --render-*)

    /// Window scene ids requested via `--open-ui a,b,c`.
    var pendingOpenUI: [String] = []

    func runDiagnosticsIfRequested() async {
        guard renderRequest != nil || !pendingOpenUI.isEmpty else { return }
        // Wait until the MenuBarExtra label rendered and provided the opener.
        for _ in 0..<100 where openWindowHandler == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard openWindowHandler != nil else {
            FileHandle.standardError.write(Data("diagnostics: openWindow environment unavailable\n".utf8))
            exit(1)
        }
        for id in pendingOpenUI {
            open(id)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if let req = renderRequest {
            open(req.sceneID)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            captureAndExit(windowTitle: req.windowTitle, outPath: req.outPath)
        }
    }

    private func captureAndExit(windowTitle: String, outPath: String) -> Never {
        let target = NSApp.windows.first { $0.title.contains(windowTitle) }
        guard let win = target else {
            FileHandle.standardError.write(Data("render: window '\(windowTitle)' not found\n".utf8))
            exit(1)
        }
        let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(win.windowNumber), [.bestResolution])
        guard let img else { exit(1) }
        let rep = NSBitmapImageRep(cgImage: img)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: outPath))
            print("rendered: " + outPath)
        }
        exit(0)
    }
}
