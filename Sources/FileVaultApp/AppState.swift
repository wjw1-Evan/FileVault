import AppKit
import SwiftUI
import FileVaultCore

/// One repo row inside the menu's protected-directories submenu.
struct RepoRow: Identifiable, Equatable {
    let id: String       // path
    let name: String
    let path: String
    let status: SyncStatus
    let health: String
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

    /// Update progress (FR-20): non-nil while an update transaction is visible.
    struct UpdateStage: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var fraction: Double?
        var detail: String
    }
    @Published var updateStage: UpdateStage?

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
    private var healthCache: [String: String] = [:]
    private var lastHealthFetch = Date.distantPast
    private var timer: Timer?
    private var updateCheckStarted = false

    // Internal for unit tests; the app uses `shared`.
    init(service: FileVaultService? = nil) {
        if let service { self.service = service }
    }

    // MARK: - Lifecycle

    func start() {
        guard service == nil else { return }
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
            scheduleUpdateCheck(delay: 20)
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

    /// Recurring update check: 20s after launch, then daily — and 10 minutes
    /// after a FAILED check (flaky networks must not starve updates).
    private func scheduleUpdateCheck(delay: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, let svc = service,
                  svc.configStore.load().general.autoCheckUpdates else { return }
            await checkForUpdate(silent: true)
            let nextDelay: TimeInterval = lastUpdateCheckFailed ? 600 : 24 * 3600
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
                var health = healthCache[r.path] ?? ""
                if health.isEmpty {
                    if let h = try? await svc.repoManager.health(path: r.path) {
                        health = "\(h.commitCount) 次 · \(h.sizeText)"
                        healthCache[r.path] = health
                    }
                }
                rows.append(RepoRow(id: r.path, name: r.name, path: r.path, status: st, health: health))
            }
            newRoots.append(RootMenuEntry(id: root, name: (root as NSString).lastPathComponent, path: root, repos: rows))
        }
        if Date().timeIntervalSince(lastHealthFetch) > 60 {
            lastHealthFetch = Date()
            for root in rootPaths {
                for r in svc.repoManager.firstLevelFolders(root: root) {
                    if let h = try? await svc.repoManager.health(path: r.path) {
                        healthCache[r.path] = "\(h.commitCount) 次 · \(h.sizeText)"
                    }
                }
            }
        }
        roots = newRoots
        repoCount = count
        envReady = svc.detection != nil
        paused = svc.pause.isGloballyPaused
        let failed = statusCache.values.contains(.failed)
        let state: String
        if paused {
            state = "已暂停自动提交"
        } else if failed {
            state = "部分仓库推送失败，点击菜单查看"
        } else if !envReady {
            state = "Git 环境未就绪"
        } else {
            state = "全部正常"
        }
        statusLine = "\(repoCount) 个仓库受守护 · \(state) · v\(version)"
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

    func checkForUpdate(silent: Bool) async {
        guard let svc = service else { return }
        let offer: ReleaseInfo?
        do {
            offer = try await updateChecker.check()
            lastUpdateCheckFailed = false
        } catch {
            lastUpdateCheckFailed = true
            if !silent { await alert("检查更新失败", "\(error.localizedDescription)") }
            return
        }
        guard let offer else {
            if !silent { await alert("已是最新版本", "当前版本 \(version)，没有可用的更新。") }
            return
        }
        // v2.4.0: automatic install — silent self-updating with progress.
        notificationService.notifyFailure("发现新版本", "FileVault \(offer.version) 正在自动更新，完成后将自动重启。")
        await installUpdate(offer: offer)
    }

    private func alert(_ title: String, _ body: String) async {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }

    private func installUpdate(offer: ReleaseInfo) async {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        updateStage = UpdateStage(text: "准备更新…", fraction: nil, detail: "")
        openWindowHandler?("update-progress")
        do {
            let zip = try await UpdateDownloader.download(info: offer) { [weak self] fraction, received, total in
                Task { @MainActor in
                    self?.updateStage = UpdateStage(
                        text: "下载更新…", fraction: fraction,
                        detail: ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                            + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                }
            }
            updateStage = UpdateStage(text: "校验完整性…", fraction: nil, detail: "")
            try SelfUpdater.verify(zipURL: zip, expectedSHA256: offer.sha256)
            updateStage = UpdateStage(text: "安装新版本…", fraction: nil, detail: "")
            try SelfUpdater.replace(bundleURL: Bundle.main.bundleURL, newZipURL: zip, relaunch: false)
            updateStage = UpdateStage(text: "重启应用…", fraction: nil, detail: "")
            // Relaunch via a detached helper AFTER we exit: `open` issued while
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
            updateStage = nil
            await alert("自动更新失败", error.localizedDescription)
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
