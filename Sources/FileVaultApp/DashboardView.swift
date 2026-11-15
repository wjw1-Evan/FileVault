import SwiftUI
import FileVaultCore

struct ActivityItem: Identifiable, Equatable {
    let id: String
    let repoName: String
    let subject: String
    let date: Date
}

/// Dashboard content model: activity feed + protected roots + status line.
@MainActor
final class DashboardModel: ObservableObject {
    @Published var activity: [ActivityItem] = []
    @Published var rootRows: [(id: String, name: String, count: Int, path: String)] = []
    @Published var repoCount = 0
    @Published var stateLine = "正在加载…"
    @Published var rootsEmpty = false

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

    func refresh() async {
        guard let app = app, let svc = app.service else { return }
        var items: [ActivityItem] = []
        var rows: [(String, String, Int, String)] = []
        var count = 0
        var failed = 0
        let roots = svc.rootsSnapshot()
        for root in roots {
            let folders = svc.repoManager.firstLevelFolders(root: root)
            count += folders.count
            rows.append(((root as NSString).lastPathComponent, root, folders.count, root))
            for r in folders {
                let st = await svc.sync.status(for: r.path)
                if st == .failed { failed += 1 }
                if let log = try? await svc.history.commits(repoPath: r.path, limit: 3) {
                    for c in log {
                        items.append(ActivityItem(id: r.path + c.hash, repoName: r.name, subject: c.subject, date: c.date))
                    }
                }
            }
        }
        items.sort { $0.date > $1.date }
        activity = Array(items.prefix(10))
        rootRows = rows.map { (id: $0.1, name: $0.0, count: $0.2, path: $0.1) }
        repoCount = count
        rootsEmpty = roots.isEmpty
        let state: String
        if svc.pause.isGloballyPaused {
            state = "已暂停自动提交"
        } else if failed > 0 {
            state = "\(failed) 个仓库推送失败，点击菜单查看"
        } else if svc.detection == nil {
            state = "Git 环境未就绪"
        } else {
            state = "全部正常"
        }
        let versionPart = app.version.isEmpty ? "" : " · v" + app.version
        stateLine = "\(count) 个仓库受守护 · \(state)\(versionPart)"
    }
}

/// Main dashboard (status overview + recent activity + protected roots).
struct DashboardView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = DashboardModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerCard
                activityCard
                rootsCard
                footerButtons
            }
            .padding(16)
        }
        .frame(minWidth: 620, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { model.bind(app) }
    }

    private var headerCard: some View {
        card {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                Text("FileVault — 文件时光机")
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(model.stateLine)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var activityCard: some View {
        card {
            Text("最近活动").font(.system(size: 14, weight: .semibold))
            if model.activity.isEmpty {
                Text("还没有任何提交——向文件夹写入文件后会自动记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.activity) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.green)
                            .font(.system(size: 12))
                        Text(item.date.formatted(.dateTime.month().day().hour().minute()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(item.repoName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.subject)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }

    private var rootsCard: some View {
        card {
            Text("受保护的目录").font(.system(size: 14, weight: .semibold))
            if model.rootsEmpty {
                Text("尚未添加根目录——点击下方「设置」添加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.rootRows, id: \.id) { row in
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 13))
                    Text(row.name).font(.system(size: 13))
                    Text("\(row.count) 个仓库")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("打开") { app.openPath(row.path) }
                        .controlSize(.small)
                }
            }
        }
    }

    private var footerButtons: some View {
        HStack(spacing: 8) {
            Button {
                openWindow(id: "settings")
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            Button {
                openWindow(id: "history")
            } label: {
                Label("历史", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}
