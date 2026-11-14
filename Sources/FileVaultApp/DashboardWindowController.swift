import AppKit
import FileVaultCore

/// The main dashboard (v2.0.0): status overview + recent activity + repo cards.
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    let service: FileVaultService?
    var statusLabel: NSTextField?
    var activityStack: NSStackView?
    var rootsStack: NSStackView?
    private var refreshTimer: Timer?

    init(service: FileVaultService?) {
        self.service = service
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "FileVault"
        super.init(window: win)
        win.delegate = self
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ n: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Build

    func buildUI() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 612, height: 596))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: FVDesign.margin, bottom: 16, right: FVDesign.margin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        window?.contentView = scroll
        let dTop = stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        let dLead = stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor)
        let dTrail = stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor)
        let dBottom = stack.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor)
        for c in [dTop, dLead, dTrail, dBottom] { c.isActive = true }

        // Header.
        let header = FVDesign.card()
        let iconView = NSImageView()
iconView.image = FVDesign.lineIcon("clock.arrow.circlepath", pointSize: 18)
iconView.contentTintColor = .controlAccentColor
header.addArrangedSubview(iconView)
header.addArrangedSubview(FVDesign.header("FileVault — 文件时光机"))
        let status = NSTextField(labelWithString: "正在加载…")
        status.font = FVDesign.bodyFont
        status.textColor = .secondaryLabelColor
        statusLabel = status
        header.addArrangedSubview(status)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalToConstant: FVDesign.cardWidth).isActive = true

        // Recent activity card.
        let activity = FVDesign.card()
        activity.addArrangedSubview(FVDesign.header("最近活动"))
        let activityStack = NSStackView()
        activityStack.orientation = .vertical
        activityStack.alignment = .leading
        activityStack.spacing = 4
        self.activityStack = activityStack
        activity.addArrangedSubview(activityStack)
        stack.addArrangedSubview(activity)
        activity.widthAnchor.constraint(equalToConstant: FVDesign.cardWidth).isActive = true

        // Roots card.
        let roots = FVDesign.card()
        roots.addArrangedSubview(FVDesign.header("受保护的目录"))
        let rootsStack = NSStackView()
        rootsStack.orientation = .vertical
        rootsStack.alignment = .leading
        rootsStack.spacing = 6
        self.rootsStack = rootsStack
        roots.addArrangedSubview(rootsStack)
        stack.addArrangedSubview(roots)
        roots.widthAnchor.constraint(equalToConstant: FVDesign.cardWidth).isActive = true

        // Footer actions.
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        let addBtn = FVDesign.button("添加根目录…", action: #selector(addRootFromDashboard), target: self)
        addBtn.image = FVDesign.lineIcon("plus.circle")
        addBtn.imagePosition = .imageLeading
        let settingsBtn = FVDesign.button("设置", action: #selector(openSettingsFromDashboard), target: self)
        settingsBtn.image = FVDesign.lineIcon("gearshape")
        settingsBtn.imagePosition = .imageLeading
        let historyBtn = FVDesign.button("历史", action: #selector(openHistoryFromDashboard), target: self)
        historyBtn.image = FVDesign.lineIcon("clock.arrow.circlepath")
        historyBtn.imagePosition = .imageLeading
        actions.addArrangedSubview(addBtn)
        actions.addArrangedSubview(settingsBtn)
        actions.addArrangedSubview(historyBtn)
        stack.addArrangedSubview(actions)
        // Trailing spacer absorbs extra height so cards keep their fitting size.
        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        bottomSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(bottomSpacer)
        for card in stack.arrangedSubviews where card is NSStackView {
            card.setContentHuggingPriority(.required, for: .vertical)
        }
    }

    // MARK: - Show / refresh

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refresh()
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    struct ActivityItem {
        var repoName: String
        var subject: String
        var date: Date
        var synced: Bool
    }

    func refresh() {
        guard let svc = service, statusLabel != nil else { return }
        Task { @MainActor in
            let roots = svc.rootsSnapshot()
            var repoCount = 0
            var activity: [ActivityItem] = []
            var failed = 0
            for root in roots {
                for r in svc.repoManager.firstLevelFolders(root: root) {
                    repoCount += 1
                    let st = await svc.sync.status(for: r.path)
                    if st == .failed { failed += 1 }
                    if let log = try? await svc.history.commits(repoPath: r.path, limit: 3) {
                        for c in log {
                            activity.append(ActivityItem(repoName: r.name, subject: c.subject,
                                                         date: c.date, synced: st != .failed))
                        }
                    }
                }
            }
            activity.sort { $0.date > $1.date }
            let top = Array(activity.prefix(10))
            // Header.
            let state: String
            if svc.pause.isGloballyPaused {
                state = "已暂停自动提交"
            } else if failed > 0 {
                state = String(failed) + " 个仓库推送失败，点击菜单查看"
            } else if svc.detection == nil {
                state = "Git 环境未就绪"
            } else {
                state = "全部正常"
            }
            statusLabel?.stringValue = String(repoCount) + " 个仓库受守护 · " + state
            // Activity rows.
            activityStack?.views.forEach { $0.removeFromSuperview() }
            if top.isEmpty {
                activityStack?.addArrangedSubview(FVDesign.caption("还没有任何提交——向文件夹写入文件后会自动记录"))
            } else {
                for a in top {
                    let row = NSStackView()
                    row.orientation = .horizontal
                    row.spacing = 6
                    let f = DateFormatter()
                    f.dateFormat = "MM-dd HH:mm"
                    row.addArrangedSubview(FVDesign.statusGlyph("checkmark.circle", .systemGreen))
                    row.addArrangedSubview(FVDesign.caption(f.string(from: a.date)))
                    let nameLabel = NSTextField(labelWithString: a.repoName)
                    nameLabel.font = FVDesign.captionFont
                    nameLabel.textColor = .secondaryLabelColor
                    row.addArrangedSubview(nameLabel)
                    let subjectLabel = NSTextField(labelWithString: a.subject)
                    subjectLabel.font = FVDesign.captionFont
                    subjectLabel.lineBreakMode = .byTruncatingTail
                    row.addArrangedSubview(subjectLabel)
                    activityStack?.addArrangedSubview(row)
                }
            }
            // Repo rows.
            rootsStack?.views.forEach { $0.removeFromSuperview() }
            for root in roots {
                let folders = svc.repoManager.firstLevelFolders(root: root)
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 6
                let folderIcon = NSImageView()
folderIcon.image = FVDesign.lineIcon("folder", pointSize: 13)
row.addArrangedSubview(folderIcon)
let nameLabel = NSTextField(labelWithString: (root as NSString).lastPathComponent)
                nameLabel.font = FVDesign.bodyFont
                row.addArrangedSubview(nameLabel)
                let countLabel = FVDesign.caption(String(folders.count) + " 个仓库")
                row.addArrangedSubview(countLabel)
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                row.addArrangedSubview(spacer)
                row.addArrangedSubview(FVDesign.button("打开", action: #selector(openRoot(_:)), target: self, identifier: root))
                rootsStack?.addArrangedSubview(row)
            }
            if roots.isEmpty {
                rootsStack?.addArrangedSubview(FVDesign.caption("尚未添加根目录——点击下方「＋ 添加根目录…」开始"))
            }
        }
    }

    // MARK: - Actions

    @objc func openRoot(_ sender: NSButton) {
        guard let root = sender.identifier?.rawValue else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: root))
    }

    @objc func addRootFromDashboard() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择要保护的根目录（第一层子文件夹将被独立版本管理）"
        if panel.runModal() == .OK, let url = panel.url, let svc = service {
            Task {
                try? await svc.addRoot(path: url.path)
                await MainActor.run { self.refresh() }
            }
        }
    }

    @objc func openSettingsFromDashboard() {
        (NSApp.delegate as? AppDelegate)?.openSettings()
    }

    @objc func openHistoryFromDashboard() {
        (NSApp.delegate as? AppDelegate)?.openHistory()
    }
}
