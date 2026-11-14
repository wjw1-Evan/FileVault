import AppKit
import FileVaultCore

/// Settings window — card-based layout (v1.2.0 redesign):
/// each managed root renders as a rounded card containing its repos.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    let service: FileVaultService?
    var urlFields: [String: NSTextField] = [:]
    var pushToggles: [String: NSButton] = [:]
    var healthLabels: [String: NSTextField] = [:]
    var statusDots: [String: NSImageView] = [:]
    var sshLabels: [String: NSTextField] = [:]
    var rootCards: [NSView] = []
    private var gitignoreEditors: [String: GitignoreEditorController] = [:]
    /// Fields the user has typed into (async refill must not wipe them).
    var userEditedPaths: Set<String> = []
    /// Per-repo status message line (save result / connectivity / ssh guidance).
    var messageLabels: [String: NSTextField] = [:]
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
        messageLabels.removeAll()
        userEditedPaths.removeAll()
        rootCards.removeAll()
        contentStack.addArrangedSubview(makeGeneralCard(svc: svc))
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

    /// General preferences card (v1.3.0 complete settings).
    func makeGeneralCard(svc: FileVaultService) -> NSView {
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
        card.widthAnchor.constraint(equalToConstant: 586).isActive = true

        let header = NSTextField(labelWithString: "⚙️ 通用设置")
        header.font = .systemFont(ofSize: 14, weight: .semibold)
        card.addArrangedSubview(header)
        card.addArrangedSubview(makeSeparator())

        let general = svc.configStore.load().general
        let toggles = NSStackView()
        toggles.orientation = .horizontal
        toggles.spacing = 16
        if LaunchAtLogin.available {
            let login = NSButton(checkboxWithTitle: "登录时启动", target: self, action: #selector(toggleLaunchAtLogin(_:)))
            login.state = LaunchAtLogin.isEnabled ? .on : .off
            toggles.addArrangedSubview(login)
        }
        let notif = NSButton(checkboxWithTitle: "推送失败通知", target: self, action: #selector(generalToggleChanged(_:)))
        notif.identifier = NSUserInterfaceItemIdentifier("notificationsEnabled")
        notif.state = general.notificationsEnabled ? .on : .off
        toggles.addArrangedSubview(notif)
        let autoUpd = NSButton(checkboxWithTitle: "自动检查更新", target: self, action: #selector(generalToggleChanged(_:)))
        autoUpd.identifier = NSUserInterfaceItemIdentifier("autoCheckUpdates")
        autoUpd.state = general.autoCheckUpdates ? .on : .off
        toggles.addArrangedSubview(autoUpd)
        card.addArrangedSubview(toggles)

        let debounceRow = NSStackView()
        debounceRow.orientation = .horizontal
        debounceRow.spacing = 8
        let dLabel = NSTextField(labelWithString: "自动提交延迟")
        dLabel.font = .systemFont(ofSize: 12)
        debounceRow.addArrangedSubview(dLabel)
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 90, height: 24), pullsDown: false)
        for opt in [2, 5, 10, 30] {
            popup.addItem(withTitle: "\(opt) 秒")
            popup.lastItem?.representedObject = opt
        }
        popup.selectItem(at: [2, 5, 10, 30].firstIndex(of: general.debounceSeconds) ?? 1)
        popup.target = self
        popup.action = #selector(debounceChanged(_:))
        debounceRow.addArrangedSubview(popup)
        let dNote = NSTextField(labelWithString: "（文件变动后等待静默的秒数）")
        dNote.font = .systemFont(ofSize: 10.5)
        dNote.textColor = .secondaryLabelColor
        debounceRow.addArrangedSubview(dNote)
        card.addArrangedSubview(debounceRow)

        let thresholdRow = NSStackView()
        thresholdRow.orientation = .horizontal
        thresholdRow.spacing = 8
        let tLabel = NSTextField(labelWithString: "大文件阈值")
        tLabel.font = .systemFont(ofSize: 12)
        thresholdRow.addArrangedSubview(tLabel)
        let tField = NSTextField(string: String(general.largeFileThresholdMB))
        tField.identifier = NSUserInterfaceItemIdentifier("largeFileThresholdMB")
        tField.delegate = self
        tField.target = self
        tField.action = #selector(thresholdSubmitted(_:))
        tField.frame = NSRect(x: 0, y: 0, width: 70, height: 22)
        tField.translatesAutoresizingMaskIntoConstraints = false
        tField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        thresholdRow.addArrangedSubview(tField)
        let tNote = NSTextField(labelWithString: "MB（超过此大小的文件自动排除出版本管理）")
        tNote.font = .systemFont(ofSize: 10.5)
        tNote.textColor = .secondaryLabelColor
        thresholdRow.addArrangedSubview(tNote)
        card.addArrangedSubview(thresholdRow)

        let openBtn = NSButton(title: "打开配置文件", target: self, action: #selector(openConfigFile))
        openBtn.bezelStyle = .rounded
        card.addArrangedSubview(openBtn)
        return card
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
        let cfgRoot = svc.configStore.load().roots.first { $0.path == root }
        let pause = NSButton(checkboxWithTitle: "⏸ 暂停", target: self, action: #selector(pauseRootChanged(_:)))
        pause.identifier = NSUserInterfaceItemIdentifier(root)
        pause.state = (cfgRoot?.paused ?? false) ? .on : .off
        let openBtn = NSButton(title: "打开", target: self, action: #selector(openRootInFinder(_:)))
        openBtn.identifier = NSUserInterfaceItemIdentifier(root)
        openBtn.bezelStyle = .rounded
        openBtn.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "打开")
        openBtn.imagePosition = .imageLeading
        let removeBtn = NSButton(title: "移除", target: self, action: #selector(removeRootAction(_:)))
        removeBtn.identifier = NSUserInterfaceItemIdentifier(root)
        removeBtn.bezelStyle = .rounded
        header.addArrangedSubview(pause)
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
        field.placeholderString = "远程仓库地址（留空 = 仅本地，回车保存）"
        field.tag = 1
        field.delegate = self
        field.identifier = NSUserInterfaceItemIdentifier(repo.path)
        field.target = self
        field.action = #selector(remoteFieldSubmitted(_:))
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
        let pullBtn = NSButton(title: "拉取", target: self, action: #selector(pullRepo(_:)))
        pullBtn.identifier = NSUserInterfaceItemIdentifier(repo.path)
        pullBtn.bezelStyle = .rounded
        let createBtn = NSButton(title: "建仓", target: self, action: #selector(createRepoAction(_:)))
        createBtn.identifier = NSUserInterfaceItemIdentifier(repo.path)
        createBtn.bezelStyle = .rounded
        createBtn.toolTip = "在 GitHub 创建私有仓库并绑定"
        actionRow.addArrangedSubview(save)
        actionRow.addArrangedSubview(pushBtn)
        actionRow.addArrangedSubview(testBtn)
        actionRow.addArrangedSubview(ignoreBtn)
        actionRow.addArrangedSubview(pullBtn)
        actionRow.addArrangedSubview(createBtn)
        let actionSpacer = NSView()
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionRow.addArrangedSubview(actionSpacer)
        section.addArrangedSubview(actionRow)

        let messageLabel = NSTextField(labelWithString: "")
        messageLabel.font = .systemFont(ofSize: 10.5)
        messageLabel.textColor = .systemRed
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabels[repo.path] = messageLabel
        sshLabels[repo.path] = messageLabel
        section.addArrangedSubview(messageLabel)

        // Async fill: url/toggle/health/status dot/ssh guidance.
        Task { [weak self] in
            let url = await svc.repoManager.remoteURL(path: repo.path)
            let auto = await svc.sync.autoPushEnabled(repoPath: repo.path)
            let healthInfo = await svc.repoManager.health(path: repo.path)
            let st = await svc.sync.status(for: repo.path)
            let glyph = Self.repoGlyph(st)
            await MainActor.run {
                // Never wipe text the user is typing (async fill vs input race).
                if self?.userEditedPaths.contains(repo.path) != true {
                    field.stringValue = url ?? ""
                }
                toggle.state = auto ? .on : .off
                self?.healthLabels[repo.path]?.stringValue = healthInfo.summary
                self?.statusDots[repo.path]?.image = NSImage(systemSymbolName: glyph.symbol, accessibilityDescription: "状态")?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
                self?.statusDots[repo.path]?.contentTintColor = glyph.color
                let isSsh = url?.hasPrefix("git@") == true || url?.hasPrefix("ssh://") == true
                let guide = isSsh ? svc.sshChecker.guidance : nil
                // Do not clobber live save/pull feedback with the async fill.
                if (self?.messageLabels[repo.path]?.stringValue ?? "").isEmpty {
                    self?.messageLabels[repo.path]?.stringValue = guide ?? ""
                }
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
        saveRemote(repoPath: repoPath)
    }

    /// Enter in the remote field saves too (v1.2.3: the field is a first-class control).
    @objc func remoteFieldSubmitted(_ sender: NSTextField) {
        guard let repoPath = sender.identifier?.rawValue else { return }
        saveRemote(repoPath: repoPath)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let repoPath = field.identifier?.rawValue else { return }
        userEditedPaths.insert(repoPath)
    }

    /// Shared save path for button and Enter: configure + test + inline feedback.
    func saveRemote(repoPath: String) {
        guard let svc = service else { return }
        let url = urlFields[repoPath]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let auto = pushToggles[repoPath]?.state == .on
        let setStage: (String, NSColor) -> Void = { text, color in
            DispatchQueue.main.async {
                self.messageLabels[repoPath]?.stringValue = text
                self.messageLabels[repoPath]?.textColor = color
            }
        }
        Task {
            setStage("正在保存…", .secondaryLabelColor)
            do {
                if url.isEmpty {
                    try await svc.sync.clearRemote(repoPath: repoPath)
                    await MainActor.run { self.reloadAfterSave() }
                    setStage("已清除远程仓库（仅本地模式）", .secondaryLabelColor)
                    return
                }
                try await svc.sync.configureRemote(repoPath: repoPath, url: url, autoPush: auto)
                // GitHub HTTPS remotes need credentials; gh provides them for free.
                if url.contains("github.com") && url.hasPrefix("https://") {
                    _ = try? await GitRunner.ghAuthSetupGit()
                }
                setStage("已保存，正在测试连接…", .secondaryLabelColor)
                let conn = await svc.sync.testConnectivity(repoPath: repoPath)
                userEditedPaths.remove(repoPath)
                await MainActor.run { self.reloadAfterSave() }
                if conn.ok {
                    setStage(auto ? "✓ 已保存并连通，提交后将自动推送" : "✓ 已保存并连通（自动推送未开启）", .systemGreen)
                } else {
                    setStage("⚠️ 已保存但连接失败：\(conn.detail)。请确认远程仓库已在平台上创建且凭证可用。", .systemRed)
                }
            } catch {
                setStage("⚠️ 保存失败：\(error.localizedDescription)", .systemRed)
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

    /// General toggles (notifications / auto-check-updates) persist + apply.
    @objc func generalToggleChanged(_ sender: NSButton) {
        guard let svc = service, let key = sender.identifier?.rawValue else { return }
        let on = sender.state == .on
        svc.updateGeneral { g in
            switch key {
            case "notificationsEnabled": g.notificationsEnabled = on
            case "autoCheckUpdates": g.autoCheckUpdates = on
            default: break
            }
        }
    }

    @objc func debounceChanged(_ sender: NSPopUpButton) {
        guard let svc = service,
              let seconds = sender.selectedItem?.representedObject as? Int else { return }
        svc.updateGeneral { $0.debounceSeconds = seconds }
    }

    @objc func thresholdSubmitted(_ sender: NSTextField) {
        guard let svc = service, let mb = Int(sender.stringValue.trimmingCharacters(in: .whitespaces)),
              mb > 0 else { return }
        svc.updateGeneral { $0.largeFileThresholdMB = mb }
        messageFeedbackGlobal("已应用：大文件阈值 \(mb) MB")
    }

    func messageFeedbackGlobal(_ text: String) {
        DispatchQueue.main.async {
            self.messageLabels.first?.value.stringValue = text
        }
    }

    @objc func openConfigFile() {
        let file = service?.configStore.directory.appendingPathComponent("config.json")
        guard let file else { return }
        NSWorkspace.shared.open(file)
    }

    /// Per-root pause (FR-13).
    @objc func pauseRootChanged(_ sender: NSButton) {
        guard let svc = service, let root = sender.identifier?.rawValue else { return }
        let on = sender.state == .on
        Task {
            await svc.setRootPaused(on, root: root)
            await MainActor.run { self.reloadAfterSave() }
        }
    }

    /// Create a private GitHub repo and bind it to this repo (P2 gh integration).
    @objc func createRepoAction(_ sender: NSButton) {
        guard let svc = service, let repoPath = sender.identifier?.rawValue else { return }
        let alert = NSAlert()
        alert.messageText = "在 GitHub 创建私有仓库并绑定"
        alert.informativeText = "输入仓库名（将创建为当前 gh 账号下的私有仓库）："
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "my-notes"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        alert.addButton(withTitle: "创建并绑定")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let setMsg: (String, NSColor) -> Void = { text, color in
                DispatchQueue.main.async {
                    self.messageLabels[repoPath]?.stringValue = text
                    self.messageLabels[repoPath]?.textColor = color
                }
            }
            setMsg("正在创建仓库 " + name + "…", .secondaryLabelColor)
            Task {
                do {
                    let url = try await GhRepoCreator().createPrivate(name: name)
                    await MainActor.run {
                        self.urlFields[repoPath]?.stringValue = url
                    }
                    saveRemote(repoPath: repoPath)
                } catch {
                    setMsg("⚠️ 创建失败: " + error.localizedDescription, .systemRed)
                }
            }
        }
    }

    /// Pull with ff-only + inline feedback.
    @objc func pullRepo(_ sender: NSButton) {
        guard let svc = service, let repoPath = sender.identifier?.rawValue else { return }
        let setMsg: (String, NSColor) -> Void = { text, color in
            DispatchQueue.main.async {
                self.messageLabels[repoPath]?.stringValue = text
                self.messageLabels[repoPath]?.textColor = color
            }
        }
        setMsg("正在拉取…", .secondaryLabelColor)
        Task {
            do {
                let out = try await svc.repoManager.pull(path: repoPath)
                let upToDate = out.contains("Already up to date")
                setMsg(upToDate ? "✓ 已是最新" : "✓ 已拉取远程更新（ff-only）", .systemGreen)
            } catch {
                setMsg("⚠️ 拉取失败：\(error.localizedDescription)", .systemRed)
            }
        }
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
