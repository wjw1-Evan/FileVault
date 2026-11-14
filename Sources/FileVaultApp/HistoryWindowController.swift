import AppKit
import FileVaultCore

/// History window: repo picker + commit timeline + rollback (FR-09/10).
final class HistoryWindowController: NSWindowController {
    let service: FileVaultService?
    var repoPopup: NSPopUpButton?
    var table: NSTableView?
    var commits: [CommitInfo] = []

    init(service: FileVaultService?) {
        self.service = service
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
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
        let container = NSGridView(numberOfColumns: 1, rows: 0)
        container.rowSpacing = 8
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(repoChanged)
        self.repoPopup = popup
        container.addRow(with: [popup])
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 320))
        scroll.hasVerticalScroller = true
        let tv = NSTableView()
        let hashCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hash"))
        hashCol.title = "版本"
        hashCol.width = 90
        let subjectCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("subject"))
        subjectCol.title = "提交信息"
        subjectCol.width = 420
        tv.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tv.addTableColumn(hashCol)
        tv.addTableColumn(subjectCol)
        tv.dataSource = self
        tv.delegate = self
        tv.usesAlternatingRowBackgroundColors = true
        self.table = tv
        scroll.documentView = tv
        container.addRow(with: [scroll])
        let rollback = NSButton(title: "回滚到此版本", target: self, action: #selector(rollbackAction))
        rollback.target = self
        container.addRow(with: [rollback])
        window?.contentView = container
        reloadRepos()
    }

    // MARK: - Data loading

    var repoPaths: [String] = []

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
            repoPopup?.addItem(withTitle: (p as NSString).lastPathComponent)
        }
        guard !repoPaths.isEmpty else { return }
        repoPopup?.selectItem(at: 0)
        reloadCommits()
    }

    func currentRepo() -> String? {
        let idx = repoPopup?.indexOfSelectedItem ?? 0
        guard repoPaths.indices.contains(idx) else { return nil }
        return repoPaths[idx]
    }

    func reloadCommits() {
        guard let svc = service, let repo = currentRepo() else { return }
        Task {
            let list = (try? await svc.history.commits(repoPath: repo, limit: 100)) ?? []
            await MainActor.run {
                self.commits = list
                self.table?.reloadData()
            }
        }
    }

    // MARK: - Actions

    @objc func repoChanged() {
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
        let run_holder = alert.runModal()
        if run_holder == .alertFirstButtonReturn {
            Task {
                try? await svc.history.resetRepo(repoPath: repo, to: target.hash)
                await MainActor.run { self.reloadCommits() }
            }
        }
    }
}

extension HistoryWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        commits.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        let c = commits[row]
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: id == "hash" ? c.shortHash : c.subject)
        tf.lineBreakMode = .byTruncatingTail
        cell.textField = tf
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(greaterThanOrEqualTo: cell.leadingAnchor),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
