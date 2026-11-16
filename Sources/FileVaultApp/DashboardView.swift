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
    @Published var overall: DashboardOverall = .ok
    @Published var lastActivity: Date?
    @Published var lastRootName = ""
    @Published var rootsEmpty = false
    @Published var stateLine = "正在加载…"

    private var app: AppState?
    private var timer: Timer?
    private var listenerToken: UUID?

    func bind(_ app: AppState) {
        guard self.app == nil else { return }
        self.app = app
        listenerToken = app.service?.addStateListener { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
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
        var items: [ActivityItem] = []
        var rows: [RootRow] = []
        var failed = 0
        var pending = 0
        let roots = svc.rootsSnapshot()
        for root in roots {
            // v4.0: one repo per protected folder — no subfolder enumeration.
            let name = (root as NSString).lastPathComponent
            let st = await svc.sync.status(for: root)
            if st == .failed { failed += 1 }
            if st == .pendingPush || st == .pushing { pending += 1 }
            rows.append(RootRow(id: root, name: name, path: root, status: st))
            if let log = try? await svc.history.commits(repoPath: root, limit: 3) {
                for c in log {
                    items.append(ActivityItem(id: root + c.hash,
                                              rootName: name,
                                              subject: c.subject.fvDecodingGitEscapes,
                                              date: c.date))
                }
            }
        }
        items.sort { $0.date > $1.date }
        activity = Array(items.prefix(6))
        rootRows = rows
        rootCount = roots.count
        failedCount = failed
        pendingCount = pending
        rootsEmpty = roots.isEmpty
        lastActivity = items.first?.date
        lastRootName = items.first?.rootName ?? ""

        if failed > 0 {
            overall = .attention
            stateLine = String(format: NSLocalizedString("%d 个文件夹推送失败，点击菜单查看",
                                                         comment: "dashboard state"), failed)
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
                       caption: model.rootRows.isEmpty ? "尚未添加文件夹" : "全部纳入版本管理")
            FVStatTile(symbol: "clock.fill",
                       tint: .purple,
                       value: model.lastActivity.map(FVTime.relative) ?? "—",
                       label: "最近提交",
                       caption: model.lastRootName.isEmpty ? "等待第一次记录" : model.lastRootName)
            FVStatTile(symbol: model.failedCount > 0
                          ? "exclamationmark.triangle.fill"
                          : (model.pendingCount > 0 ? "arrow.up.circle.fill" : "checkmark.icloud.fill"),
                       tint: model.failedCount > 0 ? .red : (model.pendingCount > 0 ? .orange : .green),
                       value: "\(model.failedCount > 0 ? model.failedCount : model.pendingCount)",
                       label: model.failedCount > 0 ? "推送失败" : "待推送",
                       caption: model.failedCount > 0
                           ? "本地版本已保留"
                           : (model.pendingCount > 0 ? "正在等待上传" : "云端已最新"))
        }
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
                FVEmptyState(symbol: "clock",
                             title: "还没有提交记录",
                             message: "向受保护的文件夹写入文件，几秒后就会自动记录第一个版本。")
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
        return HStack(spacing: 10) {
            FVIconBadge(symbol: "folder.fill", tint: .orange, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta.label)
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
            .help("在 Finder 中打开：\(row.path)")
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
