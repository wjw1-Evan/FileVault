import Foundation

/// One-click support diagnostics.
///
/// Good support needs reproducible, privacy-conscious reports: enough to
/// diagnose without asking users to paste terminal output, and without shipping
/// file contents or credentials anywhere.
public enum SupportBundle {
    /// Build the plain-text report shown to users and attached to the zip.
    ///
    /// - Home paths are collapsed to `~` so reports can be shared publicly.
    /// - Credentials never appear (they live in the keychain, not the config).
    public static func report(appVersion: String,
                              bundleIdentifier: String = AppBrand.bundleIdentifier,
                              config: AppConfig?,
                              gitDescription: String?,
                              roots: [String] = [],
                              now: Date = Date()) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let arch = ProcessInfo.processInfo.machineHardwareName ?? "unknown"
        var lines: [String] = []
        lines.append("FileVault 诊断报告")
        lines.append("生成时间: " + ISO8601DateFormatter().string(from: now))
        lines.append("")
        lines.append("## 应用")
        lines.append("版本: " + appVersion)
        lines.append("Bundle ID: " + bundleIdentifier)
        lines.append("macOS: " + os)
        lines.append("架构: " + arch)
        lines.append("语言: " + Locale.current.identifier)
        lines.append("许可: " + AppBrand.pricingNote + "（无账号、无订阅）")
        lines.append("")
        lines.append("## Git")
        lines.append("环境: " + (gitDescription ?? "未检测到"))
        lines.append("")
        lines.append("## 受保护的目录（已脱敏）")
        if roots.isEmpty {
            lines.append("（无）")
        } else {
            for root in roots {
                lines.append("- " + Self.masked(root) + "（1 个仓库）")
            }
        }
        lines.append("")
        lines.append("## 配置（已脱敏）")
        if let config {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(config),
               let json = String(data: data, encoding: .utf8) {
                lines.append(Self.masked(json))
            } else {
                lines.append("（无法序列化配置）")
            }
        } else {
            lines.append("（未加载配置）")
        }
        lines.append("")
        lines.append("## 隐私说明")
        lines.append("本报告不含任何文件内容、远程地址或账号；路径已替换为 ~。")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Write `diagnostics.txt` (plus a redacted config copy) into a zip.
    @discardableResult
    public static func export(report: String,
                              configDirectory: URL?,
                              destination: URL,
                              now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("fv-diagnostics-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try report.write(to: staging.appendingPathComponent("diagnostics.txt"), atomically: true, encoding: .utf8)
        if let configDirectory {
            let src = configDirectory.appendingPathComponent("config.json")
            if let data = try? Data(contentsOf: src) {
                let masked = Self.masked(String(decoding: data, as: UTF8.self))
                try? masked.write(to: staging.appendingPathComponent("config.redacted.json"), atomically: true, encoding: .utf8)
            }
        }

        let parent = destination.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--keepParent", staging.path, destination.path]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0, fm.fileExists(atPath: destination.path) else {
            throw DiagnosticsError.exportFailed
        }
        return destination
    }

    public enum DiagnosticsError: Error, LocalizedError {
        case exportFailed
        public var errorDescription: String? { "诊断包生成失败，请检查目标位置是否可写" }
    }

    // MARK: - Helpers

    /// Collapse the user's home directory to `~` (reports are shareable).
    public static func masked(_ text: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty, home != "/" else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }
}

extension ProcessInfo {
    /// "arm64" / "x86_64" without shelling out to uname.
    var machineHardwareName: String? {
        var sysinfo = utsname()
        guard uname(&sysinfo) == 0 else { return nil }
        let mirror = Mirror(reflecting: sysinfo.machine)
        var bytes: [UInt8] = []
        for child in mirror.children {
            guard let value = child.value as? Int8, value != 0 else { break }
            bytes.append(UInt8(bitPattern: value))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
