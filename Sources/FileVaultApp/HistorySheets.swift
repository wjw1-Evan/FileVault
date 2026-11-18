import SwiftUI
import FileVaultCore

/// v4.0.5 history sheets: one file's versions, two-commit comparison, and the
/// pre-rollback snapshots kept in refs/filevault/backup.

private func sheetStatusTint(_ status: String) -> Color {
    switch status {
    case "A": return .green
    case "D": return .red
    case "R": return .blue
    case "T": return .purple
    default: return .orange
    }
}

// MARK: - One file's timeline

struct FileHistorySheet: View {
    let service: HistoryService
    let recovery: RecoveryService?
    let repoPath: String
    let file: String
    let currentHash: String
    let onSelect: (String) -> Void
    let onRestored: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var commits: [CommitInfo] = []
    @State private var loading = true
    @State private var status: String?
    /// Versions that can actually be restored under the CURRENT path:
    /// pre-rename commits (--follow surfaces them) cannot (v4.2.27).
    @State private var restorable: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            FVHairline(leading: 0)
            content
            FVHairline(leading: 0)
            footer
        }
        .frame(width: 660, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("此文件的历史")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                Button("关闭") { dismiss() }
                    .controlSize(.small)
            }
            Text(file)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在载入…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if commits.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("此文件没有历史版本")
                    .font(.system(size: 12, weight: .medium))
                Text("它可能刚被加入文件夹，且还没有提交过这个文件。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(commits) { commit in
                        row(commit)
                    }
                }
                .padding(10)
            }
            // 老版本在改名前：恢复按钮点了才报错 → 提前禁用并说明（v4.2.27）。
            // v4.2.28: 条件反转修正——只有确实存在「不可按当前文件名恢复」的
            // 版本时才提示；未改名的文件此前也常驻这条提示，而全部版本都
            // 是改名前（恰恰最需要提示）时反而不显示。
            .overlay(alignment: .bottom) {
                if commits.contains(where: { !restorable.contains($0.hash) }) {
                    Text("改名前的版本不能按当前文件名恢复；请到「找回与还原」按当时的文件名找回。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
        }
    }

    private func row(_ commit: CommitInfo) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(commit.subject)
                    .font(.system(size: 12))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(commit.shortHash)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(FVTime.absolute(commit.date))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    if commit.hash == currentHash {
                        Text("当前版本")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                }
            }
            Spacer(minLength: 8)
            Button("查看") {
                onSelect(commit.hash)
                dismiss()
            }
            .controlSize(.small)
            .disabled(commit.hash == currentHash)
            Button("恢复") {
                restore(commit)
            }
            .controlSize(.small)
            // Pre-rename versions exist in history but not under the current
            // path: restore would answer "该版本里没有文件" — disable up front
            // (v4.2.27; empty set when recovery is unavailable = no marking).
            .disabled(recovery != nil && !restorable.contains(commit.hash))
            .help(recovery != nil && !restorable.contains(commit.hash)
                  ? NSLocalizedString("该版本里此文件是改名前的旧路径，无法按当前文件名恢复",
                                      comment: "file history")
                  : "")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(commit.hash == currentHash ? Color.accentColor.opacity(0.08) : Color.clear)
        )
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: status?.hasPrefix("⚠️") == true
                  ? "exclamationmark.triangle" : "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            Text(status ?? String(format: NSLocalizedString("共 %d 个版本", comment: "file history"),
                                  commits.count))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .help(status ?? "")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    @MainActor
    private func load() async {
        loading = true
        // A failed read is an error, not "没有历史版本" (v4.2.27).
        do {
            commits = try await service.fileHistory(repoPath: repoPath, file: file, limit: 200)
        } catch {
            commits = []
            status = String(format: NSLocalizedString("⚠️ 读取历史失败：%@", comment: "history status"),
                            error.localizedDescription)
            loading = false
            return
        }
        // Pre-rename versions: reuse RecoveryService.versions()' exists 语义.
        if let recovery {
            let versions = (try? await recovery.versions(repoPath: repoPath, file: file, limit: 200)) ?? []
            restorable = Set(versions.filter(\.exists).map(\.hash))
        }
        loading = false
    }

    private func restore(_ commit: CommitInfo) {
        status = String(format: NSLocalizedString("正在恢复 %@…", comment: "history status"), file)
        Task { @MainActor in
            do {
                _ = try await service.restoreFile(repoPath: repoPath, file: file, to: commit.hash)
                status = String(format: NSLocalizedString("✓ 已恢复 %@ 到 %@", comment: "history status"),
                                file, commit.shortHash)
                onRestored()
                await load()
            } catch {
                status = String(format: NSLocalizedString("⚠️ 恢复失败：%@", comment: "history status"),
                                error.localizedDescription)
            }
        }
    }
}

// MARK: - Compare two commits

struct CompareSheet: View {
    let service: HistoryService
    let repoPath: String
    let commits: [CommitInfo]

    @Environment(\.dismiss) private var dismiss
    @State private var fromHash: String
    @State private var toHash: String
    @State private var files: [ComparedFile] = []
    @State private var selectedPath: String?
    @State private var diff: FileDiff?
    @State private var loading = false
    @State private var diffLoading = false
    @State private var error: String?
    /// Per-file diff failure: shown in the RIGHT pane only — reusing `error`
    /// used to replace the whole file list (v4.2.27).
    @State private var diffError: String?
    @State private var generation = 0

    init(service: HistoryService, repoPath: String, commits: [CommitInfo],
         initialFrom: String?, initialTo: String?) {
        self.service = service
        self.repoPath = repoPath
        self.commits = commits
        let to = initialTo ?? commits.first?.hash ?? ""
        let from = initialFrom ?? commits.dropFirst().first?.hash ?? commits.last?.hash ?? to
        _fromHash = State(initialValue: from)
        _toHash = State(initialValue: to)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            FVHairline(leading: 0)
            content
            FVHairline(leading: 0)
            footer
        }
        .frame(width: 980, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: fromHash + "|" + toHash) {
            await loadCompare()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("对比两个版本")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 10)
            Picker("从", selection: $fromHash) {
                ForEach(commits) { commit in
                    Text(label(commit)).tag(commit.hash)
                }
            }
            .frame(width: 230)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Picker("到", selection: $toHash) {
                ForEach(commits) { commit in
                    Text(label(commit)).tag(commit.hash)
                }
            }
            .frame(width: 230)
            Button("关闭") { dismiss() }
                .controlSize(.small)
        }
        .padding(16)
    }

    private func label(_ commit: CommitInfo) -> String {
        commit.shortHash + " · " + commit.subject
    }

    @ViewBuilder
    private var content: some View {
        if fromHash == toHash {
            hint("请选择两个不同的版本", detail: "从较早的版本对比到较新的版本。")
        } else if loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在对比…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            hint("对比失败", detail: LocalizedStringKey(error))
        } else if files.isEmpty {
            hint("两个版本没有差异", detail: "这些版本之间的文件夹内容完全一致。")
        } else {
            HSplitView {
                fileList
                    .frame(minWidth: 300, idealWidth: 330, maxWidth: 420)
                diffPane
                    .frame(minWidth: 420, maxWidth: .infinity)
            }
        }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(files) { file in
                    HStack(spacing: 7) {
                        Text(file.statusCharacter)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(sheetStatusTint(file.statusCharacter))
                            .frame(width: 14)
                        Text(file.path)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(file.isBinary ? NSLocalizedString("二进制", comment: "diff stat")
                                           : "+" + String(file.added) + " −" + String(file.removed))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(file.path == selectedPath ? Color.accentColor.opacity(0.10) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { select(file.path) }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var diffPane: some View {
        if diffLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在载入…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diffError {
            hint("差异读取失败", detail: LocalizedStringKey(diffError))
        } else if let diff {
            if diff.isBinary {
                hint("二进制文件已更改",
                     detail: LocalizedStringKey(NSLocalizedString("无法显示逐行差异，请用默认应用打开查看。",
                                                                  comment: "diff")))
            } else if diff.isEmpty {
                hint("这个文件没有差异", detail: "选中的文件在两个版本之间没有变化。")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(selectedPath ?? "")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text("+\(diff.added) −\(diff.removed)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    ScrollView([.horizontal, .vertical]) {
                        DiffText(text: diff.text)
                            .padding(.vertical, 4)
                    }
                }
            }
        } else {
            hint("选择一个文件查看差异", detail: nil)
        }
    }

    private func hint(_ title: LocalizedStringKey, detail: LocalizedStringKey?) -> some View {
        VStack(spacing: 7) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // "共 0 个文件有差异" next to an error read as a successful empty
            // comparison; only claim a count when one was actually loaded
            // (v4.2.28).
            if error == nil, !loading {
                Text(String(format: NSLocalizedString("共 %d 个文件有差异", comment: "compare"), files.count))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(fromHash.prefix(7) + " → " + toHash.prefix(7))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    @MainActor
    private func loadCompare() async {
        generation += 1
        let current = generation
        diff = nil
        selectedPath = nil
        guard fromHash != toHash else {
            files = []
            error = nil
            loading = false
            return
        }
        loading = true
        error = nil
        do {
            let result = try await service.compare(repoPath: repoPath, from: fromHash, to: toHash)
            guard current == generation else { return }
            files = result
            loading = false
            if let first = result.first { select(first.path) }
        } catch {
            guard current == generation else { return }
            loading = false
            self.error = error.localizedDescription
        }
    }

    private func select(_ path: String) {
        selectedPath = path
        diff = nil
        diffError = nil
        diffLoading = true
        let from = fromHash
        let to = toHash
        let current = generation
        Task { @MainActor in
            do {
                let result = try await service.diff(repoPath: repoPath, from: from, to: to, file: path)
                guard current == generation, selectedPath == path else { return }
                diff = result
                diffLoading = false
            } catch {
                guard current == generation else { return }
                diffLoading = false
                self.diffError = error.localizedDescription
            }
        }
    }
}

// MARK: - Recover a pre-rollback snapshot

struct RecoverySheet: View {
    let service: HistoryService
    let repoPath: String
    let onRestored: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var backups: [BackupSnapshot] = []
    @State private var loading = true
    /// Reading the hidden refs can fail (folder gone, git error). That is NOT
    /// the same as "no backups yet" and used to be swallowed (v4.2.26).
    @State private var loadError: String?
    @State private var status: String?
    @State private var target: BackupSnapshot?
    @State private var confirming = false
    @State private var restoring = false

    var body: some View {
        VStack(spacing: 0) {
            header
            FVHairline(leading: 0)
            content
            FVHairline(leading: 0)
            footer
        }
        .frame(width: 700, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await load() }
        .alert("回滚到这个备份？", isPresented: $confirming, presenting: target) { backup in
            Button("恢复到此版本", role: .destructive) { restore(backup) }
            Button("取消", role: .cancel) {}
        } message: { backup in
            Text(String(format: NSLocalizedString("当前分支会回到 %@（%@）。恢复前的状态仍会再备份一次。",
                                                 comment: "recovery alert"),
                        backup.shortHash, backup.subject))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("找回被回滚的版本")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }
                    .controlSize(.small)
            }
            Text("每次回滚前，FileVault 都会把当时的状态备份到隐藏 ref（refs/filevault/backup）。这里可以把它恢复回来。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在载入…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(backupLoadErrorText(loadError))
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("重试") { Task { await load() } }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
        } else if backups.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("还没有可恢复的备份")
                    .font(.system(size: 12, weight: .medium))
                Text("执行过一次「回滚到该版本」之后，这里会出现回滚前的快照。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(backups) { backup in
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(backup.subject.isEmpty ? backup.stamp : backup.subject)
                                    .font(.system(size: 12))
                                    .lineLimit(2)
                                HStack(spacing: 8) {
                                    Text(backup.shortHash)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                    Text(backup.stamp)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                    if let date = backup.date {
                                        Text(FVTime.absolute(date))
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            Spacer(minLength: 8)
                            Button("恢复到此版本") {
                                target = backup
                                confirming = true
                            }
                            .controlSize(.small)
                            .disabled(restoring)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.03))
                        )
                    }
                }
                .padding(10)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: footerSymbol)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            Text(footerText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .help(footerText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var footerSymbol: String {
        if loadError != nil || status?.hasPrefix("⚠️") == true {
            return "exclamationmark.triangle"
        }
        return "info.circle"
    }

    private var footerText: String {
        if let loadError { return backupLoadErrorText(loadError) }
        return status ?? String(format: NSLocalizedString("共 %d 个备份", comment: "recovery"),
                                backups.count)
    }

    /// Shared wording so the error block and the footer never drift apart.
    private func backupLoadErrorText(_ reason: String) -> String {
        String(format: NSLocalizedString("无法读取备份：%@", comment: "recovery sheet"), reason)
    }

    @MainActor
    private func load() async {
        loading = true
        loadError = nil
        do {
            backups = try await service.backups(repoPath: repoPath)
        } catch {
            // Keep the reason visible and offer retry: a silent empty list
            // reads as "there is nothing to recover".
            backups = []
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func restore(_ backup: BackupSnapshot) {
        restoring = true
        status = NSLocalizedString("正在恢复…", comment: "history status")
        Task { @MainActor in
            do {
                try await service.resetRepo(repoPath: repoPath, to: backup.hash)
                status = String(format: NSLocalizedString("✓ 已恢复到 %@", comment: "history status"),
                                backup.shortHash)
                restoring = false
                onRestored()
                dismiss()
            } catch {
                restoring = false
                status = String(format: NSLocalizedString("⚠️ 恢复失败：%@", comment: "history status"),
                                error.localizedDescription)
            }
        }
    }
}
