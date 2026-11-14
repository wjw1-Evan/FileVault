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
}
