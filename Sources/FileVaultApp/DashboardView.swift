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

/// Main dashboard (native GroupBox styling, v3.1.0).
struct DashboardView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = DashboardModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                activityGroupBox
                rootsGroupBox
                footerButtons
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 540)
        .task { model.bind(app) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FileVault — 文件时光机")
                .font(.title2.weight(.semibold))
            Text(model.stateLine)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activityGroupBox: some View {
        GroupBox("最近活动") {
            VStack(alignment: .leading, spacing: 6) {
                if model.activity.isEmpty {
                    Text("还没有任何提交——向文件夹写入文件后会自动记录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.activity) { item in
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.green)
                            Text(item.date.formatted(.dateTime.month().day().hour().minute()))
                                .monospacedDigit()
                            Text(item.repoName)
                                .foregroundStyle(.secondary)
                            Text(item.subject)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rootsGroupBox: some View {
        GroupBox("受保护的目录") {
            VStack(alignment: .leading, spacing: 8) {
                if model.rootsEmpty {
                    Text("尚未添加根目录——点击下方「设置」添加")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.rootRows, id: \.id) { row in
                    HStack {
                        Label(row.name, systemImage: "folder")
                        Text("\(row.count) 个仓库")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("打开") { app.openPath(row.path) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footerButtons: some View {
        HStack(spacing: 10) {
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
            Spacer()
        }
    }
}
