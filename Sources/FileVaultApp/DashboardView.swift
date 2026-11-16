import SwiftUI
import FileVaultCore

struct ActivityItem: Identifiable, Equatable {
    let id: String
    /// Protected folder that produced the commit (v4.0: one repo per folder).
    let rootName: String
    let subject: String
    let date: Date
}

struct RootRow: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let status: SyncStatus
    /// Configured but not attached right now (v4.2.26).
    let unavailable: Bool
    /// Auto-commit paused for this folder (v4.2.26).
    let paused: Bool
}

enum DashboardOverall {
    case ok, attention, setup

    var label: LocalizedStringKey {
        switch self {
        case .ok: return "全部正常"
        case .attention: return "需要处理"
        case .setup: return "Git 未就绪"
        }
    }

    var tint: Color {
        switch self {
        case .ok: return .green
        case .attention: return .red
        case .setup: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .setup: return "wrench.and.screwdriver.fill"
        }
    }
}

/// Dashboard content model: activity feed + protected roots + status line.
@MainActor
final class DashboardModel: ObservableObject {
    @Published var activity: [ActivityItem] = []
    @Published var rootRows: [RootRow] = []
    @Published var rootCount = 0
    @Published var failedCount = 0
    @Published var pendingCount = 0
    /// Attached folders with NO remote: "云端已最新" was a lie for them —
    /// their versions exist only on this Mac (v4.2.27 design round).
    @Published var noRemoteCount = 0
    @Published var overall: DashboardOverall = .ok
    @Published var lastActivity: Date?
    @Published var lastRootName = ""
    @Published var rootsEmpty = false
    @Published var stateLine = NSLocalizedString("正在加载…", comment: "dashboard state")
    /// Unreadable history, shown instead of a cheerful empty state (v4.2.26).
    @Published var activityError: String?
    /// Guards against an older refresh pass overwriting a newer snapshot.
    private var generation = 0

    private var app: AppState?
    private var timer: Timer?
    private var listenerToken: UUID?

    func bind(_ app: AppState) {
        self.app = app
        // Re-binding after the window was hidden and shown again must restore
        // the listener and timer; the old "guard self.app == nil" returned early,
        // leaving a window that never refreshed again (v4.2.25).
        if listenerToken == nil, let svc = app.service {
            listenerToken = svc.addStateListener { [weak self] in
                Task { @MainActor in await self?.refresh() }
            }
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
        // A window restored at login (or --open-ui) can appear before the
        // service exists; without this retry it never registered the listener and
        // fell back to 10 s polling forever (v4.2.26).
        if app.service == nil {
            Task { @MainActor [weak self] in
                for _ in 0..<50 where self?.app?.service == nil {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                guard let self, let a = self.app, a.service != nil else { return }
                self.bind(a)
            }
        }
        Task { @MainActor in await refresh() }
    }

    func unbind() {
        if let token = listenerToken { app?.service?.removeStateListener(token) }
        listenerToken = nil
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        guard let app = app, let svc = app.service else { return }
        generation += 1
        let pass = generation
        var items: [ActivityItem] = []
        var rows: [RootRow] = []
        var failed = 0
        var pending = 0
        var unavailable = 0
        var noRemote = 0
        var readError: String?
        // Configured folders (not just attached ones): an unplugged disk must
        // stay visible with a reason instead of disappearing (v4.2.26).
        let configured = svc.configuredRoots()
        for cfg in configured {
            // v4.0: one repo per protected folder — no subfolder enumeration.
            let root = cfg.path
            let name = (root as NSString).lastPathComponent
            let attached = svc.isAttached(root: root)
            var st: SyncStatus = .noRemote
            if attached {
                st = await svc.sync.status(for: root)
                if st == .failed { failed += 1 }
                if st == .pendingPush || st == .pushing { pending += 1 }
                if st == .noRemote { noRemote += 1 }
            } else {
                unavailable += 1
            }
            rows.append(RootRow(id: root, name: name, path: root, status: st,
                                unavailable: !attached, paused: cfg.paused))
            guard attached else { continue }
            do {
                let log = try await svc.history.commits(repoPath: root, limit: 3)
                for c in log {
                    items.append(ActivityItem(id: root + c.hash,
                                              rootName: name,
                                              subject: c.subject.fvDecodingGitEscapes,
                                              date: c.date))
                }
            } catch {
                // "can't read history" must not render as "no commits yet".
                if readError == nil { readError = error.localizedDescription }
            }
        }
        // A slow older pass must not overwrite the newer snapshot.
        guard pass == generation else { return }
        items.sort { $0.date > $1.date }
        activity = Array(items.prefix(6))
        rootRows = rows
        rootCount = configured.count
        failedCount = failed
        pendingCount = pending
        noRemoteCount = noRemote
        rootsEmpty = configured.isEmpty
        activityError = readError
        lastActivity = items.first?.date
        lastRootName = items.first?.rootName ?? ""

        if failed > 0 {
            overall = .attention
            stateLine = String(format: NSLocalizedString("%d 个文件夹推送失败，点击菜单查看",
                                                         comment: "dashboard state"), failed)
        } else if unavailable > 0 {
            overall = .attention
            stateLine = String(format: NSLocalizedString("%d 个文件夹当前不可用（外置盘未挂载或被移动）",
                                                         comment: "dashboard state"), unavailable)
        } else if svc.detection == nil {
            overall = .setup
            if let reason = app.gitSetupError, !reason.isEmpty {
                // Show the concrete reason (e.g. "所有 git 下载地址都失败了") instead of a dead end.
                let firstLine = reason.split(separator: "\n").first.map(String.init) ?? reason
                stateLine = firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine
            } else {
                stateLine = NSLocalizedString("Git 环境未就绪", comment: "dashboard state")
            }
        } else {
            overall = .ok
            // The pill already says 全部正常 — do not repeat it in the subtitle.
            stateLine = ""
        }
        let units = String(format: NSLocalizedString("%d 个文件夹受守护", comment: "dashboard state"),
                           rootCount)
        stateLine = stateLine.isEmpty
            ? units
            : String(format: NSLocalizedString("%@ · %@", comment: "dashboard state"), units, stateLine)
    }
}

/// Main dashboard: status header, summary strip, recent activity and roots.
struct DashboardView: View {
    /// The dashboard window sizes itself to its content; cap the roots list so
    /// a machine with dozens of roots still fits on screen without scrolling.
    static let maxRootRows = 8

    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = DashboardModel()
    @State private var quickAddPresented = false

    var body: some View {
        // v3.4.1: no ScrollView — the window is sized to the content, so the
        // dashboard always shows everything at once (no scrollbars ever).
        VStack(alignment: .leading, spacing: 16) {
            header
            summaryStrip
            HStack(alignment: .top, spacing: 16) {
                activityCard
                rootsCard
                    .frame(width: 272)
            }
            footer
        }
        .padding(24)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: 720, alignment: .leading)
        .fvCanvas()
        .task { model.bind(app) }
        .onDisappear { model.unbind() }
        .sheet(isPresented: $quickAddPresented) {
            QuickAddSheet {
                Task { await model.refresh() }
            }
            .environmentObject(app)
        }
        .onChange(of: app.quickAddRequested) { _, requested in
            guard requested else { return }
            app.quickAddRequested = false
            quickAddPresented = true
        }
        .onAppear {
            // The request may already be set when this window is first shown
            // (first-run onboarding), so onChange alone is not enough.
            if app.quickAddRequested {
                app.quickAddRequested = false
                quickAddPresented = true
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            FVIconBadge(symbol: "clock.arrow.circlepath", size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("FileVault")
                    .font(FVTheme.titleFont)
                    .tracking(-0.4)
                Text("文件时光机 · \(model.stateLine)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                FVStatusPill(text: model.overall.label,
                             tint: model.overall.tint,
                             symbol: model.overall.symbol)
                Text(app.version.isEmpty ? "" : "v\(app.version)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Summary

    private var summaryStrip: some View {
        HStack(spacing: 12) {
            FVStatTile(symbol: "folder.fill",
                       tint: .blue,
                       value: "\(model.rootCount)",
                       label: "受保护文件夹",
                       caption: model.rootRows.isEmpty
                           ? NSLocalizedString("尚未添加文件夹", comment: "dashboard tile")
                           : NSLocalizedString("全部纳入版本管理", comment: "dashboard tile"))
            FVStatTile(symbol: "clock.fill",
                       tint: .purple,
                       value: model.lastActivity.map(FVTime.relative) ?? "—",
                       label: "最近提交",
                       caption: model.lastRootName.isEmpty
                           ? NSLocalizedString("等待第一次记录", comment: "dashboard tile")
                           : model.lastRootName)
            syncTile
        }
    }

    /// The sync-status tile: "云端已最新" must not display when nothing is on
    /// the remote — folders without a remote show 仅本地 instead (v4.2.27
    /// design round).
    @ViewBuilder
    private var syncTile: some View {
        let hasFailure = model.failedCount > 0
        let hasPending = model.pendingCount > 0
        let localOnly = model.noRemoteCount > 0
        let valueText = hasFailure ? String(model.failedCount)
            : (hasPending ? String(model.pendingCount) : String(model.noRemoteCount))
        FVStatTile(symbol: hasFailure
                       ? "exclamationmark.triangle.fill"
                       : (hasPending ? "arrow.up.circle.fill"
                                     : (localOnly ? "internaldrive.fill" : "checkmark.icloud.fill")),
                   tint: hasFailure ? .red : (hasPending ? .orange : (localOnly ? .gray : .green)),
                   value: valueText,
                   label: hasFailure ? "推送失败" : (hasPending ? "待推送" : (localOnly ? "仅本地" : "待推送")),
                   caption: hasFailure
                       ? NSLocalizedString("本地版本已保留", comment: "dashboard tile")
                       : (hasPending
                          ? NSLocalizedString("正在等待上传", comment: "dashboard tile")
                          : (localOnly
                             ? NSLocalizedString("版本只保存在本机，绑定远程后自动上云", comment: "dashboard tile")
                             : NSLocalizedString("云端已最新", comment: "dashboard tile")))
        )
    }

    // MARK: Activity

    private var activityCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                FVSectionHeader(title: "最近活动",
                                subtitle: "自动提交会按时间聚合，不需要你手动保存")
                HStack(spacing: 10) {
                    Button("恢复文件") { app.open("recovery") }
                        .buttonStyle(.link)
                        .font(FVTheme.metaFont)
                    Button("全部历史") { app.open("history") }
                        .buttonStyle(.link)
                        .font(FVTheme.metaFont)
                }
                .padding(.trailing, 16)
            }
            FVHairline(leading: 0)
            if model.activity.isEmpty {
                if let readError = model.activityError {
                    // Never present "repository unreadable" as "no commits yet"
                    // (v4.2.26).
                    FVEmptyState(symbol: "exclamationmark.triangle",
                                 title: "读不到提交历史",
                                 message: LocalizedStringKey(readError))
                } else {
                    FVEmptyState(symbol: "clock",
                                 title: "还没有提交记录",
                                 message: "向受保护的文件夹写入文件，几秒后就会自动记录第一个版本。")
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.activity.enumerated()), id: \.element.id) { index, item in
                        activityRow(item)
                        if index < model.activity.count - 1 {
                            FVHairline(leading: 40)
                        }
                    }
                }
            }
        }
        .fvCard()
    }

    private func activityRow(_ item: ActivityItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(Color.green.opacity(0.9))
                .frame(width: 7, height: 7)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.subject)
                    .font(FVTheme.rowFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.subject)
                HStack(spacing: 6) {
                    Text(item.rootName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.10)))
                    Text(FVTime.absolute(item.date))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Text(FVTime.relative(item.date))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help(FVTime.absoluteWithSeconds(item.date))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: Roots

    private var rootsCard: some View {
        VStack(spacing: 0) {
            // The summary tile above already shows the folder count.
            FVSectionHeader(title: "受保护的文件夹")
            FVHairline(leading: 0)
            if model.rootsEmpty {
                FVEmptyState(symbol: "folder.badge.plus",
                             title: "还没有受保护的文件夹",
                             message: "添加一个文件夹，里面的所有文件都会自动拥有版本历史。",
                             actionTitle: "添加文件夹",
                             action: { quickAddPresented = true })
            } else {
                VStack(spacing: 0) {
                    // Bounded list: the window fits its content, so cap the rows
                    // instead of ever introducing a scrollbar.
                    ForEach(Array(model.rootRows.prefix(Self.maxRootRows).enumerated()), id: \.element.id) { index, row in
                        rootRow(row)
                        if index < min(model.rootRows.count, Self.maxRootRows) - 1 {
                            FVHairline(leading: 50)
                        }
                    }
                    if model.rootRows.count > Self.maxRootRows {
                        Button {
                            openWindow(id: "settings")
                        } label: {
                            Text(String(format: NSLocalizedString("还有 %d 个文件夹…", comment: "dashboard overflow"),
                                        model.rootRows.count - Self.maxRootRows))
                                .font(FVTheme.metaFont)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
                FVHairline(leading: 0)
                Button {
                    quickAddPresented = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11))
                        Text("添加文件夹…")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .fvCard()
    }

    private func rootRow(_ row: RootRow) -> some View {
        let meta = FVStatusMeta.forSync(row.status)
        let label = row.unavailable
            ? NSLocalizedString("不可用", comment: "dashboard root")
            : (row.paused ? NSLocalizedString("已暂停", comment: "dashboard root") : meta.label)
        let tint: Color = row.unavailable ? .orange : (row.paused ? .secondary : meta.tint)
        return HStack(spacing: 10) {
            FVIconBadge(symbol: "folder.fill", tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button {
                app.openPath(row.path)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(LocalizedStringKey("在 Finder 中打开：\(row.path)"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                openWindow(id: "settings")
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            Spacer()
        }
        .controlSize(.regular)
        .padding(.top, 2)
    }
}
