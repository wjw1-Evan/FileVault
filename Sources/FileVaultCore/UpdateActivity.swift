import Foundation

/// In-flight update state surfaced in the menu bar (v3.1.5).
///
/// The updater used to open a dedicated progress window (FR-20). Menus are a
/// better home for it: the user already has the menu open, and a window that
/// pops up over the desktop during a silent auto-update is noise. Because a
/// `.menu`-style MenuBarExtra cannot host a live SwiftUI ProgressView, the
/// percentage is rendered into the text itself.
public struct UpdateActivity: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case checking
        case downloading
        case verifying
        case installing
        case restarting
    }

    public var phase: Phase
    /// 0...1 download progress; nil while the total size is unknown.
    public var fraction: Double?
    /// Optional second-line detail (byte counts).
    public var detail: String

    public init(phase: Phase, fraction: Double? = nil, detail: String = "") {
        self.phase = phase
        self.fraction = fraction
        self.detail = detail
    }

    /// Whole percent, clamped to 0...100 and rounded down so the menu never
    /// claims 100% before the download is finished.
    public var percent: Int? {
        guard let fraction else { return nil }
        let clamped = min(max(fraction, 0), 1)
        return Int((clamped * 100).rounded(.down))
    }

    /// One menu line describing the current step.
    public var menuText: String {
        switch phase {
        case .checking:
            return NSLocalizedString("正在检查更新…", comment: "update phase")
        case .downloading:
            var text = NSLocalizedString("正在下载更新", comment: "update phase")
            if let percent { text += " \(percent)%" }
            text += "…"
            if !detail.isEmpty { text += " · " + detail }
            return text
        case .verifying:
            return NSLocalizedString("正在校验更新…", comment: "update phase")
        case .installing:
            return NSLocalizedString("正在安装更新…", comment: "update phase")
        case .restarting:
            return NSLocalizedString("更新完成，正在重启…", comment: "update phase")
        }
    }
}

/// Finished update outcomes (shown in the menu instead of an alert panel).
public enum UpdateStatus {
    public static func upToDate(_ version: String) -> String {
        String(format: NSLocalizedString("已是最新版本（v%@）", comment: "update status"), version)
    }

    public static func failed(_ reason: String?) -> String {
        guard let reason, !reason.isEmpty else {
            return NSLocalizedString("更新失败，将自动重试", comment: "update status")
        }
        return String(format: NSLocalizedString("更新失败：%@", comment: "update status"), reason)
    }

    /// Unbundled builds (`.build/debug/FileVaultApp`) cannot be replaced.
    public static var developmentBuild: String {
        NSLocalizedString("开发模式运行，不自动安装更新", comment: "update status")
    }
}
