import AppKit
import FileVaultCore

/// History window (v1.2.4 redesign): repo switcher + commit table with time
/// column + per-commit changed-file list. Fixes the v1.2.x frame and switch bugs.
final class HistoryWindowController: NSWindowController, NSTableViewDelegate, NSTextFieldDelegate {
    let service: FileVaultService?
    var repoPopup: NSPopUpButton?
    var table: NSTableView?
    var filesLabel: NSTextField?
    var filesText: String? { filesLabel?.stringValue }
    var commits: [CommitInfo] = []
    var repoPaths: [String] = []
    /// Guard: only the newest load may touch the table (stale-switch fix).
    private var loadGeneration = 0
    private var filesGeneration = 0

    init(service: FileVaultService?) {
        self.service = service
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        win.title = "FileVault 历史"
        super.init(window: win)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func buildUI() {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        popup.target = self
        popup.action = #selector(repoChanged)
        repoPopup = popup

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 636, height: 260))
        scroll.hasVerticalScroller = true
        let tv = NSTableView(frame: NSRect(x: 0, y: 0, width: 636, height: 260))
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
        scroll.documentView = tv
        tv.sizeLastColumnToFit()

        let filesLabel = NSTextField(wrappingLabelWithString: "选择一个提交以查看其包含的文件变更")
        filesLabel.font = .systemFont(ofSize: 11)
        filesLabel.textColor = .secondaryLabelColor
        filesLabel.frame = NSRect(x: 0, y: 0, width: 636, height: 60)
        self.filesLabel = filesLabel
        let filesScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 636, height: 70))
        filesScroll.hasVerticalScroller = true
        filesScroll.documentView = filesLabel
        filesLabel.autoresizingMask = [.width]
        filesLabel.isEditable = false

        let rollback = NSButton(title: "回滚到此版本", target: self, action: #selector(rollbackAction))
        rollback.target = self
        rollback.bezelStyle = .rounded

        // Layout: popup / table / files panel / rollback in a fixed column.
        let host = NSView()
        window?.contentView = host
        popup.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        filesScroll.translatesAutoresizingMaskIntoConstraints = false
        rollback.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(popup)
        host.addSubview(scroll)
        host.addSubview(filesScroll)
        host.addSubview(rollback)
        let m: CGFloat = 12
        NSLayoutConstraint.activate([
            popup.topAnchor.constraint(equalTo: host.topAnchor, constant: m),
            popup.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            scroll.topAnchor.constraint(equalTo: popup.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -m),
            scroll.heightAnchor.constraint(equalToConstant: 240),
            filesScroll.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            filesScroll.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m),
            filesScroll.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -m),
            filesScroll.heightAnchor.constraint(equalToConstant: 78),
            rollback.topAnchor.constraint(equalTo: filesScroll.bottomAnchor, constant: 10),
            rollback.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m),
            rollback.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -m),
        ])
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
        repoPaths = []
        for root in svc.rootsSnapshot() {
            for r in svc.repoManager.firstLevelFolders(root: root) {
                repoPaths.append(r.path)
            }
        }
        repoPopup?.removeAllItems()
        for p in repoPaths {
            repoPopup?.addItem(withTitle: "📁 " + (p as NSString).lastPathComponent)
        }
        guard !repoPaths.isEmpty else {
            commits = []
            table?.reloadData()
            filesLabel?.stringValue = "尚未添加任何根目录"
            return
        }
        repoPopup?.selectItem(at: 0)
        reloadCommits()
    }

    func currentRepo() -> String? {
        let idx = repoPopup?.indexOfSelectedItem ?? -1
        guard repoPaths.indices.contains(idx) else { return nil }
        return repoPaths[idx]
    }

    func reloadCommits() {
        guard let svc = service, let repo = currentRepo() else { return }
        loadGeneration += 1
        let generation = loadGeneration
        filesLabel?.stringValue = "正在加载提交历史…"
        Task {
            let list = (try? await svc.history.commits(repoPath: repo, limit: 100)) ?? []
            // Stale-switch guard: drop results that are no longer current.
            guard generation == self.loadGeneration else { return }
            await MainActor.run {
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
            let files = (try? await svc.history.changedFiles(repoPath: repo, hash: hash)) ?? []
            guard generation == self.filesGeneration else { return }
            await MainActor.run {
                guard generation == self.filesGeneration else { return }
                if files.isEmpty {
                    self.filesLabel?.stringValue = "「\(subject)」没有文件变更"
                } else {
                    self.filesLabel?.stringValue = "「\(subject)」包含 \(files.count) 个文件：\\n" + files.joined(separator: "\\n")
                }
            }
        }
    }

    // MARK: - Actions

    @objc func repoChanged() {
        table?.deselectAll(nil)
        reloadCommits()
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
        let modalResult = alert.runModal()
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
        commits.count
    }
}

extension HistoryWindowController /* delegate methods */ {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        let c = commits[row]
        let text: String
        switch id {
        case "hash": text = c.shortHash
        case "date":
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm:ss"
            text = f.string(from: c.date)
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
        loadChangedFiles()
    }
}
