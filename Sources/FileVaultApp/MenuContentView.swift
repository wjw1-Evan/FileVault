import SwiftUI
import FileVaultCore

/// Short labels for the menu bar (v3.1.5, still used for accessibility text).
///
/// v4.0: a protected folder is itself the repository, so the label carries the
/// folder name and its sync status — there are no sub-repo rows to announce.
enum MenuLabels {
    /// Root label, e.g. "工作（已同步）".
    static func root(_ name: String, status: SyncStatus) -> String {
        String(format: NSLocalizedString("%@（%@）", comment: "menu root label"),
               name, FVStatusMeta.forSync(status).label)
    }

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
            secondaryActions
            panelDivider
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
            // Already-localized text from AppState: look up as a key, falls back
            // to the text itself.
            noticeText(LocalizedStringKey(notice))
        } else if app.lastUpdateCheckFailed {
            noticeText("更新检查失败，将在后台重试")
        }
    }

    private func noticeText(_ text: LocalizedStringKey) -> some View {
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
                Text("尚未添加文件夹")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("添加文件夹…") {
                    app.quickAddRequested = true
                    app.open("dashboard")
                }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(app.roots) { root in
                        RootMenuRow(root: root) { app.openPath(root.path) }
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
        // One row per protected folder (v4.0), plus the section's own padding.
        min(CGFloat(app.roots.count) * 30 + 16, 260)
    }

    // MARK: Actions

    private var primaryActions: some View {
        VStack(spacing: 0) {
            MenuActionRow(symbol: "clock.arrow.circlepath",
                          title: "历史与恢复…") { app.open("records") }
            MenuActionRow(symbol: "gearshape",
                          title: "设置…",
                          key: ",", modifiers: [.command],
                          hint: "⌘,") { app.open("settings") }
        }
        .padding(.vertical, 5)
    }

    /// Utility actions live at the bottom as compact rows, matching the rest
    /// of the panel instead of two oversized tiles (v4.2.24).
    private var secondaryActions: some View {
        VStack(spacing: 0) {
            MenuActionRow(symbol: "arrow.triangle.2.circlepath",
                          title: app.isUpdating ? "正在检查更新…" : "检查更新",
                          compact: true) {
                Task { await app.checkForUpdate(silent: false) }
            }
            .disabled(app.isUpdating)
            MenuActionRow(symbol: "info.circle",
                          title: "关于 FileVault",
                          hint: app.version.isEmpty ? nil : "v\(app.version)",
                          compact: true) { app.showAbout() }
        }
        .padding(.vertical, 2)
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

/// One protected folder: folder glyph, status dot, name, and a quiet status word.
struct RootMenuRow: View {
    let root: RootMenuEntry
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let meta = FVStatusMeta.forSync(root.status)
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.9))
                Text(root.name)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Circle()
                    .fill(meta.tint)
                    .frame(width: 6, height: 6)
                Text(meta.label)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(MenuLabels.root(root.name, status: root.status))
        .help("在 Finder 中打开 \(root.name)")
    }
}

/// Standard action row with optional keyboard shortcut + visible hint.
struct MenuActionRow: View {
    let symbol: String
    /// LocalizedStringKey (not String): a String parameter selects SwiftUI's
    /// verbatim Text initializer, so the rows stayed Chinese in English builds
    /// even though every key was translated (v4.2.25).
    let title: LocalizedStringKey
    var key: KeyEquivalent? = nil
    var modifiers: EventModifiers = [.command]
    var hint: String? = nil
    /// Secondary utility rows (检查更新 / 关于) are slightly smaller and dimmer
    /// so they do not compete with 历史与恢复 / 设置 (v4.2.24).
    var compact = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 10 : 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: compact ? 11 : 12))
                    .foregroundStyle(compact ? Color.secondary : Color.primary)
                Spacer(minLength: 6)
                if let hint {
                    Text(hint)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, compact ? 4.5 : 6)
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
