import SwiftUI

/// Update progress window (FR-20): visible stage + byte-level progress.
struct UpdateProgressView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("正在更新 FileVault")
                .font(.headline)
            if let stage = app.updateStage {
                Text(stage.text)
                if let fraction = stage.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                if !stage.detail.isEmpty {
                    Text(stage.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(width: 380, height: 160)
    }
}
