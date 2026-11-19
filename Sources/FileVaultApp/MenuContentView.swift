import SwiftUI
import CoreTransferable
import FileVaultCore

/// Short labels for the menu bar (v3.1.5, still used for accessibility text).
///
/// v4.0: a protected folder is itself the repository, so the label carries the
/// folder name and its sync status — there are no sub-repo rows to announce.
enum MenuLabels {
    /// Root label, e.g. "工作（已同步）".
    ///
    /// v4.2.26: paused folders and folders that cannot be attached right now
    /// are named explicitly instead of pretending to be "已同步".
    static func root(_ name: String, status: SyncStatus,
                     paused: Bool = false, unavailable: Bool = false) -> String {
        let label: String
        if unavailable {
            label = NSLocalizedString("不可用", comment: "menu root label")
        } else if paused {
            label = NSLocalizedString("已暂停", comment: "menu root label")
        } else {
            label = FVStatusMeta.forSync(status).label
        }
        return String(format: NSLocalizedString("%@（%@）", comment: "menu root label"), name, label)
    }

    /// Overflow submenu title.
    static let more = "更多"
}

/// Menu bar panel (v4.2.29 redesign): status header, then floating section
/// cards — protected folders, primary actions, and a quiet utility+quit group.
///
/// The v3.2 panel chopped sections apart with hairline dividers and closed on
/// a padded strip under the last row; both read as stray bars. The redesign
/// groups rows into inset cards on the panel canvas (the same surface language
/// as the windows' fvCard) so no decorative strips are needed anywhere, and
/// the frame padding is symmetric (12pt) so no edge shows a leftover band.
struct MenuContentView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var dropHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            statusBanner
            foldersCard
            actionsCard
            footerCard
        }
        .padding(12)
        .frame(width: 320)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            FVIconBadge(symbol: "clock.arrow.circlepath", size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pastward")
                    .font(.system(size: 13, weight: .semibold))
                Text(app.statusLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
        }
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
        } else if !app.envReady, let reason = app.gitSetupError, !reason.isEmpty {
            // The reason the automatic git setup failed belongs in the menu:
            // otherwise "Git 未就绪" is a dead end (v4.2.26).
            noticeText(LocalizedStringKey(reason))
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
    }

    // MARK: Folders card

    @ViewBuilder
    private var foldersCard: some View {
        Group {
        if app.roots.isEmpty {
            FVMenuCard {
                // v4.2.30: the empty card was a dead label next to a status
                // line claiming "0 个文件夹 · 正常" — it is now the action
                // itself, plus the drop target the hint promises.
                MenuActionRow(symbol: "plus.circle",
                              title: "添加第一个文件夹…") {
                    app.quickAddRequested = true
                    app.open("dashboard")
                }
                Text("或把文件夹拖到这里")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            FVMenuCard {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(app.roots) { root in
                            // An unavailable folder has nothing to open in
                            // Finder (NSWorkspace.open just fails silently) — route
                            // to Settings where 重新定位/移除 live (v4.2.27).
                            RootMenuRow(root: root) {
                                if root.unavailable {
                                    app.open("settings")
                                } else {
                                    app.openPath(root.path)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                // Deterministic height: a bare ScrollView in a popover has no
                // intrinsic height and can collapse or balloon.
                .frame(height: rootsListHeight)
                // Soft fade instead of a hard cut through the last folder row.
                .mask(
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.92),
                        .init(color: .clear, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                )
            }
        }
        }
        // v4.2.30: drag a folder onto the panel → the add sheet opens with
        // the path pre-filled. README's 「把文件夹拖进来」becomes literal.
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { hovering in
            dropHover = hovering
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dropHover ? Color.accentColor.opacity(0.7) : Color.clear,
                              lineWidth: 1.5)
                .padding(-3)
        )
    }

    /// A dropped folder pre-fills the quick-add sheet. Already-protected
    /// folders (and files, multi-selection) bounce back (v4.2.30; the rule
    /// set moved into the shared, tested QuickAddDrop in v4.2.31).
    private func handleDrop(_ urls: [URL]) -> Bool {
        guard let path = QuickAddDrop.folderPath(from: urls, isProtected: { candidate in
            app.roots.contains { $0.path == candidate }
        }) else { return false }
        app.quickAddPrefill = path
        app.quickAddRequested = true
        app.open("dashboard")
        return true
    }

    private var rootsListHeight: CGFloat {
        // One row per protected folder (v4.0): row ≈ 30pt (6pt insets × 2 +
        // 11.5pt text) + 2pt gaps + the card's own insets.
        min(CGFloat(app.roots.count) * 30 + 8, 232)
    }

    // MARK: Actions card

    private var actionsCard: some View {
        FVMenuCard {
            VStack(spacing: 2) {
                // v4.2.30: the dashboard was an icon-only header button
                // ("zero discoverability" — the code comment said so itself);
                // it is now a labelled row and the header keeps no duplicate.
                MenuActionRow(symbol: "rectangle.on.rectangle",
                              title: "主面板…",
                              key: "d", modifiers: [.command, .shift],
                              hint: "⇧⌘D") { app.open("dashboard") }
                // README promises 添加入口在「首启、菜单栏、主面板」三处 (v4.2.27
                // 设计轮) — the menu keeps a permanent add row.
                MenuActionRow(symbol: "plus.circle",
                              title: "添加文件夹…") {
                    app.quickAddRequested = true
                    app.open("dashboard")
                }
                MenuActionRow(symbol: "clock.arrow.circlepath",
                              title: "历史与恢复…") { app.open("records") }
                MenuActionRow(symbol: "gearshape",
                              title: "设置…",
                              key: ",", modifiers: [.command],
                              hint: "⌘,") { app.open("settings") }
            }
        }
    }

    // MARK: Utility + quit card

    /// Quiet bottom group (v4.2.24 hierarchy, kept by the redesign): utility
    /// rows are smaller and dimmer so they do not compete with the primary
    /// actions, and quit stays last with its shortcut visible.
    private var footerCard: some View {
        FVMenuCard {
            VStack(spacing: 2) {
                MenuActionRow(symbol: "arrow.triangle.2.circlepath",
                              title: app.isUpdating ? "正在检查更新…" : "检查更新",
                              compact: true) {
                    Task { await app.checkForUpdate(silent: false) }
                }
                .disabled(app.isUpdating)
                MenuActionRow(symbol: "info.circle",
                              title: "关于 Pastward",
                              hint: app.version.isEmpty ? nil : "v\(app.version)",
                              compact: true) { app.showAbout() }
                MenuActionRow(symbol: "power",
                              title: "退出 Pastward",
                              key: "q", modifiers: [.command],
                              hint: "⌘Q",
                              compact: true) { app.quit() }
            }
        }
    }
}

/// Inset group card (v4.2.29 menu redesign): a section floats as a rounded
/// card on the panel canvas instead of being chopped apart by hairline strips.
/// Same surface pairing as the windows' fvCard (FVTheme.card + hairline
/// stroke), scaled down for a 320pt popover.
private struct FVMenuCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(FVTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(FVTheme.cardStroke, lineWidth: 1)
            )
            // Edge rows' hover washes must not bleed past the card corners.
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        let label = root.unavailable
            ? NSLocalizedString("不可用", comment: "menu root label")
            : (root.paused ? NSLocalizedString("已暂停", comment: "menu root label") : meta.label)
        let tint: Color = root.unavailable
            ? Color.orange
            : (root.paused ? Color.secondary : meta.tint)
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
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(MenuLabels.root(root.name, status: root.status,
                                             paused: root.paused,
                                             unavailable: root.unavailable))
        // LocalizedStringKey (not String): a String argument selects the
        // verbatim overload and keeps the tooltip Chinese in English builds
        // (v4.2.26).
        // v4.2.28: unavailable rows navigate to Settings (where they can be
        // relocated or removed) — the tooltip must not promise Finder.
        .help(root.unavailable
              ? LocalizedStringKey("文件夹当前不可用；点击前往设置重新定位或移除")
              : LocalizedStringKey("在 Finder 中打开 \(root.name)"))
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
    /// Utility rows (检查更新 / 关于 / 退出) are slightly smaller and dimmer
    /// so they do not compete with the primary actions (v4.2.24).
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
            .padding(.horizontal, 8)
            .padding(.vertical, compact ? 5 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(OptionalShortcut(key: key, modifiers: modifiers))
        .onHover { hovering = $0 }
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
