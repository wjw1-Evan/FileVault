import Foundation

/// One managed root folder with its own pause flag (FR-02).
public struct ManagedRoot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var paused: Bool

    public init(path: String, paused: Bool = false) {
        var resolved = path
        if let resolvedURL = try? URL(fileURLWithPath: path).resolvingSymlinksInPath() {
            resolved = resolvedURL.path
        }
        self.path = resolved
        self.paused = paused
    }
}

/// General (non-root) user preferences (v1.3.0 complete settings).
public struct GeneralSettings: Codable, Equatable, Sendable {
    public var notificationsEnabled: Bool
    public var autoCheckUpdates: Bool
    public var debounceSeconds: Int          // auto-commit quiet window
    public var largeFileThresholdMB: Int     // FR-12 threshold

    public init(notificationsEnabled: Bool = true,
                autoCheckUpdates: Bool = true,
                debounceSeconds: Int = 5,
                largeFileThresholdMB: Int = 200) {
        self.notificationsEnabled = notificationsEnabled
        self.autoCheckUpdates = autoCheckUpdates
        self.debounceSeconds = max(1, debounceSeconds)
        self.largeFileThresholdMB = max(1, largeFileThresholdMB)
    }

    public static let `default` = GeneralSettings()
}

/// Top-level app configuration.
public struct AppConfig: Codable, Equatable, Sendable {
    public var roots: [ManagedRoot]
    public var general: GeneralSettings

    public init(roots: [ManagedRoot] = [], general: GeneralSettings = .default) {
        self.roots = roots
        self.general = general
    }
}

/// JSON config persistence at <dir>/config.json (FR-02 / NFR privacy).
public final class ConfigStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var cache: AppConfig?

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/FileVault")
        }
    }

    public func load() -> AppConfig {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }
        let file = directory.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: file),
           let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            cache = cfg
            return cfg
        }
        let empty = AppConfig()
        cache = empty
        return empty
    }

    public func save(_ config: AppConfig) {
        lock.lock(); defer { lock.unlock() }
        cache = config
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config.json")
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
