import AppKit
import FileVaultCore

/// History window (v1.2.4 redesign): repo switcher + commit table with time
/// column + per-commit changed-file list. Fixes the v1.2.x frame and switch bugs.
final class HistoryWindowController: NSWindowController, NSTableViewDelegate, NSTextFieldDelegate {
    let service: FileVaultService?
    var rootPopup: NSPopUpButton?
    var repoPopup: NSPopUpButton?
    var rootPaths: [String] = []
    var currentFolders: [SubRepo] = []
    var table: NSTableView?
    var filesTable: NSTableView?
    var filesLabel: NSTextField?
    var filesText: String? { filesLabel?.stringValue }
    var changedFiles: [(status: String, path: String)] = []
    /// Row the user picked for single-file restore (FR-10).
    var selectedChangedFile: String? {
        let idx = filesTable?.selectedRow ?? -1
        guard changedFiles.indices.contains(idx) else { return nil }
        return changedFiles[idx].path
    }
    var commits: [CommitInfo] = []
    enum HistMode { case commits, file }
    var mode: HistMode = .commits
    var trackedFiles: [String] = []
    var fileTimeline: [CommitInfo] = []
    var filePopup: NSPopUpButton?
    var fileRow: NSStackView?
    var filesScroll: NSScrollView?
    var modeSegment: NSSegmentedControl?
    var restoreFileBtn: NSButton?
    /// Guard: only the newest load may touch the table (stale-switch fix).
    private var loadGeneration = 0
    private var filesGeneration = 0

    init(service: FileVaultService?) {
        self.service = service
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "FileVault 历史"
        win.minSize = NSSize(width: 640, height: 500)
        super.init(window: win)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func buildUI() {
        // Proven single-scroll-page pattern (dashboard/settings): everything in
        // one document stack; the table gets a fixed height and the page scrolls.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 636, height: 560))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
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

        // Row 1: repo picker + view mode.
        let rootPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 190, height: 26), pullsDown: false)
        rootPopup.target = self
        rootPopup.action = #selector(rootChanged)
        rootPopup.identifier = NSUserInterfaceItemIdentifier("rootPicker")
        self.rootPopup = rootPopup
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 170, height: 26), pullsDown: false)
        popup.target = self
        popup.action = #selector(repoChanged)
        repoPopup = popup
        let segment = NSSegmentedControl(labels: ["全部提交", "单文件恢复"], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        segment.selectedSegment = 0
        modeSegment = segment
        let controlsRow = NSStackView(views: [rootPopup, popup, segment])
        controlsRow.orientation = .horizontal
        controlsRow.spacing = 8
        page.addArrangedSubview(controlsRow)

        // Row 2: file picker (file mode only; collapses when hidden).
        let filePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        filePopup.target = self
        filePopup.action = #selector(fileChanged)
        filePopup.isHidden = true
        self.filePopup = filePopup
        let fileRow = NSStackView(views: [filePopup])
        fileRow.orientation = .horizontal
        page.addArrangedSubview(fileRow)
        self.fileRow = fileRow

        // Row 3: commit/version table (fixed height; the page scrolls).
        let tableScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 612, height: 240))
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        let tv = NSTableView(frame: NSRect(x: 0, y: 0, width: 612, height: 240))
        let hashCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hash"))
        hashCol.title = "版本"
        hashCol.width = 80
        hashCol.minWidth = 60
        let subjectCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("subject"))
        subjectCol.title = "提交信息"
        subjectCol.width = 340
        subjectCol.minWidth = 200
        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateCol.title = "时间"
        dateCol.width = 140
        dateCol.minWidth = 100
        tv.addTableColumn(hashCol)
        tv.addTableColumn(subjectCol)
        tv.addTableColumn(dateCol)
        tv.dataSource = self
        tv.delegate = self
        tv.usesAlternatingRowBackgroundColors = true
        tv.allowsColumnReordering = false
        tv.rowHeight = 24
        table = tv
        tableScroll.documentView = tv
        tv.sizeLastColumnToFit()
        page.addArrangedSubview(tableScroll)
        tableScroll.widthAnchor.constraint(equalToConstant: 612).isActive = true
        tableScroll.heightAnchor.constraint(equalToConstant: 240).isActive = true

        // Row 4: changed files of the selected commit (commits mode only).
        let filesScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 612, height: 84))
        filesScroll.hasVerticalScroller = true
        let ftv = NSTableView(frame: NSRect(x: 0, y: 0, width: 612, height: 84))
        let stCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        stCol.title = "变更"
        stCol.width = 56
        let fCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        fCol.title = "文件（选中后可单文件恢复）"
        fCol.width = 536
        ftv.addTableColumn(stCol)
        ftv.addTableColumn(fCol)
        ftv.dataSource = self
        ftv.delegate = self
        ftv.rowHeight = 20
        filesTable = ftv
        filesScroll.documentView = ftv
        ftv.sizeLastColumnToFit()
        page.addArrangedSubview(filesScroll)
        filesScroll.widthAnchor.constraint(equalToConstant: 612).isActive = true
        filesScroll.heightAnchor.constraint(equalToConstant: 84).isActive = true
        self.filesScroll = filesScroll

        // Row 5: hint + actions.
        let filesLabel = NSTextField(labelWithString: "选择一个提交以查看其包含的文件变更")
        filesLabel.font = .systemFont(ofSize: 10.5)
        filesLabel.textColor = .secondaryLabelColor
        filesLabel.lineBreakMode = .byTruncatingTail
        filesLabel.widthAnchor.constraint(equalToConstant: 612).isActive = true
        filesLabel.translatesAutoresizingMaskIntoConstraints = false
        self.filesLabel = filesLabel
        page.addArrangedSubview(filesLabel)
        let restoreBtn = NSButton(title: "恢复选中文件", target: self, action: #selector(restoreFileAction))
        restoreBtn.target = self
        restoreBtn.bezelStyle = .rounded
        let restoreVersionBtn = NSButton(title: "恢复此文件", target: self, action: #selector(restoreFileToVersion))
        restoreVersionBtn.target = self
        restoreVersionBtn.bezelStyle = .rounded
        restoreVersionBtn.isHidden = true
        restoreFileBtn = restoreVersionBtn
        let rollback = NSButton(title: "回滚到此版本", target: self, action: #selector(rollbackAction))
        rollback.target = self
        rollback.bezelStyle = .rounded
        let actionsRow = NSStackView(views: [restoreBtn, restoreVersionBtn, rollback])
        actionsRow.orientation = .horizontal
        actionsRow.spacing = 8
        page.addArrangedSubview(actionsRow)

        // Window sizing: explicit content size (Auto Layout would otherwise
        // collapse the window to the zero-frame table fitting size).
        window?.setContentSize(NSSize(width: 636, height: 560))
        reloadRepos()
    }

    /// Called every time the window is shown: refresh repo list (roots may have changed).
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        reloadRepos()
    }

    // MARK: - Data

    func reloadRepos() {
        guard let svc = service else { return }
        rootPaths = svc.rootsSnapshot()
        rootPopup?.removeAllItems()
        for root in rootPaths {
            rootPopup?.addItem(withTitle: "📁 " + (root as NSString).lastPathComponent)
        }
        guard !rootPaths.isEmpty else {
            currentFolders = []
            commits = []
            table?.reloadData()
            filesLabel?.stringValue = "尚未添加任何根目录——先在设置中添加根目录"
            return
        }
        rootPopup?.selectItem(at: 0)
        populateRepoPopup()
    }

    /// Level 2: folders of the selected root.
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
            fileTimeline = []
            table?.reloadData()
            filesLabel?.stringValue = "该根目录暂无子文件夹"
            return
        }
        repoPopup?.selectItem(at: 0)
        loadForCurrentSelection()
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

    /// Load commits + tracked files for the current selection. The async
    /// completion RESTORES the user's selection (a stale rebuild must not
    /// reset the popup — v2.4.2 race fix).
    func loadForCurrentSelection() {
        guard let svc = service, let repo = currentRepo() else { return }
        Task {
            let files = await svc.repoManager.listFiles(path: repo)
            await MainActor.run {
                guard self.currentRepo() == repo else { return }  // user moved on
                self.trackedFiles = files
                self.rebuildFilePopup(selecting: repo)
                if self.mode == .file { self.reloadFileTimeline() } else { self.reloadCommits() }
            }
        }
    }

    /// Level 1 changed: refresh the root list if it went stale (roots added /
    /// removed in settings while this window was open), then repopulate folders.
    @objc func rootChanged() {
        let fresh = service?.rootsSnapshot() ?? []
        if rootPopup?.numberOfItems != fresh.count {
            reloadRepos()
            return
        }
        populateRepoPopup()
    }

    /// Populate the file picker for the current repo.
    func rebuildFilePopup(selecting keep: String? = nil) {
        filePopup?.removeAllItems()
        for f in trackedFiles {
            filePopup?.addItem(withTitle: f)
        }
        guard !trackedFiles.isEmpty else { return }
        if let keep, let idx = trackedFiles.firstIndex(of: keep) {
            filePopup?.selectItem(at: idx)
        } else {
            filePopup?.selectItem(at: 0)
        }
    }

    /// v2.2.0 mode switch: all commits vs single-file timeline.
    @objc func modeChanged(_ sender: NSSegmentedControl) {
        mode = sender.selectedSegment == 1 ? .file : .commits
        filePopup?.isHidden = mode == .commits
        fileRow?.isHidden = mode == .commits
        restoreFileBtn?.isHidden = mode == .commits
        table?.deselectAll(nil)
        if mode == .file {
            reloadFileTimeline()
        } else {
            reloadCommits()
        }
    }

    /// File picker changed: reload that file's timeline.
    @objc func fileChanged() {
        table?.deselectAll(nil)
        reloadFileTimeline()
    }

    /// Version timeline of the selected file.
    func reloadFileTimeline() {
        guard let svc = service, let repo = currentRepo(),
              let file = filePopup?.selectedItem?.title, !file.isEmpty else { return }
        loadGeneration += 1
        let generation = loadGeneration
        Task {
            let list = (try? await svc.history.fileHistory(repoPath: repo, file: file, limit: 100)) ?? []
            guard generation == self.loadGeneration else { return }
            await MainActor.run {
                guard generation == self.loadGeneration else { return }
                self.fileTimeline = list
                self.table?.reloadData()
                if list.isEmpty {
                    self.filesLabel?.stringValue = "该文件还没有版本历史"
                } else {
                    self.filesLabel?.stringValue = "「" + file + "」的版本时间线（" + String(list.count) + " 个版本），选中后点「恢复此文件」"
                }
            }
        }
    }

    /// Restore the selected file to the selected timeline version.
    @objc func restoreFileToVersion() {
        guard let svc = service, let repo = currentRepo(),
              let file = filePopup?.selectedItem?.title, !file.isEmpty else { return }
        let row = table?.selectedRow ?? -1
        guard row >= 0, row < fileTimeline.count else { return }
        let target = fileTimeline[row]
        let alert = NSAlert()
        alert.messageText = "恢复文件到历史版本"
        alert.informativeText = "把「" + file + "」恢复到 " + target.shortHash + "（" + target.subject + "）？恢复会形成一次新的提交。"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        if FVDesign.activateAndRunModal(alert) == .alertFirstButtonReturn {
            filesLabel?.stringValue = "正在恢复…"
            Task {
                do {
                    _ = try await svc.history.restoreFile(repoPath: repo, file: file, to: target.hash)
                    await MainActor.run {
                        filesLabel?.stringValue = "✓ 已将 " + file + " 恢复到 " + target.shortHash + "（已自动提交）"
                        self.reloadFileTimeline()
                    }
                } catch {
                    await MainActor.run {
                        filesLabel?.stringValue = "⚠️ 恢复失败: " + error.localizedDescription
                    }
                }
            }
        }
    }

    func reloadCommits() {
        guard let svc = service, let repo = currentRepo() else { return }
        print("[HC] reloadCommits repo=" + repo)
        loadGeneration += 1
        let generation = loadGeneration
        filesLabel?.stringValue = "正在加载提交历史…"
        Task {
            let list = (try? await svc.history.commits(repoPath: repo, limit: 100)) ?? []
            // Stale-switch guard: drop results that are no longer current.
            guard generation == self.loadGeneration else { return }
            await MainActor.run {
                print("[HC] apply gen=" + String(generation) + " latest=" + String(self.loadGeneration) + " repo=" + repo + " count=" + String(list.count))
                guard generation == self.loadGeneration else { return }
                self.commits = list
                self.table?.reloadData()
                if list.isEmpty {
                    self.filesLabel?.stringValue = "该文件夹还没有提交历史"
                } else if self.table?.selectedRow == -1 || self.table?.selectedRow == nil {
                    self.table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                } else {
                    self.loadChangedFiles()
                }
            }
        }
    }

    /// Load + display the changed files of the selected commit.
    func loadChangedFiles() {
        guard let svc = service, let repo = currentRepo() else { return }
        let row = table?.selectedRow ?? -1
        guard row >= 0, row < commits.count else {
            filesLabel?.stringValue = "选择一个提交以查看其包含的文件变更"
            return
        }
        let hash = commits[row].hash
        let subject = commits[row].subject
        filesGeneration += 1
        let generation = filesGeneration
        Task {
            let lines = (try? await svc.history.changedFiles(repoPath: repo, hash: hash)) ?? []
            guard generation == self.filesGeneration else { return }
            await MainActor.run {
                guard generation == self.filesGeneration else { return }
                self.changedFiles = lines.map { line -> (String, String) in
                    let parts = line.split(separator: "\t", maxSplits: 1)
                    return (parts.count > 1 ? String(parts[0]) : "?", parts.count > 1 ? String(parts[1]) : line)
                }
                self.filesTable?.reloadData()
                if self.changedFiles.isEmpty {
                    self.filesLabel?.stringValue = "「" + subject + "」没有文件变更"
                } else {
                    self.filesLabel?.stringValue = "「" + subject + "」包含 " + String(self.changedFiles.count) + " 个文件，选中后可单文件恢复"
                }
            }
        }
    }

    // MARK: - Actions

    @objc func repoChanged() {
        print("[HC] repoChanged sel=" + String(repoPopup?.indexOfSelectedItem ?? -1))
        table?.deselectAll(nil)
        reloadCommits()
    }

    /// FR-10 single-file restore from the selected commit.
    @objc func restoreFileAction() {
        guard let svc = service, let repo = currentRepo(),
              let file = selectedChangedFile else { return }
        let row = table?.selectedRow ?? -1
        guard row >= 0, row < commits.count else { return }
        let target = commits[row]
        let alert = NSAlert()
        alert.messageText = "单文件恢复"
        alert.informativeText = "把「" + file + "」恢复到 " + target.shortHash + "（" + target.subject + "）？恢复会形成一次新的回滚提交。"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        if FVDesign.activateAndRunModal(alert) == .alertFirstButtonReturn {
            filesLabel?.stringValue = "正在恢复 " + file + "…"
            Task {
                do {
                    _ = try await svc.history.restoreFile(repoPath: repo, file: file, to: target.hash)
                    await MainActor.run {
                        filesLabel?.stringValue = "✓ 已恢复 " + file + " 到 " + target.shortHash + "（已自动提交）"
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
        guard row >= 0, row < commits.count else { return }
        let target = commits[row]
        let alert = NSAlert()
        alert.messageText = "回滚确认"
        alert.informativeText = "把「\((repo as NSString).lastPathComponent)」整个回滚到 \(target.shortHash)（\(target.subject)）？此操作会丢弃之后的提交。"
        alert.addButton(withTitle: "回滚")
        alert.addButton(withTitle: "取消")
        let modalResult = FVDesign.activateAndRunModal(alert)
        if modalResult == .alertFirstButtonReturn {
            Task {
                try? await svc.history.resetRepo(repoPath: repo, to: target.hash)
                await MainActor.run { self.reloadCommits() }
            }
        }
    }
}

extension HistoryWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === filesTable { return changedFiles.count }
        return mode == .file ? fileTimeline.count : commits.count
    }
}

extension HistoryWindowController /* delegate methods */ {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        if tableView === filesTable {
            let entry = changedFiles[row]
            let text = id == "status" ? entry.status : entry.path
            let cell = NSTableCellView()
            let tf = NSTextField(labelWithString: text)
            tf.font = .systemFont(ofSize: 11)
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        if mode == .file {
            let c = fileTimeline[row]
            let text: String = id == "hash" ? c.shortHash : (id == "date" ? Self.dateText(c.date) : c.subject)
            return Self.makeCell(text)
        }
        let c = commits[row]
        let text: String
        switch id {
        case "hash": text = c.shortHash
        case "date": text = Self.dateText(c.date)
        default: text = c.subject
        }
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: text)
        tf.font = .systemFont(ofSize: 12)
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if mode == .file { return }  // file mode: panel shows timeline hint instead
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
