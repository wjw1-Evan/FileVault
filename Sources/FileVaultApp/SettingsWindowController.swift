import AppKit
import FileVaultCore

/// Settings window — card-based layout (v1.2.0 redesign):
/// each managed root renders as a rounded card containing its repos.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let service: FileVaultService?
    var urlFields: [String: NSTextField] = [:]
    var pushToggles: [String: NSButton] = [:]
    var healthLabels: [String: NSTextField] = [:]
    var statusDots: [String: NSImageView] = [:]
    var sshLabels: [String: NSTextField] = [:]
    var rootCards: [NSView] = []
    private var gitignoreEditors: [String: GitignoreEditorController] = [:]
    var contentStack: NSStackView!
    var scrollHost: NSScrollView!

    /// Per-repo status glyph + tint (testable).
    static func repoGlyph(_ status: SyncStatus) -> (symbol: String, color: NSColor) {
        switch status {
        case .noRemote: return ("circle.dashed", .systemGray)
        case .synced: return ("checkmark.circle.fill", .systemGreen)
        case .pendingPush: return ("arrow.up.circle", .systemOrange)
        case .pushing: return ("arrow.triangle.2.circlepath", .systemBlue)
        case .failed: return ("exclamationmark.triangle.fill", .systemRed)
        }
    }

    init(service: FileVaultService?) {
        self.service = service
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
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

    // MARK: - Layout

    func buildUI() {
        // Proven pattern: the scroll IS the contentView (AppKit sizes it to the
        // window); the document stack follows the clip width via autoresizing.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 612, height: 552))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.edgeInsets = NSEdgeInsets(top: 12, left: 13, bottom: 12, right: 13)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = contentStack
        scrollHost = scroll
        window?.contentView = scroll
        // Standard AL scroll pattern: pin top/lead/trail; bottom >= clip bottom.
        let dLead = contentStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor)
        let dTrail = contentStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor)
        let dTop = contentStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        let dBottom = contentStack.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor)
        for c in [dLead, dTrail, dTop, dBottom] { c.isActive = true }

        if LaunchAtLogin.available {
            let toggle = NSButton(checkboxWithTitle: "登录时启动 FileVault", target: self, action: #selector(toggleLaunchAtLogin(_:)))
            toggle.state = LaunchAtLogin.isEnabled ? .on : .off
            contentStack.addArrangedSubview(toggle)
        }
        rebuild()
    }

    /// Rebuild all root cards.
    func rebuild() {
        guard let svc = service, contentStack != nil else { return }
        contentStack.views.forEach { $0.removeFromSuperview() }
        urlFields.removeAll()
        pushToggles.removeAll()
        healthLabels.removeAll()
        statusDots.removeAll()
        sshLabels.removeAll()
        rootCards.removeAll()
        for root in svc.rootsSnapshot() {
            let card = makeRootCard(root: root, svc: svc)
            rootCards.append(card)
            contentStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalToConstant: 586).isActive = true
        }
        let addBtn = NSButton(title: "＋ 添加根目录…", target: self, action: #selector(addRootAction))
        addBtn.bezelStyle = .rounded
        addBtn.controlSize = .large
        contentStack.addArrangedSubview(addBtn)
    }

    /// One rounded card per managed root (styled stack — NSBox wraps poorly
    /// with Auto Layout, a stack's fitting size is always correct).
    func makeRootCard(root: String, svc: FileVaultService) -> NSView {
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 8
        card.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.borderWidth = 1

        // Card header: name + path + spacer + actions.
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        let nameLine = NSStackView()
        nameLine.orientation = .vertical
        nameLine.alignment = .leading
        nameLine.spacing = 1
        let nameLabel = NSTextField(labelWithString: "📁 " + (root as NSString).lastPathComponent)
        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let pathLabel = NSTextField(labelWithString: root)
        pathLabel.font = .systemFont(ofSize: 10.5)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        nameLine.addArrangedSubview(nameLabel)
        nameLine.addArrangedSubview(pathLabel)
        header.addArrangedSubview(nameLine)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(spacer)
        let openBtn = NSButton(title: "打开", target: self, action: #selector(openRootInFinder(_:)))
        openBtn.identifier = NSUserInterfaceItemIdentifier(root)
        openBtn.bezelStyle = .rounded
        openBtn.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "打开")
        openBtn.imagePosition = .imageLeading
        let removeBtn = NSButton(title: "移除", target: self, action: #selector(removeRootAction(_:)))
        removeBtn.identifier = NSUserInterfaceItemIdentifier(root)
        removeBtn.bezelStyle = .rounded
        header.addArrangedSubview(openBtn)
        header.addArrangedSubview(removeBtn)
        card.addArrangedSubview(header)

        // Repos inside the card.
        let folders = svc.repoManager.firstLevelFolders(root: root)
        for r in folders {
            card.addArrangedSubview(makeSeparator())
            card.addArrangedSubview(makeRepoSection(repo: r, svc: svc))
        }
        if folders.isEmpty {
            let empty = NSTextField(labelWithString: "此根目录暂无子文件夹")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            card.addArrangedSubview(empty)
        }
        // Width is fixed; height wraps content via the stack's fitting size.
        card.widthAnchor.constraint(equalToConstant: 586).isActive = true
        return card
    }

    private func makeSeparator() -> NSView {
        let sep = NSBox()
        sep.boxType = .separator
        return sep
    }

    /// Per-repo section: status dot + name + health, remote row, action row.
    func makeRepoSection(repo: SubRepo, svc: FileVaultService) -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6

        // Row 1: status glyph + name + health summary.
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        let dot = NSImageView()
        let glyph = Self.repoGlyph(.noRemote)
        dot.image = NSImage(systemSymbolName: glyph.symbol, accessibilityDescription: "状态")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        dot.contentTintColor = glyph.color
        statusDots[repo.path] = dot
        titleRow.addArrangedSubview(dot)
        let nameLabel = NSTextField(labelWithString: repo.name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleRow.addArrangedSubview(nameLabel)
        let health = NSTextField(labelWithString: "…")
        health.font = .systemFont(ofSize: 11)
        health.textColor = .secondaryLabelColor
        healthLabels[repo.path] = health
        titleRow.addArrangedSubview(health)
        section.addArrangedSubview(titleRow)

        // Row 2: remote URL + auto-push toggle.
        let remoteRow = NSStackView()
        remoteRow.orientation = .horizontal
        remoteRow.spacing = 8
        let field = NSTextField(string: "")
        field.placeholderString = "远程仓库地址（留空 = 仅本地）"
        field.tag = 1
        urlFields[repo.path] = field
        let toggle = NSButton(checkboxWithTitle: "自动推送", target: nil, action: nil)
        pushToggles[repo.path] = toggle
        remoteRow.addArrangedSubview(field)
        remoteRow.addArrangedSubview(toggle)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        section.addArrangedSubview(remoteRow)

        // Row 3: action buttons + ssh guidance.
        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = 6
        let save = NSButton(title: "保存", target: self, action: #selector(saveRepoConfig(_:)))
        save.identifier = NSUserInterfaceItemIdentifier(repo.path)
        save.bezelStyle = .rounded
        let pushBtn = NSButton(title: "立即推送", target: self, action: #selector(pushNow(_:)))
        pushBtn.identifier = NSUserInterfaceItemIdentifier(repo.path)
        pushBtn.bezelStyle = .rounded
        let testBtn = NSButton(title: "测试连接", target: self, action: #selector(testConnection(_:)))
        testBtn.identifier = NSUserInterfaceItemIdentifier(repo.path)
        testBtn.bezelStyle = .rounded
        let ignoreBtn = NSButton(title: "忽略规则", target: self, action: #selector(editGitignore(_:)))
        ignoreBtn.identifier = NSUserInterfaceItemIdentifier(repo.path)
        ignoreBtn.bezelStyle = .rounded
        actionRow.addArrangedSubview(save)
        actionRow.addArrangedSubview(pushBtn)
        actionRow.addArrangedSubview(testBtn)
        actionRow.addArrangedSubview(ignoreBtn)
        let actionSpacer = NSView()
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionRow.addArrangedSubview(actionSpacer)
        section.addArrangedSubview(actionRow)

        let sshLabel = NSTextField(labelWithString: "")
        sshLabel.font = .systemFont(ofSize: 10.5)
        sshLabel.textColor = .systemRed
        sshLabels[repo.path] = sshLabel
        section.addArrangedSubview(sshLabel)

        // Async fill: url/toggle/health/status dot/ssh guidance.
        Task { [weak self] in
            let url = await svc.repoManager.remoteURL(path: repo.path)
            let auto = await svc.sync.autoPushEnabled(repoPath: repo.path)
            let healthInfo = await svc.repoManager.health(path: repo.path)
            let st = await svc.sync.status(for: repo.path)
            let glyph = Self.repoGlyph(st)
            await MainActor.run {
                field.stringValue = url ?? ""
                toggle.state = auto ? .on : .off
                self?.healthLabels[repo.path]?.stringValue = healthInfo.summary
                self?.statusDots[repo.path]?.image = NSImage(systemSymbolName: glyph.symbol, accessibilityDescription: "状态")?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
                self?.statusDots[repo.path]?.contentTintColor = glyph.color
                let isSsh = url?.hasPrefix("git@") == true || url?.hasPrefix("ssh://") == true
                let guide = isSsh ? svc.sshChecker.guidance : nil
                self?.sshLabels[repo.path]?.stringValue = guide ?? ""
            }
        }
        return section
    }

    // MARK: - Actions

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

    /// Open a managed root folder in Finder (FR-21).
    @objc func openRootInFinder(_ sender: NSButton) {
        guard let root = sender.identifier?.rawValue else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: root))
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
