import SwiftUI
import AppKit
import FileVaultCore

/// v4.2.18: one dialog gets a folder protected — choose it, optionally paste a
/// remote URL (pre-filled when the folder already has an origin), done.
///
/// Before this, adding a folder took: open settings → 添加文件夹 → pick folder →
/// find the remote section → paste URL → save. Now it is one sheet with two
/// optional steps, and it can be opened straight from the menu bar.
struct QuickAddSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    var onAdded: (() -> Void)?

    @State private var folderPath = ""
    @State private var remoteURL = ""
    @State private var detectedRemote = false
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                FVIconBadge(symbol: "folder.badge.plus", size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("添加受保护文件夹")
                        .font(.system(size: 14, weight: .semibold))
                    Text("选一个文件夹，里面的所有文件都会自动保存版本。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(folderPath.isEmpty ? "尚未选择文件夹" : folderPath)
                    .font(.system(size: 11))
                    .foregroundStyle(folderPath.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("选择…") { chooseFolder() }
                    .controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

            VStack(alignment: .leading, spacing: 4) {
                Text("远程仓库地址（可选）")
                    .font(.system(size: 11, weight: .medium))
                TextField("https://github.com/用户名/仓库.git", text: $remoteURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .disabled(busy)
                Text(detectedRemote
                     ? "已检测到该文件夹已有的远程地址，将直接使用。"
                     : "现在不填也可以：之后在设置里随时能加，本地版本管理已经生效。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
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
                Button(busy ? "添加中…" : "添加") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(folderPath.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("选择文件夹", comment: "quick add panel")
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
            detectedRemote = false
            remoteURL = ""
            Task { @MainActor in
                guard let svc = app.service else { return }
                if let existing = await svc.repoManager.remoteURL(path: url.path) {
                    remoteURL = existing
                    detectedRemote = true
                }
            }
        }
    }

    private func add() {
        guard let svc = app.service else { return }
        busy = true
        errorText = nil
        Task { @MainActor in
            do {
                try await svc.addRoot(path: folderPath)
                let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    do {
                        try await svc.sync.configureRemote(repoPath: folderPath,
                                                           url: trimmed, autoPush: true)
                    } catch {
                        busy = false
                        await app.refresh()
                        errorText = NSLocalizedString("文件夹已添加，但远程绑定失败：", comment: "quick add")
                            + error.localizedDescription
                        return
                    }
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
