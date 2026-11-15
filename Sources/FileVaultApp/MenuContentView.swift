import SwiftUI
import FileVaultCore

/// The menu bar menu (status sections, protected directories, actions).
struct MenuContentView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(app.statusLine)
            .font(.caption)
            .foregroundStyle(.secondary)
        if app.lastUpdateCheckFailed {
            Text("上次检查更新失败——将自动重试，也可手动检查")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Divider()
        Section("受保护的目录") {
            if app.roots.isEmpty {
                Text("尚未添加根目录——点击「设置」开始")
            }
            ForEach(app.roots) { root in
                Menu {
                    Button("在 Finder 中打开根目录") { app.openPath(root.path) }
                    Divider()
                    ForEach(root.repos) { repo in
                        Button {
                            app.openPath(repo.path)
                        } label: {
                            Label("\(repo.name)  ·  \(repo.health.isEmpty ? repo.status.rawValue : repo.health)",
                                  systemImage: glyph(repo.status))
                        }
                    }
                } label: {
                    Label("\(root.name)（\(root.repos.count)）", systemImage: "folder")
                }
            }
        }
        Divider()
        Section("操作") {
            Toggle(pausedTitle, isOn: pauseBinding)
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("立即提交全部") { app.commitAllNow() }
            Button("打开主面板") { app.open("dashboard") }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("历史版本…") { app.open("history") }
            Button("设置…") { app.open("settings") }
                .keyboardShortcut(",", modifiers: [.command])
            Button("检查更新…") { Task { await app.checkForUpdate(silent: false) } }
            Button("关于 FileVault") { app.showAbout() }
            Button("退出 FileVault") { app.quit() }
                .keyboardShortcut("q", modifiers: [.command])
        }
    }

    private var pausedTitle: String { app.paused ? "恢复自动提交" : "暂停自动提交" }

    private var pauseBinding: Binding<Bool> {
        Binding(get: { app.paused }, set: { _ in app.toggleGlobalPause() })
    }

    private func glyph(_ status: SyncStatus) -> String {
        switch status {
        case .noRemote: return "circle.dashed"
        case .synced: return "checkmark.circle"
        case .pendingPush: return "arrow.up.circle"
        case .pushing: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        }
    }
}
