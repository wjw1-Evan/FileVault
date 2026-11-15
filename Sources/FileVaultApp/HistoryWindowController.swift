import AppKit
import FileVaultCore

/// History window (v2.5.0 simplified): repo pickers + commit table + per-file
/// inline restore. No mode switching — one list, one click per file.
final class HistoryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate {
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
    /// Auto-refresh (v2.6.5): service state listener + coalescing reload task.
    private var stateListenerToken: UUID?
    private var pendingStateReload: Task<Void, Never>?

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
        win.delegate = self
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build

    func buildUI() {
        // Flexible-middle layout: the commit table absorbs window resize
        // (width AND height); other rows are fixed.
        let host = NSView()
        window?.contentView = host

        let rootPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 190, height: 26), pullsDown: false)
        rootPopup.target = self
        rootPopup.action = #selector(rootChanged)
        self.rootPopup = rootPopup
        let repoPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 170, height: 26), pullsDown: false)
        repoPopup.target = self
        repoPopup.action = #selector(repoChanged)
        self.repoPopup = repoPopup
        let controlsRow = NSStackView(views: [rootPopup, repoPopup])
        controlsRow.orientation = .horizontal
        controlsRow.spacing = 8
        controlsRow.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controlsRow)

        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = true
        tableScroll.backgroundColor = .windowBackgroundColor
        let tv = NSTableView(frame: NSRect(x: 0, y: 0, width: 610, height: 240))
        let hashCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hash"))
        hashCol.title = "版本"
        hashCol.width = 78
        hashCol.minWidth = 60
        let subjectCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("subject"))
        subjectCol.title = "提交信息"
        subjectCol.width = 330
        subjectCol.minWidth = 160
        subjectCol.resizingMask = .autoresizingMask
        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateCol.title = "时间"
        dateCol.width = 130
        dateCol.minWidth = 90
        tv.addTableColumn(hashCol)
        tv.addTableColumn(subjectCol)
        tv.addTableColumn(dateCol)
        tv.dataSource = self
        tv.delegate = self
        tv.usesAlternatingRowBackgroundColors = true
        tv.rowHeight = 24
        tv.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table = tv
        tableScroll.documentView = tv
        tv.sizeLastColumnToFit()
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(tableScroll)

        let filesHeader = NSTextField(labelWithString: "此提交包含的文件（点「恢复」回到该时点）")
        filesHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        filesHeader.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(filesHeader)
        let filesScroll = NSScrollView()
        filesScroll.hasVerticalScroller = true
        let ftv = NSTableView(frame: NSRect(x: 0, y: 0, width: 610, height: 110))
        let stCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        stCol.title = "变更"
        stCol.width = 52
        let fCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        fCol.title = "文件"
        fCol.width = 420
        fCol.resizingMask = .autoresizingMask
        let rCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("restore"))
        rCol.title = "操作"
        rCol.width = 110
        ftv.addTableColumn(stCol)
        ftv.addTableColumn(fCol)
        ftv.addTableColumn(rCol)
        ftv.dataSource = self
        ftv.delegate = self
        ftv.rowHeight = 26
        ftv.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        filesTable = ftv
        filesScroll.documentView = ftv
        ftv.sizeLastColumnToFit()
        filesScroll.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(filesScroll)

        let filesLabel = NSTextField(labelWithString: "选择一个提交，查看并恢复它包含的文件")
        filesLabel.font = FVDesign.captionFont
        filesLabel.textColor = .secondaryLabelColor
        filesLabel.lineBreakMode = .byTruncatingTail
        filesLabel.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(filesLabel)
        // v2.6.5: buildUI previously created only a LOCAL — the property stayed
        // nil, so every status message (正在恢复/已恢复/包含 N 个文件) was a no-op.
        self.filesLabel = filesLabel

        let rollback = NSButton(title: "回滚整个文件夹到此版本", target: self, action: #selector(rollbackAction))
        rollback.target = self
        rollback.bezelStyle = .rounded
        rollback.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(rollback)

        let m: CGFloat = 12
        let c1 = controlsRow.topAnchor.constraint(equalTo: host.topAnchor, constant: m)
        let c2 = controlsRow.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m)
        let c3 = controlsRow.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -m)
        let c4 = tableScroll.topAnchor.constraint(equalTo: controlsRow.bottomAnchor, constant: 10)
        let c5 = tableScroll.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m)
        let c6 = tableScroll.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -m)
        let c7 = tableScroll.bottomAnchor.constraint(equalTo: filesHeader.topAnchor, constant: -10)
        let c8 = tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        let c9 = filesHeader.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m)
        let c10 = filesHeader.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -m)
        let c11 = filesScroll.topAnchor.constraint(equalTo: filesHeader.bottomAnchor, constant: 6)
        let c12 = filesScroll.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m)
        let c13 = filesScroll.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -m)
        let c14 = filesScroll.heightAnchor.constraint(equalToConstant: 110)
        let c15 = filesLabel.topAnchor.constraint(equalTo: filesScroll.bottomAnchor, constant: 6)
        let c16 = filesLabel.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m)
        let c17 = filesLabel.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -m)
        let c18 = rollback.topAnchor.constraint(equalTo: filesLabel.bottomAnchor, constant: 8)
        let c19 = rollback.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m)
        let c20 = rollback.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -m)
        for c in [c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, c13, c14,
                  c15, c16, c17, c18, c19, c20] { c.isActive = true }
        window?.setContentSize(NSSize(width: 660, height: 560))
        reloadRepos()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        reloadRepos()
        subscribeStateListener()
    }

    func windowWillClose(_ n: Notification) {
        unsubscribeStateListener()
    }

    /// While open, background auto-commits/pushes refresh the lists too
    /// (v2.6.5). Rapid state flips coalesce through one debounced task.
    private func subscribeStateListener() {
        guard stateListenerToken == nil, let svc = service else { return }
        stateListenerToken = svc.addStateListener { [weak self] in
            Task { @MainActor in self?.handleExternalStateChange() }
        }
    }

    private func unsubscribeStateListener() {
        if let token = stateListenerToken { service?.removeStateListener(token) }
        stateListenerToken = nil
        pendingStateReload?.cancel()
        pendingStateReload = nil
    }

    @MainActor
    private func handleExternalStateChange() {
        guard window?.isVisible == true else { return }  // showWindow refreshes anyway
        pendingStateReload?.cancel()
        pendingStateReload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.reloadCommits(preserveSelection: true)
        }
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
        loadGeneration += 1  // invalidate stale async loads from the previous root
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

    /// Reload the commit list. `preserveSelection` keeps the currently selected
    /// commit across the reload (background auto-commits add rows on top); a
    /// fresh operation (restore/rollback) passes false to select the new HEAD.
    /// The changed-files list is refreshed EXPLICITLY: re-selecting the same
    /// row does not fire tableViewSelectionDidChange, which used to leave the
    /// file list stale after operations (v2.6.5).
    func reloadCommits(preserveSelection: Bool = false) {
        guard let svc = service, let repo = currentRepo() else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let selectedHash: String? = preserveSelection
            ? (table?.selectedRow).flatMap { commits.indices.contains($0) ? commits[$0].hash : nil }
            : nil
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
                    var targetRow = 0
                    if let selectedHash, let idx = list.firstIndex(where: { $0.hash == selectedHash }) {
                        targetRow = idx
                    }
                    self.table?.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
                    // Deterministic: the files list must follow the selection
                    // even when the selection index did not change.
                    self.loadChangedFiles()
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
