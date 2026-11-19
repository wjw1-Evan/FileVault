import SwiftUI
import FileVaultCore

/// v4.2.20: one window for everything version-related.
///
/// "历史版本" and "文件恢复" are two views of the same thing (a folder's
/// versions); keeping them as separate windows made users learn two concepts
/// and two entry points. They now share one window with a two-tab switch, and
/// both views stay mounted so switching tabs keeps the selected folder/version.
struct RecordsWindow: View {
    @EnvironmentObject var app: AppState
    /// Cross-tab handoff (v4.2.30 audit round): the folder the recovery tab
    /// asks the timeline to open. Owned here so both tabs stay plain views;
    /// the tab switch itself still goes through app.recordsTab.
    @StateObject private var handoff = RecordsHandoff()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $app.recordsTab) {
                    ForEach(RecordsTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            FVHairline(leading: 0)

            ZStack {
                RecoveryView(handoff: handoff)
                    .opacity(app.recordsTab == .recover ? 1 : 0)
                    .allowsHitTesting(app.recordsTab == .recover)
                    .accessibilityHidden(app.recordsTab != .recover)
                HistoryView(handoff: handoff)
                    .opacity(app.recordsTab == .history ? 1 : 0)
                    .allowsHitTesting(app.recordsTab == .history)
                    .accessibilityHidden(app.recordsTab != .history)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 700)
        .fvCanvas()
    }
}

/// Which tab of the shared 历史与恢复 window is showing.
enum RecordsTab: String, CaseIterable, Identifiable {
    case recover
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recover: return NSLocalizedString("文件恢复", comment: "records tab")
        case .history: return NSLocalizedString("历史时间线", comment: "records tab")
        }
    }

    var symbol: String {
        switch self {
        case .recover: return "arrow.uturn.backward.circle"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

/// Folder the recovery tab asked the history tab to show ("去历史时间线按提交
/// 查找"). Consumed once when the history tab activates; later switches keep
/// whatever the user picks there, matching the mounted-both-tabs behavior of
/// RecordsWindow (v4.2.30 audit round).
@MainActor
final class RecordsHandoff: ObservableObject {
    @Published var requestedHistoryRoot: String?
}
