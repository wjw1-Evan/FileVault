import SwiftUI
import FileVaultCore

// MARK: - Create-repo dialog (v4.2.30 audit item 6)

/// The "在 GitHub 建仓并绑定" dialog.
///
/// A sheet — not a transient alert — so a failed create/bind can be shown
/// INSIDE it (v4.2.30 audit item 6c): the old alert closed itself and the
/// error landed in the card's small status line where users could not
/// connect it to what they had just clicked.
struct CreateRepoSheet: View {
    @Binding var name: String
    @Binding var errorText: String
    @Binding var busy: Bool
    let ghMissing: Bool
    let onCreate: () -> Void
    let onCancel: () -> Void

    /// Mirrors GhRepoCreator's naming rule so the button can grey out BEFORE
    /// the first create attempt fails (v4.2.30 audit item 6a).
    static func isValidRepoName(_ raw: String) -> Bool {
        let safe = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !safe.isEmpty && safe.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var nameHint: String? {
        if trimmed.isEmpty { return NSLocalizedString("请输入仓库名", comment: "gh repo dialog") }
        if !Self.isValidRepoName(name) {
            return NSLocalizedString("仓库名只能包含字母、数字、点、下划线和连字符", comment: "gh repo error")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                FVIconBadge(symbol: "cloud.badge.plus", tint: .green, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("在 GitHub 创建私有仓库并绑定")
                        .font(.system(size: 15, weight: .semibold))
                    Text("输入仓库名（将创建为当前 gh 账号下的私有仓库）：")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            TextField("my-notes", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(busy)
            if let hint = nameHint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            // Prechecked when the dialog opens (v4.2.30 audit item 6b): a
            // missing gh used to surface only after a doomed click.
            if ghMissing {
                VStack(alignment: .leading, spacing: 6) {
                    Text("需要先安装 GitHub CLI")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                    if let url = URL(string: "https://cli.github.com") {
                        Link("https://cli.github.com", destination: url)
                            .font(.system(size: 11))
                    }
                }
            }
            if !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                }
                Button("取消", action: onCancel)
                    .disabled(busy)
                Button("创建并绑定") { onCreate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || ghMissing || !Self.isValidRepoName(name))
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(FVTheme.canvas)
    }
}

// MARK: - FAQ (v4.2.30 audit item 10: support system, P1 gap)

/// One expandable question/answer pair.
struct FAQItem: Identifiable {
    let id = UUID()
    let question: String
    let answer: String
}

/// Eight answers for the most common support questions. Every answer names a
/// concrete next step, so the sheet doubles as first-line support.
enum FAQContent {
    /// Localised at construction: the Chinese keys live in the source (the
    /// default language), the en table carries the translations.
    static let items: [FAQItem] = [
        FAQItem(question: NSLocalizedString("误删或改坏了文件怎么找回？", comment: "faq"),
                answer: NSLocalizedString("打开菜单栏「历史与恢复…」→「文件恢复」标签，已删除的文件会自动列出，选中后一键找回。", comment: "faq")),
        FAQItem(question: NSLocalizedString("为什么没有「保存」按钮？", comment: "faq"),
                answer: NSLocalizedString("FileVault 的自动保存始终开启：文件改动约 5 秒后自动生成一个新版本，无需任何操作。", comment: "faq")),
        FAQItem(question: NSLocalizedString("提示「大文件未同步」是什么意思？", comment: "faq"),
                answer: NSLocalizedString("超过云端单文件上限（如 GitHub 100 MB）的文件不会上传云端，但本地版本一直保留；建议压缩或拆分后重新放入。", comment: "faq")),
        FAQItem(question: NSLocalizedString("iCloud / 云盘里的文件夹能用吗？", comment: "faq"),
                answer: NSLocalizedString("云盘「按需下载」会被误判为文件删除，建议用本地文件夹，或关闭该文件夹的按需下载。", comment: "faq")),
        FAQItem(question: NSLocalizedString("「暂停」期间会怎样？", comment: "faq"),
                answer: NSLocalizedString("暂停期间改动不生成版本；恢复后自动补一次提交，中间的改动不会丢。", comment: "faq")),
        FAQItem(question: NSLocalizedString("换新 Mac 怎么带走全部历史？", comment: "faq"),
                answer: NSLocalizedString("每个受保护文件夹就是标准 Git 仓库：迁移文件夹本身即可；绑定了远程的话，在新机器上添加同一文件夹并填入同一远程地址即可继续。", comment: "faq")),
        FAQItem(question: NSLocalizedString("远程认证方式怎么选？", comment: "faq"),
                answer: NSLocalizedString("装了 GitHub CLI 选「自动」最省事；有访问令牌选「令牌」；常用 SSH 密钥选「SSH」。凭证只存本机钥匙串。", comment: "faq")),
        FAQItem(question: NSLocalizedString("遇到问题怎么求助？", comment: "faq"),
                answer: NSLocalizedString("设置里导出诊断包（脱敏，不含文件内容），发到支持邮箱或在 GitHub 提 Issue。", comment: "faq")),
    ]
}

/// The settings FAQ sheet: 8 questions, each expands to a concrete next step.
struct FAQSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                FVIconBadge(symbol: "questionmark.circle.fill", tint: .blue, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("常见问题")
                        .font(.system(size: 15, weight: .semibold))
                    Text("点击问题展开答案")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .controlSize(.small)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(FAQContent.items) { item in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expanded.contains(item.id) },
                            set: { if $0 { expanded.insert(item.id) } else { expanded.remove(item.id) } })) {
                            Text(item.answer)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 4)
                        } label: {
                            Text(item.question)
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .background(FVTheme.canvas)
    }
}

// MARK: - Excluded large files (v4.2.30 audit item 4)

/// One excluded file with its on-disk size, preformatted for display.
struct LargeFileRow: Identifiable {
    let id = UUID()
    let name: String
    let size: String
}

/// Sheet payload: the repo's display name plus the excluded files.
struct LargeFilesState: Identifiable {
    let id = UUID()
    let repoName: String
    let rows: [LargeFileRow]
}

/// Lists the files auto-excluded for exceeding the remote's single-file limit
/// — they are NOT backed up, so the sheet says what to do about it.
struct LargeFilesSheet: View {
    let state: LargeFilesState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                FVIconBadge(symbol: "exclamationmark.triangle.fill", tint: .orange, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("大文件未备份")
                        .font(.system(size: 15, weight: .semibold))
                    Text(state.repoName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .controlSize(.small)
            }
            if state.rows.isEmpty {
                Text("现在没有超限的大文件了。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.rows) { row in
                            HStack(spacing: 12) {
                                Text(row.name)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(row.size)
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("这些文件超过远程单文件上限，不会生成版本、也不会同步到云端（文件本身不会被删除）。需要备份请压缩或拆分后重新放入，或移出受保护文件夹。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 520, height: 380)
        .background(FVTheme.canvas)
    }
}
