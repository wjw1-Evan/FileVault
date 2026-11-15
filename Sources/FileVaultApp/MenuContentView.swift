import SwiftUI
import FileVaultCore

/// Short labels for the menu bar (v3.1.5).
///
/// The menu used to be a wall of text: a three-part status line, health strings
/// on every repo row, and eight action items. Rows now carry only what is
/// needed to pick something; details live in the dashboard/settings windows.
enum MenuLabels {
    /// Root submenu title, e.g. "工作（3）".
    static func root(_ name: String, repoCount: Int) -> String {
        "\(name)（\(repoCount)）"
    }

    /// Repo row label: the name only — status is conveyed by the glyph.
    static func repo(_ name: String) -> String { name }

    /// Overflow submenu title.
    static let more = "更多"
}

/// The menu bar menu: one status line, one submenu per protected root and the
/// handful of actions people actually use day to day.
struct MenuContentView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(app.statusLine)
            .font(.caption)
            .foregroundStyle(.secondary)
        if app.lastUpdateCheckFailed {
            Text("更新检查失败，将在后台重试")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Divider()
        if app.roots.isEmpty {
            Text("尚未添加根目录")
        }
        ForEach(app.roots) { root in
            Menu {
                Button("在 Finder 中打开") { app.openPath(root.path) }
                Divider()
                ForEach(root.repos) { repo in
                    Button {
                        app.openPath(repo.path)
                    } label: {
                        Label(MenuLabels.repo(repo.name), systemImage: glyph(repo.status))
                    }
                }
            } label: {
                Label(MenuLabels.root(root.name, repoCount: root.repos.count), systemImage: "folder")
            }
        }
        Divider()
        Button("打开主面板") { app.open("dashboard") }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        Button("历史版本…") { app.open("history") }
        Button("设置…") { app.open("settings") }
            .keyboardShortcut(",", modifiers: [.command])
        Divider()
        Toggle(pausedTitle, isOn: pauseBinding)
            .keyboardShortcut("p", modifiers: [.command, .shift])
        Menu(MenuLabels.more) {
            Button("立即提交全部") { app.commitAllNow() }
            Button("检查更新…") { Task { await app.checkForUpdate(silent: false) } }
            Button("关于 FileVault") { app.showAbout() }
        }
        Divider()
        Button("退出 FileVault") { app.quit() }
            .keyboardShortcut("q", modifiers: [.command])
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
