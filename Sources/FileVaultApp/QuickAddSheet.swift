import SwiftUI
import AppKit
import FileVaultCore

/// v4.2.18: one dialog gets a folder protected — choose it, optionally paste a
/// remote URL (pre-filled when the folder already has an origin), done.
///
/// Before this, adding a folder took: open settings → 添加文件夹 → pick folder →
/// find the remote section → paste URL → save. Now it is one sheet with two
/// optional steps, and it can be opened straight from the menu bar.
///
/// v4.2.30:
/// - Drag & drop: the sheet opens with the path pre-filled when a folder was
///   dropped on the menu panel or the dashboard roots card.
/// - The form speaks plain language (「云端备份」instead of 「远程仓库地址」)
///   and creates a private GitHub repo inline — previously the only one-click
///   creation lived in Settings → 更多, which the first-run user never saw.
/// - Git-not-ready is honest: a running download shows its progress, a
///   permanent failure shows its reason. "请稍后重试" for a dead end is gone.
struct QuickAddSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    /// Path pre-filled from a drag & drop (menu panel / dashboard, v4.2.30).
    var initialPath: String? = nil
    var onAdded: (() -> Void)?

    @State private var folderPath = ""
    @State private var remoteURL = ""
    @State private var detectedRemote = false
    @State private var busy = false
    @State private var errorText: String?
    // v4.2.30: inline one-click private GitHub repo creation.
    @State private var ghRepoName = ""
    @State private var ghBusy = false
    @State private var ghUnavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                FVIconBadge(symbol: "folder.badge.plus", size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("添加受保护文件夹")
                        .font(.system(size: 14, weight: .semibold))
                    Text("把文件夹拖进来，或点「选择…」；里面的所有文件都会自动保存版本。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                // v4.2.26 audit M12: a ternary whose branches are String makes
                // SwiftUI pick the verbatim Text initialiser, so the placeholder
                // bypassed the localisation table and stayed Chinese in English.
                Group {
                    if folderPath.isEmpty {
                        Text("尚未选择文件夹")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(folderPath)
                    }
                }
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("选择…") { chooseFolder() }
                    .controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

            VStack(alignment: .leading, spacing: 4) {
                Text("云端备份（可选）")
                    .font(.system(size: 11, weight: .medium))
                TextField("https://github.com/用户名/仓库名", text: $remoteURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .disabled(busy)
                Text(detectedRemote
                     ? "已检测到该文件夹已有的云端地址，将直接使用。"
                     : "留空 = 只保存在这台 Mac。绑定 GitHub 私有仓库后会自动上云、换电脑不丢；之后在设置里随时能加。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                // v4.2.30: users without a remote hit a wall here before — the
                // app already had one-click creation but never showed it in the
                // first form. Hidden once an address is present (typed or
                // detected): the wall only exists while the field is empty.
                if !detectedRemote,
                   remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 6) {
                        TextField("仓库名（默认用文件夹名）", text: $ghRepoName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .disabled(busy || ghBusy || ghUnavailable)
                        Button { createAndBindRepo() } label: {
                            if ghBusy { Text("创建中…") } else { Text("在 GitHub 创建并绑定") }
                        }
                        .controlSize(.small)
                            .disabled(busy || ghBusy || ghUnavailable
                                     || ghRepoName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if ghUnavailable {
                        Text("需要先安装 GitHub CLI（brew install gh 并登录），或把现成仓库地址粘贴到上面。")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if !app.envReady {
                // v4.2.30: the add button stays disabled until git exists; the
                // form explains WHY instead of failing on click.
                HStack(spacing: 6) {
                    if app.isPreparingGit {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 10))
                        Text(app.statusLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text(app.gitSetupError.flatMap { $0.isEmpty ? nil : $0 }
                             ?? NSLocalizedString("Git 环境尚未就绪。", comment: "quick add"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("查看详情") { app.open("dashboard") }
                            .controlSize(.small)
                            .buttonStyle(.link)
                    }
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .disabled(busy)
                Button { add() } label: {
                    if busy {
                        Text("添加中…")
                    } else if app.envReady {
                        Text("添加")
                    } else {
                        Text("Git 就绪后可添加")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folderPath.isEmpty || busy || !app.envReady)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            ghUnavailable = GhRepoCreator.defaultGhPath().isEmpty
            if folderPath.isEmpty, let path = initialPath {
                adoptFolder(at: path)
            }
        }
    }

    /// Adopt a folder path (from 选择… or a drag & drop): record it, then
    /// probe for an existing origin with the same stale-result guards as the
    /// v4.2.26 audit M8 fix.
    private func adoptFolder(at path: String) {
        folderPath = path
        detectedRemote = false
        remoteURL = ""
        if ghRepoName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ghRepoName = (path as NSString).lastPathComponent
        }
        Task { @MainActor in
            // Git setup can still be running (or have failed): never touch
            // the implicitly-unwrapped repoManager before it exists (v4.2.26).
            guard let svc = app.service, svc.isReady else { return }
            let existing = await svc.repoManager.remoteURL(path: path)
            // The probe is async: if the user picked another folder (or
            // typed another address) meanwhile, never let the stale result
            // overwrite the current choice (v4.2.26 audit M8).
            guard folderPath == path, remoteURL.isEmpty else { return }
            if let existing {
                remoteURL = existing
                detectedRemote = true
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("选择文件夹", comment: "quick add panel")
        if panel.runModal() == .OK, let url = panel.url {
            adoptFolder(at: url.path)
        }
    }

    /// v4.2.30: create a private GitHub repo with gh and continue straight
    /// into the add flow — one click, and failures stay in this sheet
    /// instead of landing in a distant one-line message elsewhere.
    private func createAndBindRepo() {
        guard !busy, !ghBusy else { return }
        let name = ghRepoName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        ghBusy = true
        errorText = nil
        Task { @MainActor in
            do {
                let url = try await GhRepoCreator().createPrivate(name: name)
                remoteURL = url
                ghBusy = false
                add()
            } catch {
                ghBusy = false
                errorText = error.localizedDescription
            }
        }
    }

    private func add() {
        // A double click can deliver two actions before SwiftUI repaints the
        // button as disabled; never run two add/configure passes (v4.2.26).
        guard !busy else { return }
        guard let svc = app.service, svc.isReady else {
            // v4.2.30: "请稍后重试" was a dead end when the failure is permanent
            // (mirror ladder exhausted → needs Xcode CLT). The status line
            // above already tracks preparation; show the concrete reason.
            errorText = app.gitSetupError.flatMap { $0.isEmpty ? nil : $0 }
                ?? NSLocalizedString("Git 环境尚未就绪。", comment: "quick add")
            return
        }
        busy = true
        errorText = nil
        Task { @MainActor in
            do {
                let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
                // v4.2.26: bind the remote in the same step as the first commit.
                // A brand-new repo then knows the remote's single-file ceiling
                // before its initial version is written, so an oversized file is
                // excluded instead of entering history forever. An already
                // existing remote still goes through configureRemote below to
                // fetch/merge.
                try await svc.addRoot(path: folderPath,
                                      remoteURL: trimmed.isEmpty ? nil : trimmed)
                if !trimmed.isEmpty {
                    do {
                        let change = try await svc.sync.configureRemote(repoPath: folderPath,
                                                                        url: trimmed, autoPush: true)
                        // setRemote reports a failed fetch through the result,
                        // not an error — surfacing it here keeps "看起来添加
                        // 成功但其实连不上" from surfacing only as a push
                        // failure notification minutes later (v4.2.28). The
                        // sheet STAYS OPEN so the address can be corrected,
                        // same as the bind-failure path below.
                        if !change.fetchSucceeded {
                            busy = false
                            await app.refresh()
                            onAdded?()
                            errorText = NSLocalizedString("文件夹已添加，但无法连接远程地址（当前按仅本地保存版本）。请检查地址与网络后重新点「添加」。",
                                                          comment: "quick add")
                            return
                        }
                    } catch {
                        busy = false
                        await app.refresh()
                        errorText = NSLocalizedString("文件夹已添加，但远程绑定失败：", comment: "quick add")
                            + error.localizedDescription
                        return
                    }
                } else if detectedRemote {
                    // The field was PRE-FILLED with the folder's own origin and
                    // the user emptied it: 「留空 = 仅本地」 must hold. Without
                    // this, attachRoot re-enables auto-push for the existing
                    // remote and the folder silently keeps syncing to the
                    // cloud (v4.2.28).
                    try await svc.sync.clearRemote(repoPath: folderPath)
                }
                await app.refresh()
                onAdded?()
                busy = false
                dismiss()
            } catch {
                busy = false
                errorText = error.localizedDescription
            }
        }
    }
}
