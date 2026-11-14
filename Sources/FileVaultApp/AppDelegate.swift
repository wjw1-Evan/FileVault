import AppKit
import FileVaultCore

/// Menu bar resident app delegate (FR-08).
final class AppDelegate: NSObject, NSApplicationDelegate {
    var service: FileVaultService?
    var statusItem: NSStatusItem?
    private var timer: Timer?
    var statusCache: [String: SyncStatus] = [:]
    weak var settingsWindow: SettingsWindowController?
    weak var historyWindow: HistoryWindowController?

    static let pausedIcon = "⏸"
    static let okIcon = "●"
    static let pendingIcon = "●"
    static let errorIcon = "●"

    let notifications = NotificationService()
    /// Pending update offer (shown in menu + notification) (FR-20).
    var pendingUpdate: ReleaseInfo?
    lazy var updateChecker = UpdateChecker(
        currentVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0",
        fetcher: GhReleaseFetcher()
    )

    func applicationDidFinishLaunching(_ n: Notification) {
        let svc = FileVaultService()
        service = svc
        notifications.setup()
        svc.onFailure.handler = { [weak self] title, body in
            self?.notifications.notifyFailure(title, body)
        }
        Task {
            do {
                try await svc.start()
            } catch {
                // Git env failure surfaced in menu; keep app alive.
            }
            await MainActor.run { self.refreshMenu() }
        }
        // FR-20: silent update check shortly after launch, once per launch.
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await self.checkForUpdate(silent: true)
        }
        // Event-driven refresh: rebuild the menu only when state actually changes.
        // A slow fallback timer (15s) covers missed events without busy polling.
        svc.onStateChange = { [weak self] in
            Task { @MainActor in
                await self?.refreshStatuses()
                self?.refreshMenu()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshStatuses()
                self?.refreshMenu()
            }
        }
    }

    init(service: FileVaultService?) {
        self.service = service
    }

    func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        statusItem = item
        item.menu = menu
        refreshMenu()
    }

    @objc func toggleGlobalPause() {
        guard let svc = service else { return }
        let now = !(svc.pause.isGloballyPaused)
        svc.pause.setGlobalPaused(now)
        if !now {
            Task { await svc.commitAllNow() }
        }
        refreshMenu()
    }

    // MARK: - Menu building

    private var lastMenuSignature: String = ""

    func refreshMenu(force: Bool = false) {
        guard let item = statusItem, let menu = item.menu, let svc = service else { return }
        let signature = Self.menuSignature(service: svc, statuses: statusCache)
        if !force && signature == lastMenuSignature { return }
        lastMenuSignature = signature
        menu.removeAllItems()
        // Status headline.
        let title = Self.headline(for: svc)
        let head = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        // One item per root with per-repo status submenu.
        for root in svc.rootsSnapshot() {
            let last = (root as NSString).lastPathComponent
            let rootItem = NSMenuItem(title: "📂 " + last, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let openItem = NSMenuItem(title: "在 Finder 中打开", action: #selector(openRootInFinder(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = root
            sub.addItem(openItem)
            sub.addItem(.separator())
            let repos = svc.repoManager.firstLevelFolders(root: root)
            for r in repos {
                let st = statusCache[r.path] ?? .noRemote
                let symbol: String
                switch st {
                case .noRemote: symbol = "·"
                case .synced: symbol = "✓"
                case .pendingPush: symbol = "↑"
                case .pushing: symbol = "…"
                case .failed: symbol = "⚠"
                }
                sub.addItem(NSMenuItem(title: "\(symbol) \(r.name)", action: nil, keyEquivalent: ""))
            }
            if repos.isEmpty {
                sub.addItem(NSMenuItem(title: "（无子文件夹）", action: nil, keyEquivalent: ""))
            }
            rootItem.submenu = sub
            menu.addItem(rootItem)
        }
        menu.addItem(.separator())
        let pauseTitle = svc.pause.isGloballyPaused ? "▶ 恢复自动提交" : "⏸ 暂停自动提交"
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(toggleGlobalPause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        let commitItem = NSMenuItem(title: "⤴ 立即提交全部", action: #selector(commitAllNow), keyEquivalent: "")
        commitItem.target = self
        menu.addItem(commitItem)
        let historyItem = NSMenuItem(title: "🕘 历史版本…", action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        let settingsItem = NSMenuItem(title: "⚙️ 设置…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let updateTitle = pendingUpdate != nil ? "⬆️ 下载并安装更新 \(pendingUpdate!.version)…" : "检查更新…"
        let updateItem = NSMenuItem(title: updateTitle, action: #selector(checkForUpdateManually), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 FileVault", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        // Colored status icon: red=failed, yellow=pending/pushing, green=ok (FR-08).
        let statuses = statusCache.values
        let icon: String
        if svc.pause.isGloballyPaused {
            icon = "⏸"
        } else if svc.detection == nil {
            icon = "⚠️"
        } else if statuses.contains(.failed) {
            icon = "🔴"
        } else if statuses.contains(.pendingPush) || statuses.contains(.pushing) {
            icon = "🟡"
        } else if statuses.contains(.synced) {
            icon = "🟢"
        } else {
            icon = "·"
        }
        item.button?.title = icon
    }

    /// Refresh the per-repo sync status cache from SyncManager (actor).
    func refreshStatuses() async {
        guard let svc = service else { return }
        var cache: [String: SyncStatus] = [:]
        for root in svc.rootsSnapshot() {
            for r in svc.repoManager.firstLevelFolders(root: root) {
                cache[r.path] = await svc.sync.status(for: r.path)
            }
        }
        statusCache = cache
    }

    static func menuSignature(service: FileVaultService, statuses: [String: SyncStatus]) -> String {
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

    /// Overall headline for the menu bar menu and icon.
    static func headline(for svc: FileVaultService) -> String {
        if svc.pause.isGloballyPaused { return "⏸ 已暂停自动提交" }
        guard svc.detection != nil else { return "⚠ Git 环境未就绪" }
        return "FileVault 正在守护 \(svc.rootsSnapshot().count) 个根目录"
    }

    @objc func openSettings() {
        if settingsWindow == nil || settingsWindow?.window == nil {
            settingsWindow = SettingsWindowController(service: service)
        }
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openHistory() {
        if historyWindow == nil || historyWindow?.window == nil {
            historyWindow = HistoryWindowController(service: service)
        }
        historyWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func commitAllNow() {
        guard let svc = service else { return }
        Task { await svc.commitAllNow() }
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    /// Open a managed root folder in Finder (FR-21).
    @objc func openRootInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - Auto-update (FR-20)

    @objc func checkForUpdateManually() {
        Task { await checkForUpdate(silent: false) }
    }

    func checkForUpdate(silent: Bool) async {
        guard pendingUpdate == nil else {
            await installIfConfirmed(offer: pendingUpdate!, confirmed: true)
            return
        }
        let offer: ReleaseInfo?
        do {
            offer = try await updateChecker.check()
        } catch {
            if !silent { await MainActor.run { Self.alert("检查更新失败", "\(error.localizedDescription)") } }
            return
        }
        guard let offer else {
            if !silent { await MainActor.run { Self.alert("已是最新版本", "当前版本 \(updateChecker.currentVersion)，没有可用的更新。") } }
            return
        }
        await MainActor.run {
            self.pendingUpdate = offer
            self.refreshMenu()
            self.notifications.notifyFailure("发现新版本", "FileVault \(offer.version) 已发布，菜单中选择「检查更新」即可安装。")
            if !silent { Self.alert("发现新版本", "FileVault \(offer.version) 已发布，是否下载并安装？") }
        }
        await installIfConfirmed(offer: offer, confirmed: !silent)
    }

    /// Download, verify and swap the bundle. App relaunches via `open`.
    func installIfConfirmed(offer: ReleaseInfo, confirmed: Bool) async {
        guard confirmed, Bundle.main.bundleURL.pathExtension == "app" else { return }
        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fv-update-\(UUID().uuidString.prefix(6))")
            let zip = try await SelfUpdater.download(info: offer, into: tmp)
            try SelfUpdater.verify(zipURL: zip, expectedSHA256: offer.sha256)
            try SelfUpdater.replace(bundleURL: Bundle.main.bundleURL, newZipURL: zip, relaunch: false)
            // Exit so the relaunch actually starts the NEW binary (otherwise
            // LaunchServices would just activate this still-running instance).
            await MainActor.run { NSApp.terminate(nil) }
            exit(0)
        } catch {
            await MainActor.run { Self.alert("自动更新失败", error.localizedDescription) }
        }
    }

    static func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }
}
