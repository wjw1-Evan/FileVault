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

/// Menu bar panel: status header, protected folders, primary actions, and a
/// quiet utility+quit group.
///
/// v4.2.29 replaced the v3.2 hairline-divider strips (which read as stray bars)
/// with inset cards, so no decorative chrome was needed anywhere.
///
/// v4.2.33 removes the last of that chrome — the card plates themselves. The
/// popover draws the system's vibrant menu material; an opaque FVTheme.card
/// fill (pure white in light mode) on top of it was the 「白色背景」 users saw,
/// and it made the panel read as three boxes instead of a menu. Sections are
/// now separated by spacing only and the panel is one continuous surface,
/// matching current macOS menus; frame padding stays symmetric (12pt) so no
/// edge shows a leftover band.
struct MenuContentView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var dropHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: FVTheme.Menu.groupSpacing) {
            header
            statusBanner
            foldersCard
            actionsCard
            footerCard
        }
        .padding(.horizontal, FVTheme.Menu.inset)
        .padding(.vertical, FVTheme.Menu.panelPadding)
        .frame(width: 320)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: FVTheme.Menu.iconGap) {
            // v4.2.33: flat accent glyph instead of `FVIconBadge`.
            //
            // The badge's iOS-style gradient (0.95 → 0.62) plus a coloured
            // shadow is the most saturated thing in the panel and does not
            // exist in macOS's menu language — menu-bar panels tint a single
            // accent surface or use a template glyph. The menu therefore draws
            // the mark flat on the same accent the system uses for selection;
            // the windows keep the gradient badge for the larger, branded
            // surfaces (「配色要与系统相符」).
            FVMenuHeaderGlyph(symbol: "clock.arrow.circlepath")
            VStack(alignment: .leading, spacing: 1) {
                // System text styles, not hand-picked sizes: .headline is 13pt
                // semibold and .caption 10pt on macOS — exactly the menu body
                // size, and they keep tracking Dynamic Type / accessibility
                // scaling (v4.2.34).
                Text("Pastward")
                    .font(.headline)
                Text(app.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: FVTheme.Menu.groupSpacing)
        }
    }

    // MARK: Update / notice banner

    @ViewBuilder
    private var statusBanner: some View {
        if let activity = app.updateActivity {
            HStack(spacing: FVTheme.Menu.iconGap) {
                ProgressView()
                    .controlSize(.mini)
                Text(activity.menuText)
                    .font(.caption)
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
        HStack(spacing: FVTheme.Menu.iconGap) {
            Image(systemName: "arrow.down.circle")
                .font(.caption2)
            Text(text)
                .font(.caption)
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
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, FVTheme.Menu.inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            FVMenuCard {
                ScrollView {
                    VStack(spacing: 0) {
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
        // Derived from the measured system row height instead of the old
        // hand-tuned "≈30pt row + 8pt" estimate (v4.2.34): the ScrollView must
        // have a deterministic height in a popover, but that height should
        // still be an exact multiple of the row rhythm the rows actually use.
        min(CGFloat(app.roots.count) * FVTheme.Menu.rowHeight, FVTheme.Menu.rowHeight * 8)
    }

    // MARK: Actions card

    private var actionsCard: some View {
        FVMenuCard {
            VStack(spacing: 0) {
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
            VStack(spacing: 0) {
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

/// Section group (v4.2.29 menu redesign, re-surfaced in v4.2.33).
///
/// The v4.2.29 pass floated each section as an opaque card so the panel would
/// have the same card language as the windows. Inside the menu-bar popover that
/// backfired: the popover already draws the system's vibrant menu material, so
/// `FVTheme.card` (pure white in light mode) painted three white slabs on top
/// of it — the menu looked like boxes glued onto the system surface instead of
/// a macOS menu.
///
/// v4.2.33 therefore drops the plate (and its hairline) entirely: the panel is
/// ONE continuous menu surface, sections are separated by spacing alone, and the
/// only painted chrome is the per-row hover pill — the grouping the redesign
/// wanted without any background of our own.
private struct FVMenuCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        // No padding of our own: the panel's inset and the group spacing already
        // give every section the system's rhythm (v4.2.34). Extra padding here
        // was one of the hand-tuned values that made the menu drift from the
        // system's own metrics.
        content
    }
}

/// Flat menu-bar header mark (v4.2.33).
///
/// A menu-bar panel is a system surface: its chrome should come from the system
/// palette (accent colour, label colours), not from an app-specific gradient
/// with a coloured shadow. This renders the same SF Symbol as the windows'
/// `FVIconBadge` but flat, on the user's accent colour, so the panel reads as
/// part of macOS instead of a small iOS card (「配色要与系统相符」).
private struct FVMenuHeaderGlyph: View {
    let symbol: String

    var body: some View {
        // Sized from the system row rhythm (24pt) rather than a standalone
        // hand-picked size, and drawn with the system's own icon font so it
        // scales with the text next to it (v4.2.34).
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.accentColor)
            .overlay(
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(.white)
            )
            .frame(width: FVTheme.Menu.rowHeight, height: FVTheme.Menu.rowHeight)
            .accessibilityHidden(true)
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
            HStack(spacing: FVTheme.Menu.iconGap) {
                // Template glyph, not a hand-picked tint: system menus draw
                // their leading glyphs through the label hierarchy so the
                // panel follows the user's appearance — an orange folder was
                // the one colour in the menu that came from nowhere in the
                // system palette (v4.2.33, 「配色要与系统相符」).
                Image(systemName: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(root.name)
                    .font(FVTheme.Menu.rowFont)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, FVTheme.Menu.inset / 2)
            .frame(height: FVTheme.Menu.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // Square corners: the system's menu highlight is a full-width
                // rectangle, not a rounded pill (v4.2.34).
                Rectangle()
                    .fill(hovering ? FVTheme.menuRowHover : Color.clear)
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
            HStack(spacing: FVTheme.Menu.iconGap) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                // One size for every row: macOS menus don't shrink their utility
                // items, they just dim them (v4.2.34 — the old compact ladder
                // drew 检查更新/关于/退出 at 11pt against 12pt rows).
                Text(title)
                    .font(FVTheme.Menu.rowFont)
                    .foregroundStyle(compact ? Color.secondary : Color.primary)
                Spacer(minLength: 6)
                if let hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, FVTheme.Menu.inset / 2)
            .frame(height: FVTheme.Menu.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // Full-width square highlight, exactly like the system menu's
                // own selection (v4.2.34).
                Rectangle()
                    .fill(hovering ? FVTheme.menuRowHover : Color.clear)
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
///
/// v4.2.33: the panel no longer paints any surface of its own (see the group
/// comment above), so this window-background stand-in is a fair approximation
/// of the popover material for layout checks — there is no card fill left that
/// it could hide. It is NOT a colour-accurate frame: translucency only exists
/// in the real MenuBarExtra window, so verify materials with
/// `screencapture -l<panel window number>`, not with this render.
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
