import AppKit
import FileVaultCore

/// Menu bar resident app delegate (FR-08).
final class AppDelegate: NSObject, NSApplicationDelegate {
    var service: FileVaultService?
    var statusItem: NSStatusItem?
    private var timer: Timer?
    var statusCache: [String: SyncStatus] = [:]
    var healthCache: [String: String] = [:]
    var lastHealthFetch = Date.distantPast
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
        for item in Self.buildMenuItems(service: svc, statuses: statusCache, pendingUpdate: pendingUpdate, healthCache: healthCache, target: self) {
            menu.addItem(item)
        }
        updateStatusIcon(for: svc)
    }

    /// Section header: small, gray, disabled.
    static func sectionHeader(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        it.attributedTitle = NSAttributedString(string: title, attributes: attr)
        it.indentationLevel = 0
        return it
    }

    /// Builds the whole status menu (pure — unit-testable).
    static func buildMenuItems(service: FileVaultService, statuses: [String: SyncStatus],
                               pendingUpdate: ReleaseInfo?, healthCache: [String: String], target: AnyObject?) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let paused = service.pause.isGloballyPaused
        let roots = service.rootsSnapshot()
        var repoCount = 0
        for root in roots { repoCount += service.repoManager.firstLevelFolders(root: root).count }

        let headline = NSMenuItem(title: "FileVault · \(repoCount) 个仓库受守护", action: nil, keyEquivalent: "")
        headline.isEnabled = false
        items.append(headline)
        items.append(.separator())

        items.append(sectionHeader("受保护的目录"))
        for root in roots {
            let folders = service.repoManager.firstLevelFolders(root: root)
            let rootItem = NSMenuItem(title: "📂 \((root as NSString).lastPathComponent)（\(folders.count)）",
                                      action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let openItem = NSMenuItem(title: "在 Finder 中打开根目录", action: #selector(AppDelegate.openRootInFinder(_:)), keyEquivalent: "")
            openItem.target = target
            openItem.representedObject = root
            sub.addItem(openItem)
            sub.addItem(.separator())
            for r in folders {
                let st = statuses[r.path] ?? .noRemote
                let glyph = SettingsWindowController.repoGlyph(st)
                let health = healthCache[r.path] ?? ""
                let row = NSMenuItem(title: "\(r.name)  ·  \(health.isEmpty ? st.rawValue : health)",
                                     action: #selector(AppDelegate.openRepoInFinder(_:)), keyEquivalent: "")
                row.target = target
                row.representedObject = r.path
                row.image = NSImage(systemSymbolName: glyph.symbol, accessibilityDescription: st.rawValue)?
                    .withSymbolConfiguration(.init(paletteColors: [glyph.color]))
                sub.addItem(row)
            }
            rootItem.submenu = sub
            items.append(rootItem)
        }

        items.append(.separator())
        items.append(sectionHeader("操作"))
        let pauseTitle = paused ? "▶ 恢复自动提交" : "⏸ 暂停自动提交"
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(AppDelegate.toggleGlobalPause), keyEquivalent: "p")
        pauseItem.target = target
        pauseItem.keyEquivalentModifierMask = [.command, .shift]
        items.append(pauseItem)
        let commitItem = NSMenuItem(title: "⤴ 立即提交全部", action: #selector(AppDelegate.commitAllNow), keyEquivalent: "")
        commitItem.target = target
        items.append(commitItem)
        let historyItem = NSMenuItem(title: "🕘 历史版本…", action: #selector(AppDelegate.openHistory), keyEquivalent: "")
        historyItem.target = target
        items.append(historyItem)

        items.append(.separator())
        let settingsItem = NSMenuItem(title: "⚙️ 设置…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        settingsItem.target = target
        items.append(settingsItem)
        let updateTitle = pendingUpdate != nil ? "⬆️ 下载并安装更新 \(pendingUpdate!.version)…" : "检查更新…"
        let updateItem = NSMenuItem(title: updateTitle, action: #selector(AppDelegate.checkForUpdateManually), keyEquivalent: "")
        updateItem.target = target
        items.append(updateItem)

        items.append(.separator())
        let quitItem = NSMenuItem(title: "退出 FileVault", action: #selector(AppDelegate.quitApp), keyEquivalent: "q")
        quitItem.target = target
        items.append(quitItem)
        return items
    }

    /// Open a managed REPO folder in Finder (clickable repo rows).
    @objc func openRepoInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Menu bar icon: template SF Symbol so macOS tints it for light/dark bars.
    func updateStatusIcon(for svc: FileVaultService) {
        guard let button = statusItem?.button else { return }
        let statuses = Array(statusCache.values)
        let name = Self.statusSymbol(paused: svc.pause.isGloballyPaused,
                                     envReady: svc.detection != nil,
                                     statuses: statuses)
        let size = NSSize(width: 18, height: 18)
        let image: NSImage
        if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "FileVault") {
            image = symbol
            image.size = size
        } else {
            image = NSImage(size: size)
            image.lockFocus()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: CGRect(x: 4, y: 4, width: 10, height: 10)).fill()
            image.unlockFocus()
        }
        image.isTemplate = true
        button.title = ""
        button.image = image
        button.toolTip = Self.headline(for: svc)
    }

    /// Refresh the per-repo sync status cache (health throttled to 60 s).
    func refreshStatuses() async {
        guard let svc = service else { return }
        var cache: [String: SyncStatus] = [:]
        let roots = svc.rootsSnapshot()
        for root in roots {
            for r in svc.repoManager.firstLevelFolders(root: root) {
                cache[r.path] = await svc.sync.status(for: r.path)
            }
        }
        statusCache = cache
        if Date().timeIntervalSince(lastHealthFetch) > 60 {
            lastHealthFetch = Date()
            var hc: [String: String] = [:]
            for root in roots {
                for r in svc.repoManager.firstLevelFolders(root: root) {
                    if let h = try? await svc.repoManager.health(path: r.path) {
                        hc[r.path] = "\(h.commitCount) 次 · \(h.sizeText)"
                    }
                }
            }
            healthCache = hc
        }
    }

    /// SF Symbol for the current overall state (FR-08). Always a visible glyph.
    static func statusSymbol(paused: Bool, envReady: Bool, statuses: [SyncStatus]) -> String {
        if paused { return "pause.circle" }
        if !envReady || statuses.contains(.failed) { return "exclamationmark.triangle" }
        if statuses.contains(.pendingPush) || statuses.contains(.pushing) { return "arrow.up.arrow.down.circle" }
        return "clock.arrow.circlepath"
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
