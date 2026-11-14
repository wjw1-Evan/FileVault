import AppKit
import FileVaultCore

/// History window (v2.5.0 simplified): repo pickers + commit table + per-file
/// inline restore. No mode switching — one list, one click per file.
final class HistoryWindowController: NSWindowController, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate {
    let service: FileVaultService?
    var rootPopup: NSPopUpButton?
    var repoPopup: NSPopUpButton?
    var rootPaths: [String] = []
    var currentFolders: [SubRepo] = []
    var table: NSTableView?
    var commits: [CommitInfo] = []
    var filesTable: NSTableView?
    var changedFiles: [(status: String, path: String)] = []
    var filesLabel: NSTextField?
    private var loadGeneration = 0
    private var filesGeneration = 0
    /// The commit whose changed files are currently displayed.
    private var currentCommit: CommitInfo?

    init(service: FileVaultService?) {
        self.service = service
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "FileVault 历史"
        win.minSize = NSSize(width: 640, height: 480)
        super.init(window: win)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build

    func buildUI() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 636, height: 560))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        let page = NSStackView()
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 12, left: FVDesign.margin, bottom: 12, right: FVDesign.margin)
        page.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = page
        window?.contentView = scroll
        let pTop = page.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        let pLead = page.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor)
        let pTrail = page.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor)
        let pBottom = page.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor)
        for c in [pTop, pLead, pTrail, pBottom] { c.isActive = true }

        // Row 1: two-level pickers.
        let rootPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 190, height: 26), pullsDown: false)
        rootPopup.target = self
        rootPopup.action = #selector(rootChanged)
        self.rootPopup = rootPopup
        let repoPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 170, height: 26), pullsDown: false)
        repoPopup.target = self
        repoPopup.action = #selector(repoChanged)
        self.repoPopup = repoPopup
        let pickers = NSStackView(views: [rootPopup, repoPopup])
        pickers.orientation = .horizontal
        pickers.spacing = 8
        page.addArrangedSubview(pickers)

        // Row 2: commit table (fixed height; the page scrolls).
        let tableScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 612, height: 220))
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        let tv = NSTableView(frame: tableScroll.bounds)
        let hashCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hash"))
        hashCol.title = "版本"
        hashCol.width = 78
        let subjectCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("subject"))
        subjectCol.title = "提交信息"
        subjectCol.width = 330
        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateCol.title = "时间"
        dateCol.width = 140
        tv.addTableColumn(hashCol)
        tv.addTableColumn(subjectCol)
        tv.addTableColumn(dateCol)
        tv.dataSource = self
        tv.delegate = self
        tv.usesAlternatingRowBackgroundColors = true
        tv.rowHeight = 24
        table = tv
        tableScroll.documentView = tv
        tv.sizeLastColumnToFit()
        page.addArrangedSubview(tableScroll)
        tableScroll.widthAnchor.constraint(equalToConstant: 612).isActive = true
        tableScroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        // Row 3: changed files of the selected commit — restore inline per row.
        let filesHeader = FVDesign.header("此提交包含的文件（点「恢复」回到该时点）")
        page.addArrangedSubview(filesHeader)
        let filesScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 612, height: 110))
        filesScroll.hasVerticalScroller = true
        let ftv = NSTableView(frame: filesScroll.bounds)
        let stCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        stCol.title = "变更"
        stCol.width = 52
        let fCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        fCol.title = "文件"
        fCol.width = 400
        let rCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("restore"))
        rCol.title = "操作"
        rCol.width = 110
        ftv.addTableColumn(stCol)
        ftv.addTableColumn(fCol)
        ftv.addTableColumn(rCol)
        ftv.dataSource = self
        ftv.delegate = self
        ftv.rowHeight = 26
        filesTable = ftv
        filesScroll.documentView = ftv
        ftv.sizeLastColumnToFit()
        page.addArrangedSubview(filesScroll)
        filesScroll.widthAnchor.constraint(equalToConstant: 612).isActive = true
        filesScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true

        // Row 4: feedback + repo rollback.
        let filesLabel = NSTextField(labelWithString: "选择一个提交，查看并恢复它包含的文件")
        filesLabel.font = FVDesign.captionFont
        filesLabel.textColor = .secondaryLabelColor
        filesLabel.lineBreakMode = .byTruncatingTail
        filesLabel.translatesAutoresizingMaskIntoConstraints = false
        filesLabel.widthAnchor.constraint(equalToConstant: 612).isActive = true
        self.filesLabel = filesLabel
        page.addArrangedSubview(filesLabel)
        let rollback = NSButton(title: "回滚整个文件夹到此版本", target: self, action: #selector(rollbackAction))
        rollback.target = self
        rollback.bezelStyle = .rounded
        page.addArrangedSubview(rollback)

        window?.setContentSize(NSSize(width: 636, height: 560))
        reloadRepos()
    }

    // MARK: - Data

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        reloadRepos()
    }

    func reloadRepos() {
        guard let svc = service else { return }
        rootPaths = svc.rootsSnapshot()
        rootPopup?.removeAllItems()
        for root in rootPaths {
            rootPopup?.addItem(withTitle: (root as NSString).lastPathComponent)
            rootPopup?.lastItem?.image = FVDesign.lineIcon("folder")
        }
        guard !rootPaths.isEmpty else {
            currentFolders = []
            commits = []
            table?.reloadData()
            changedFiles = []
            filesTable?.reloadData()
            filesLabel?.stringValue = "尚未添加任何根目录——先在设置中添加根目录"
            return
        }
        rootPopup?.selectItem(at: 0)
        populateRepoPopup()
    }

    func currentRootPath() -> String? {
        let idx = rootPopup?.indexOfSelectedItem ?? -1
        guard rootPaths.indices.contains(idx) else { return nil }
        return rootPaths[idx]
    }

    func currentRepo() -> String? {
        let idx = repoPopup?.indexOfSelectedItem ?? -1
        guard currentFolders.indices.contains(idx) else { return nil }
        return currentFolders[idx].path
    }

    func populateRepoPopup() {
        guard let svc = service, let root = currentRootPath() else { return }
        currentFolders = svc.repoManager.firstLevelFolders(root: root)
        repoPopup?.removeAllItems()
        for f in currentFolders {
            repoPopup?.addItem(withTitle: f.name)
            repoPopup?.lastItem?.image = FVDesign.lineIcon("folder")
        }
        guard !currentFolders.isEmpty else {
            commits = []
            table?.reloadData()
            changedFiles = []
            filesTable?.reloadData()
            filesLabel?.stringValue = "该根目录暂无子文件夹"
            return
        }
        repoPopup?.selectItem(at: 0)
        loadForCurrentSelection()
    }

    /// Load commits + tracked files; the async completion restores the user's
    /// selection (a stale rebuild must not reset the popup).
    func loadForCurrentSelection() {
        guard let svc = service, let repo = currentRepo() else { return }
        Task {
            let files = await svc.repoManager.listFiles(path: repo)
            await MainActor.run {
                guard self.currentRepo() == repo else { return }
                self.reloadCommits()
            }
        }
    }

    func reloadCommits() {
        guard let svc = service, let repo = currentRepo() else { return }
        loadGeneration += 1
        let generation = loadGeneration
        filesLabel?.stringValue = "正在加载提交历史…"
        Task {
            let list = (try? await svc.history.commits(repoPath: repo, limit: 100)) ?? []
            guard generation == self.loadGeneration else { return }
            await MainActor.run {
                guard generation == self.loadGeneration else { return }
                self.commits = list
                self.table?.reloadData()
                if list.isEmpty {
                    self.changedFiles = []
                    self.filesTable?.reloadData()
                    self.filesLabel?.stringValue = "该文件夹还没有提交历史"
                } else {
                    self.table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
            }
        }
    }

    /// Changed files of the selected commit (with inline restore buttons).
    func loadChangedFiles() {
        guard let svc = service, let repo = currentRepo() else { return }
        let row = table?.selectedRow ?? -1
        guard row >= 0, row < commits.count else {
            filesLabel?.stringValue = "选择一个提交以查看其包含的文件"
            return
        }
        let commit = commits[row]
        currentCommit = commit
        filesGeneration += 1
        let generation = filesGeneration
        Task {
            let lines = (try? await svc.history.changedFiles(repoPath: repo, hash: commit.hash)) ?? []
            guard generation == self.filesGeneration else { return }
            await MainActor.run {
                guard generation == self.filesGeneration else { return }
                self.changedFiles = lines.map { line -> (String, String) in
                    let parts = line.split(separator: "\t", maxSplits: 1)
                    return (parts.count > 1 ? String(parts[0]) : "?", parts.count > 1 ? String(parts[1]) : line)
                }
                self.filesTable?.reloadData()
                self.filesLabel?.stringValue = self.changedFiles.isEmpty
                    ? "「" + commit.subject + "」没有文件变更"
                    : "「" + commit.subject + "」包含 " + String(self.changedFiles.count) + " 个文件"
            }
        }
    }

    // MARK: - Actions

    @objc func rootChanged() {
        let fresh = service?.rootsSnapshot() ?? []
        if rootPopup?.numberOfItems != fresh.count {
            reloadRepos()
            return
        }
        populateRepoPopup()
    }

    @objc func repoChanged() {
        table?.deselectAll(nil)
        reloadCommits()
    }

    /// Inline per-file restore: one click on the row's button (FR-10).
    @objc func restoreFileRow(_ sender: NSButton) {
        guard let svc = service, let repo = currentRepo(),
              let file = sender.identifier?.rawValue else { return }
        guard let commit = currentCommit else { return }
        let alert = NSAlert()
        alert.messageText = "恢复文件"
        alert.informativeText = "把「" + file + "」恢复到 " + commit.shortHash + "（" + commit.subject + "）？恢复会形成一次新的提交。"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        if FVDesign.activateAndRunModal(alert) == .alertFirstButtonReturn {
            filesLabel?.stringValue = "正在恢复 " + file + "…"
            Task {
                do {
                    _ = try await svc.history.restoreFile(repoPath: repo, file: file, to: commit.hash)
                    await MainActor.run {
                        filesLabel?.stringValue = "✓ 已恢复 " + file + " 到 " + commit.shortHash
                        self.reloadCommits()
                    }
                } catch {
                    await MainActor.run {
                        filesLabel?.stringValue = "⚠️ 恢复失败: " + error.localizedDescription
                    }
                }
            }
        }
    }

    @objc func rollbackAction() {
        guard let svc = service, let repo = currentRepo() else { return }
        let row = table?.selectedRow ?? -1
        guard row >= 0, row < commits.count else {
            filesLabel?.stringValue = "先在列表中选择一个版本"
            return
        }
        let target = commits[row]
        let alert = NSAlert()
        alert.messageText = "回滚确认"
        alert.informativeText = "把「" + (repo as NSString).lastPathComponent + "」整个回滚到 " + target.shortHash + "（" + target.subject + "）？此操作会丢弃之后的提交。"
        alert.addButton(withTitle: "回滚")
        alert.addButton(withTitle: "取消")
        if FVDesign.activateAndRunModal(alert) == .alertFirstButtonReturn {
            filesLabel?.stringValue = "正在回滚…"
            Task {
                do {
                    try await svc.history.resetRepo(repoPath: repo, to: target.hash)
                    await MainActor.run {
                        filesLabel?.stringValue = "✓ 已回滚到 " + target.shortHash
                        self.reloadCommits()
                    }
                } catch {
                    await MainActor.run {
                        filesLabel?.stringValue = "⚠️ 回滚失败: " + error.localizedDescription
                    }
                }
            }
        }
    }

    // MARK: - Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === filesTable { return changedFiles.count }
        return commits.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        // Files table with inline per-row restore button.
        if tableView === filesTable {
            let entry = changedFiles[row]
            if id == "restore" {
                let btn = NSButton(title: "恢复", target: self, action: #selector(restoreFileRow(_:)))
                btn.bezelStyle = .rounded
                btn.identifier = NSUserInterfaceItemIdentifier(entry.path)
                return btn
            }
            let text = id == "status" ? entry.status : entry.path
            return Self.makeCell(text)
        }
        let c = commits[row]
        let text: String
        switch id {
        case "hash": text = c.shortHash
        case "date": text = Self.dateText(c.date)
        default: text = c.subject
        }
        return Self.makeCell(text)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === filesTable { return }
        loadChangedFiles()
    }

    static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    static func makeCell(_ text: String) -> NSView {
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: text)
        tf.font = .systemFont(ofSize: 12)
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
