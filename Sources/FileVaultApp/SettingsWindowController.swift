import AppKit
import FileVaultCore

/// Settings window: manage roots and per-repo remote configuration (FR-02/06/07).
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let service: FileVaultService?
    var urlFields: [String: NSTextField] = [:]
    var pushToggles: [String: NSButton] = [:]

    init(service: FileVaultService?) {
        self.service = service
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        win.title = "FileVault 设置"
        super.init(window: win)
        win.delegate = self
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ n: Notification) {
        // keep controller alive via delegate hold
    }


    var grid: NSGridView!

    func buildUI() {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 10
        grid.column(at: 0).width = 440
        grid.column(at: 1).width = 80
        grid.xPlacement = .fill
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 520))
        scroll.hasVerticalScroller = true
        scroll.documentView = grid
        window?.contentView = scroll
        self.grid = grid
        rebuild()
    }

    /// Rebuild the settings content: roots + per-repo remote config rows.
    func rebuild() {
        guard let svc = service, grid != nil else { return }
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        urlFields.removeAll()
        pushToggles.removeAll()
        for root in svc.rootsSnapshot() {
            let nameLabel = NSTextField(labelWithString: "根目录: " + (root as NSString).lastPathComponent)
            nameLabel.font = NSFont.boldSystemFont(ofSize: 13)
            grid.addRow(with: [nameLabel, NSView()])
            for r in svc.repoManager.firstLevelFolders(root: root) {
                let row = [NSTextField(labelWithString: "  📁 " + r.name)]
                grid.addRow(with: row)
                let field = NSTextField(string: "")
                field.placeholderString = "远程仓库地址（留空 = 仅本地）"
                field.tag = 1
                urlFields[r.path] = field
                let toggle = NSButton(checkboxWithTitle: "自动推送", target: nil, action: nil)
                pushToggles[r.path] = toggle
                grid.addRow(with: [field, toggle])
                                Task { [weak self] in
                    let url = await svc.repoManager.remoteURL(path: r.path)
                    let auto = await svc.sync.autoPushEnabled(repoPath: r.path)
                    await MainActor.run {
                        field.stringValue = url ?? ""
                        toggle.state = auto ? .on : .off
                    }
                }
                let save = NSButton(title: "保存", target: self, action: #selector(saveRepoConfig(_:)))
                save.identifier = NSUserInterfaceItemIdentifier(r.path)
                let pushBtn = NSButton(title: "立即推送", target: self, action: #selector(pushNow(_:)))
                pushBtn.identifier = NSUserInterfaceItemIdentifier(r.path)
                grid.addRow(with: [save, pushBtn])
                grid.addRow(with: [NSGridCell.emptyContentView, NSGridCell.emptyContentView])
            }
            let removeBtn = NSButton(title: "移除此根目录", target: self, action: #selector(removeRootAction(_:)))
            removeBtn.identifier = NSUserInterfaceItemIdentifier(root)
            grid.addRow(with: [removeBtn, NSView()])
            grid.addRow(with: [NSGridCell.emptyContentView, NSGridCell.emptyContentView])
        }
        let addBtn = NSButton(title: "添加根目录…", target: self, action: #selector(addRootAction))
        grid.addRow(with: [addBtn, NSView()])
    }

    // MARK: - Actions

    @objc func saveRepoConfig(_ sender: NSButton) {
        guard let svc = service, let repoPath = sender.identifier?.rawValue else { return }
        let url = urlFields[repoPath]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let auto = pushToggles[repoPath]?.state == .on
        Task {
            do {
                if url.isEmpty {
                    try await svc.sync.clearRemote(repoPath: repoPath)
                } else {
                    try await svc.sync.configureRemote(repoPath: repoPath, url: url, autoPush: auto)
                }
                await MainActor.run { self.reloadAfterSave() }
            } catch {
                await MainActor.run { self.reloadAfterSave() }
            }
        }
    }

    @objc func pushNow(_ sender: NSButton) {
        guard let svc = service, let repoPath = sender.identifier?.rawValue else { return }
        Task { await svc.sync.pushNow(repoPath: repoPath) }
    }

    func reloadAfterSave() {
        rebuild()
    }

    @objc func addRootAction() {
        guard let svc = service else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.message = "选择要保护的根目录（第一层子文件夹将被独立版本管理）"
        let modalResult = panel.runModal()
        if modalResult == .OK, let url = panel.url {
            Task {
                try? await svc.addRoot(path: url.path)
                await MainActor.run { self.rebuild() }
            }
        }
    }

    @objc func removeRootAction(_ sender: NSButton) {
        guard let svc = service, let root = sender.identifier?.rawValue else { return }
        Task {
            await svc.removeRoot(path: root)
            await MainActor.run { self.rebuild() }
        }
    }
}
