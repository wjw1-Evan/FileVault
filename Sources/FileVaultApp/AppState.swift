import AppKit
import SwiftUI
import FileVaultCore

/// One repo row inside the menu's protected-directories submenu.
struct RepoRow: Identifiable, Equatable {
    let id: String       // path
    let name: String
    let path: String
    let status: SyncStatus
}

struct RootMenuEntry: Identifiable {
    let id: String       // path
    let name: String
    let path: String
    let repos: [RepoRow]
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

    @Published var repoCount = 0
    @Published var roots: [RootMenuEntry] = []
    @Published var paused = false
    @Published var envReady = false
    @Published var statusLine = "正在加载…"
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
              UpdateGuard.shouldRollback(marker),
              let source = UpdateGuard.rollbackSource(for: Bundle.main.bundleURL) else {
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
        notificationService.notifyFailure("已回滚到上一版本",
                                          "新版本连续 3 次未能正常启动，已自动恢复到 v\(marker.previousVersion)。")
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
        Task { [weak self] in
            do {
                try await svc.startWithAutoInstall(installer: svc.envGuard)
            } catch {
                self?.notificationService.notifyFailure("Git 环境未就绪", "自动安装未完成：请安装 Xcode Command Line Tools 后重启应用。")
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
            openWindowHandler?("settings")
        }
    }

    /// Re-enabling "自动检查更新" resumes checking right away instead of
    /// waiting for the next idle poll (v3.1.4).
    func resumeUpdateChecksIfEnabled() {
        guard let svc = service, svc.configStore.load().general.autoCheckUpdates else { return }
        Task { [weak self] in await self?.checkForUpdate(silent: true) }
    }

    /// Recurring update check: 20s after launch, then daily — and 10 minutes
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
        var count = 0
        let rootPaths = svc.rootsSnapshot()
        for root in rootPaths {
            let folders = svc.repoManager.firstLevelFolders(root: root)
            count += folders.count
            var rows: [RepoRow] = []
            for r in folders {
                let st = await svc.sync.status(for: r.path)
                statusCache[r.path] = st
                rows.append(RepoRow(id: r.path, name: r.name, path: r.path, status: st))
            }
            newRoots.append(RootMenuEntry(id: root, name: (root as NSString).lastPathComponent, path: root, repos: rows))
        }
        roots = newRoots
        repoCount = count
        envReady = svc.detection != nil
        paused = svc.pause.isGloballyPaused
        let failed = statusCache.values.contains(.failed)
        let state: String
        if paused {
            state = "已暂停"
        } else if failed {
            state = "推送失败"
        } else if !envReady {
            state = "Git 未就绪"
        } else {
            state = "正常"
        }
        // Short enough for a single menu line (v3.1.5: the version lives in
        // 「关于 FileVault」 and the dashboard, not in the menu headline).
        statusLine = "\(repoCount) 个仓库 · \(state)"
    }

    /// SF Symbol for the overall state (FR-08). Always a visible glyph.
    nonisolated static func statusSymbol(paused: Bool, envReady: Bool, statuses: [SyncStatus]) -> String {
        if paused { return "pause.circle" }
        if !envReady || statuses.contains(.failed) { return "exclamationmark.triangle" }
        if statuses.contains(.pendingPush) || statuses.contains(.pushing) { return "arrow.up.arrow.down.circle" }
        return "clock.arrow.circlepath"
    }

    var menuIcon: String {
        Self.statusSymbol(paused: paused, envReady: envReady, statuses: Array(statusCache.values))
    }

    /// Menu identity data (replaces the former AppDelegate.menuSignature).
    nonisolated static func menuSignature(service: FileVaultService, statuses: [String: SyncStatus]) -> String {
        var parts: [String] = []
        parts.append(service.pause.isGloballyPaused ? "P" : "R")
        parts.append(service.detection == nil ? "noenv" : "env")
        parts.append(String(service.rootsSnapshot().count))
        for root in service.rootsSnapshot() {
            for r in service.repoManager.firstLevelFolders(root: root) {
                parts.append(r.path + ":" + (statuses[r.path]?.rawValue ?? "none"))
            }
        }
        return parts.joined(separator: "|")
    }

    // MARK: - Menu actions

    func toggleGlobalPause() {
        guard let svc = service else { return }
        let now = !svc.pause.isGloballyPaused
        svc.pause.setGlobalPaused(now)
        if !now {
            Task { await svc.commitAllNow() }
        }
        Task { await refresh() }
    }

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
        if let handler = openWindowHandler {
            handler(sceneID)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Update flow (FR-20)

    /// Last silent check failed → surfaced in the menu so flaky networks are
    /// visible instead of silently starving updates (v3.1.2).
    @Published var lastUpdateCheckFailed = false

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
            // A persistent "已是最新版本" line after every silent daily check
            // would just be menu clutter.
            updateNotice = silent ? nil : UpdateStatus.upToDate(version)
            return
        }
        // v2.4.0: automatic install — silent self-updating with menu progress.
        notificationService.notifyFailure("发现新版本", "FileVault \(offer.version) 正在自动更新，完成后将自动重启。")
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
            try SelfUpdater.verify(zipURL: zip, expectedSHA256: offer.sha256)
            updateActivity = UpdateActivity(phase: .installing)
            try SelfUpdater.replace(bundleURL: Bundle.main.bundleURL, newZipURL: zip, relaunch: false)
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
