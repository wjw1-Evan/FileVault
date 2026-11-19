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
        lines.append(NSLocalizedString("Pastward 诊断报告", comment: "diagnostics report"))
        lines.append(String(format: NSLocalizedString("生成时间: %@", comment: "diagnostics report"),
                            ISO8601DateFormatter().string(from: now)))
        lines.append("")
        lines.append(NSLocalizedString("## 应用", comment: "diagnostics report"))
        lines.append(String(format: NSLocalizedString("版本: %@", comment: "diagnostics report"), appVersion))
        lines.append(String(format: NSLocalizedString("Bundle ID: %@", comment: "diagnostics report"), bundleIdentifier))
        lines.append(String(format: NSLocalizedString("macOS: %@", comment: "diagnostics report"), os))
        lines.append(String(format: NSLocalizedString("架构: %@", comment: "diagnostics report"), arch))
        lines.append(String(format: NSLocalizedString("语言: %@", comment: "diagnostics report"),
                            Locale.current.identifier))
        lines.append(String(format: NSLocalizedString("许可: %@（无账号、无订阅）", comment: "diagnostics report"),
                            AppBrand.pricingNote))
        lines.append("")
        lines.append(NSLocalizedString("## Git", comment: "diagnostics report"))
        lines.append(String(format: NSLocalizedString("环境: %@", comment: "diagnostics report"),
                            gitDescription ?? NSLocalizedString("未检测到", comment: "diagnostics report")))
        lines.append("")
        lines.append(NSLocalizedString("## 受保护的文件夹", comment: "diagnostics report"))
        if roots.isEmpty {
            lines.append(NSLocalizedString("（无）", comment: "diagnostics report"))
        } else {
            for root in roots {
                lines.append("- " + Self.masked(root)
                             + NSLocalizedString("（1 个仓库）", comment: "diagnostics report"))
            }
        }
        lines.append("")
        lines.append(NSLocalizedString("## 配置（已脱敏）", comment: "diagnostics report"))
        if let config {
            let encoder = JSONEncoder()
            // withoutEscapingSlashes is REQUIRED for masking to work: the default
            // encoder writes JSON paths as \"/Users\\/alice\\/...\" (escaped
            // slashes), so the home/Users replacement below silently missed them
            // and the "redacted" report leaked full account paths (v4.2.26).
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(config),
               let json = String(data: data, encoding: .utf8) {
                lines.append(Self.masked(json))
            } else {
                lines.append(NSLocalizedString("（无法序列化配置）", comment: "diagnostics report"))
            }
        } else {
            lines.append(NSLocalizedString("（未加载配置）", comment: "diagnostics report"))
        }
        lines.append("")
        lines.append(NSLocalizedString("## 隐私说明", comment: "diagnostics report"))
        lines.append(NSLocalizedString("本报告不含任何文件内容、远程地址或账号；家目录路径已替换为 ~，受保护文件夹的名称会保留以便排查。",
                                       comment: "diagnostics report"))
        // Mask the WHOLE report, not just roots/config: the git path and any
        // diagnostic detail can contain the user name, and the privacy section
        // promises paths are collapsed to "~" (v4.2.25).
        return Self.masked(lines.joined(separator: "\n")) + "\n"
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
                // Re-encode through the typed config (with unescaped slashes) so
                // the masked copy really has no /Users/<name> left. The old raw
                // text path kept \"\\/Users\\/name\" intact (v4.2.26).
                let redacted: String
                let decoder = JSONDecoder()
                if let cfg = try? decoder.decode(AppConfig.self, from: data) {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    if let encoded = try? encoder.encode(cfg),
                       let json = String(data: encoded, encoding: .utf8) {
                        redacted = Self.masked(json)
                    } else {
                        redacted = Self.masked(String(decoding: data, as: UTF8.self))
                    }
                } else {
                    redacted = Self.masked(String(decoding: data, as: UTF8.self))
                }
                try? redacted.write(to: staging.appendingPathComponent("config.redacted.json"),
                                    atomically: true, encoding: .utf8)
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
        public var errorDescription: String? {
            NSLocalizedString("诊断包生成失败，请检查目标位置是否可写", comment: "diagnostics error")
        }
    }

    // MARK: - Helpers

    /// Collapse the user's home directory to `~` (reports are shareable).
    public static func masked(_ text: String) -> String {
        var out = text
        // JSON text contains escaped slashes (\/Users\/alice). Normalise first:
        // otherwise every replacement below silently misses and the "redacted"
        // report keeps full account paths (v4.2.26).
        out = out.replacingOccurrences(of: "\\/", with: "/")
        let home = NSHomeDirectory()
        if !home.isEmpty, home != "/" {
            // Complete path component only: /Users/alice must not turn
            // /Users/alice2 into ~2.
            let homePattern = NSRegularExpression.escapedPattern(for: home) + "(?=/|$)"
            out = out.replacingOccurrences(of: homePattern, with: "~", options: .regularExpression)
        }
        // Other accounts on the same Mac still reveal a login name; collapse
        // them too (idempotent for paths already shortened to "~").
        out = out.replacingOccurrences(of: #"/Users/[^/\s"]+"#, with: "~",
                                       options: .regularExpression)
        return out
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
