import SwiftUI
import FileVaultCore

/// Short labels for the menu bar (v3.1.5, still used for accessibility text).
enum MenuLabels {
    /// Root label, e.g. "工作（3）".
    static func root(_ name: String, repoCount: Int) -> String {
        "\(name)（\(repoCount)）"
    }

    /// Repo row label: the name only — status is conveyed by the dot.
    static func repo(_ name: String) -> String { name }

    /// Overflow submenu title.
    static let more = "更多"
}

/// Menu bar panel (v3.2): a designed popover instead of the system NSMenu.
///
/// Structure: status header, live update banner, protected repos, primary
/// actions, secondary tiles, automation toggle and quit. Every row is a plain
/// button with a hover wash so the panel reads like part of the app, not like a
/// stock menu.
struct MenuContentView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            statusBanner
            panelDivider
            rootsSection
            panelDivider
            primaryActions
            tilesRow
            panelDivider
            automationRow
            quitRow
        }
        .frame(width: 320)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            FVIconBadge(symbol: "clock.arrow.circlepath", size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("FileVault")
                    .font(.system(size: 12, weight: .semibold))
                Text(app.statusLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            MenuIconButton(symbol: "rectangle.on.rectangle", help: "打开主面板") {
                app.open("dashboard")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: Update / notice banner

    @ViewBuilder
    private var statusBanner: some View {
        if let activity = app.updateActivity {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.mini)
                Text(activity.menuText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        } else if let notice = app.updateNotice {
            noticeText(notice)
        } else if app.lastUpdateCheckFailed {
            noticeText("更新检查失败，将在后台重试")
        }
    }

    private func noticeText(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: Roots

    @ViewBuilder
    private var rootsSection: some View {
        if app.roots.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("尚未添加根目录")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("去设置添加…") { app.open("settings") }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(app.roots) { root in
                        rootHeader(root)
                        ForEach(root.repos) { repo in
                            RepoMenuRow(repo: repo) { app.openPath(repo.path) }
                        }
                        if root.id != app.roots.last?.id {
                            Rectangle()
                                .fill(FVTheme.hairline)
                                .frame(height: 1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            // Deterministic height: a bare ScrollView in a popover has no
            // intrinsic height and can collapse or balloon.
            .frame(height: rootsListHeight)
            // Soft fade instead of a hard cut through the last repo row.
            .mask(
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.9),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
        }
    }

    private var rootsListHeight: CGFloat {
        let rows = CGFloat(app.roots.reduce(0) { $0 + $1.repos.count + 1 })
        return min(rows * 26 + 12, 260)
    }

    private func rootHeader(_ root: RootMenuEntry) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange.opacity(0.9))
            Text(root.name)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
            Text("\(root.repos.count)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 4)
            Button {
                app.openPath(root.path)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("在 Finder 中打开")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(MenuLabels.root(root.name, repoCount: root.repos.count))
    }

    // MARK: Actions

    private var primaryActions: some View {
        VStack(spacing: 0) {
            MenuActionRow(symbol: "macwindow",
                          title: "打开主面板",
                          key: "d", modifiers: [.command, .shift],
                          hint: "⇧⌘D") { app.open("dashboard") }
            MenuActionRow(symbol: "clock.arrow.circlepath",
                          title: "历史版本…") { app.open("history") }
            MenuActionRow(symbol: "gearshape",
                          title: "设置…",
                          key: ",", modifiers: [.command],
                          hint: "⌘,") { app.open("settings") }
        }
        .padding(.vertical, 5)
    }

    private var tilesRow: some View {
        HStack(spacing: 7) {
            MenuTile(symbol: "arrow.up.doc", title: "立即提交") { app.commitAllNow() }
            MenuTile(symbol: "arrow.triangle.2.circlepath",
                     title: app.isUpdating ? "检查中…" : "检查更新") {
                Task { await app.checkForUpdate(silent: false) }
            }
            .disabled(app.isUpdating)
            MenuTile(symbol: "info.circle", title: "关于") { app.showAbout() }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var automationRow: some View {
        HStack(spacing: 9) {
            Image(systemName: app.paused ? "pause.circle.fill" : "bolt.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(app.paused ? Color.orange : Color.green)
                .frame(width: 16)
            Text(app.paused ? "自动提交已暂停" : "自动提交已开启")
                .font(.system(size: 12))
            Spacer()
            Toggle("", isOn: Binding(
                get: { !app.paused },
                set: { _ in app.toggleGlobalPause() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(app.paused ? "恢复自动提交" : "暂停自动提交")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var quitRow: some View {
        MenuActionRow(symbol: "power",
                      title: "退出 FileVault",
                      key: "q", modifiers: [.command],
                      hint: "⌘Q") { app.quit() }
            .padding(.bottom, 4)
    }

    private var panelDivider: some View {
        Rectangle()
            .fill(FVTheme.hairline)
            .frame(height: 1)
            .padding(.vertical, 2)
    }
}

// MARK: - Rows

/// One repo row: status dot, name, and a very quiet status word.
struct RepoMenuRow: View {
    let repo: RepoRow
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let meta = FVStatusMeta.forSync(repo.status)
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(meta.tint)
                    .frame(width: 6, height: 6)
                Text(repo.name)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Spacer(minLength: 4)
                // Only surface states that need attention; "仅本地" on every
                // row is noise when the whole vault is local.
                if repo.status != .noRemote {
                    Text(meta.label)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("在 Finder 中打开 \(repo.name)")
    }
}

/// Standard action row with optional keyboard shortcut + visible hint.
struct MenuActionRow: View {
    let symbol: String
    let title: String
    var key: KeyEquivalent? = nil
    var modifiers: EventModifiers = [.command]
    var hint: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 6)
                if let hint {
                    Text(hint)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(OptionalShortcut(key: key, modifiers: modifiers))
        .onHover { hovering = $0 }
    }
}

/// Compact secondary action tile.
struct MenuTile: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 9.5))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Small borderless icon button used in the panel header.
struct MenuIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0.0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Applies a shortcut only when one is provided.
struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?
    let modifiers: EventModifiers

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: modifiers)
        } else {
            content
        }
    }
}

#if DEBUG
/// Dev-only frame that renders the menu panel outside the menu bar so the
/// render-menu diagnostic can capture it as a PNG.
struct MenuPreviewView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ZStack {
            FVTheme.canvas.ignoresSafeArea()
            MenuContentView()
                .environmentObject(app)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(FVTheme.cardStroke, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)
        }
        .frame(minWidth: 380, minHeight: 620)
    }
}
#endif
