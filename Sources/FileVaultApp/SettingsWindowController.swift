import AppKit
import FileVaultCore

/// Settings window: manage roots and per-repo remote configuration (FR-02/06/07).
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let service: FileVaultService?
    var urlFields: [String: NSTextField] = [:]
    var pushToggles: [String: NSButton] = [:]
    var healthLabels: [String: NSTextField] = [:]
    var sshLabels: [String: NSTextField] = [:]
    private var gitignoreEditors: [String: GitignoreEditorController] = [:]

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
        // Vertical stack: [login toggle (bundled only)] + [scrollable settings grid].
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        if LaunchAtLogin.available {
            let toggle = NSButton(checkboxWithTitle: "登录时启动 FileVault", target: self, action: #selector(toggleLaunchAtLogin(_:)))
            toggle.state = LaunchAtLogin.isEnabled ? .on : .off
            stack.addArrangedSubview(toggle)
        }

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 10
        grid.column(at: 0).width = 440
        grid.column(at: 1).width = 80
        grid.xPlacement = .fill
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 460))
        scroll.hasVerticalScroller = true
        scroll.documentView = grid
        stack.addArrangedSubview(scroll)

        window?.contentView = stack
        if let content = window?.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
                scroll.heightAnchor.constraint(equalToConstant: LaunchAtLogin.available ? 440 : 480),
            ])
        }
        self.grid = grid
        rebuild()
    }

    @objc func toggleLaunchAtLogin(_ sender: NSButton) {
        do {
            try LaunchAtLogin.setEnabled(sender.state == .on)
        } catch {
            let alert = NSAlert()
            alert.messageText = "设置登录自启失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            sender.state = LaunchAtLogin.isEnabled ? .on : .off
        }
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
                let nameLabel = NSTextField(labelWithString: "  📁 " + r.name)
                let healthLabel = NSTextField(labelWithString: "…")
                healthLabel.textColor = .secondaryLabelColor
                healthLabels[r.path] = healthLabel
                grid.addRow(with: [nameLabel, healthLabel])
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
                    let health = await svc.repoManager.health(path: r.path)
                    await MainActor.run {
                        field.stringValue = url ?? ""
                        toggle.state = auto ? .on : .off
                        self?.healthLabels[r.path]?.stringValue = health.summary
                    }
                    let isSsh = url?.hasPrefix("git@") == true || url?.hasPrefix("ssh://") == true
                    if isSsh, let guide = svc.sshChecker.guidance {
                        await MainActor.run {
                            self?.sshLabels[r.path]?.stringValue = guide
                        }
                    }
                }
                let save = NSButton(title: "保存", target: self, action: #selector(saveRepoConfig(_:)))
                save.identifier = NSUserInterfaceItemIdentifier(r.path)
                let pushBtn = NSButton(title: "立即推送", target: self, action: #selector(pushNow(_:)))
                pushBtn.identifier = NSUserInterfaceItemIdentifier(r.path)
                let testBtn = NSButton(title: "测试连接", target: self, action: #selector(testConnection(_:)))
                testBtn.identifier = NSUserInterfaceItemIdentifier(r.path)
                let ignoreBtn = NSButton(title: "忽略规则", target: self, action: #selector(editGitignore(_:)))
                ignoreBtn.identifier = NSUserInterfaceItemIdentifier(r.path)
                let stack = NSStackView(views: [save, pushBtn, testBtn, ignoreBtn])
                stack.orientation = .horizontal
                stack.spacing = 8
                grid.addRow(with: [stack, NSGridCell.emptyContentView])
                let sshLabel = NSTextField(labelWithString: "")
                sshLabel.textColor = .systemRed
                sshLabels[r.path] = sshLabel
                grid.addRow(with: [sshLabel, NSGridCell.emptyContentView])
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

    @objc func testConnection(_ sender: NSButton) {
        guard let svc = service, let repoPath = sender.identifier?.rawValue else { return }
        Task {
            let result = await svc.sync.testConnectivity(repoPath: repoPath)
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = result.ok ? "✅ 连接成功" : "⚠️ 连接失败"
                alert.informativeText = result.detail
                alert.runModal()
            }
        }
    }

    @objc func editGitignore(_ sender: NSButton) {
        guard let svc = service, let repoPath = sender.identifier?.rawValue else { return }
        let editor = GitignoreEditorController(repoPath: repoPath, repos: svc.repoManager)
        gitignoreEditors[repoPath] = editor
        editor.onSaved = { [weak self] in
            DispatchQueue.main.async { self?.rebuild() }
        }
        editor.showWindow(nil)
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
