import Foundation

/// One managed root folder with its own pause flag (FR-02).
public struct ManagedRoot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var paused: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    }

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
    /// The USER's intent for login-launch; re-registered after updates break it.
    public var launchAtLoginRequested: Bool

    public init(notificationsEnabled: Bool = true,
                autoCheckUpdates: Bool = true,
                debounceSeconds: Int = 5,
                launchAtLoginRequested: Bool = false) {
        self.notificationsEnabled = notificationsEnabled
        self.autoCheckUpdates = autoCheckUpdates
        self.debounceSeconds = max(1, debounceSeconds)
        self.launchAtLoginRequested = launchAtLoginRequested
    }

    public static let `default` = GeneralSettings()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        autoCheckUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? true
        debounceSeconds = max(1, (try c.decodeIfPresent(Int.self, forKey: .debounceSeconds)) ?? 5)
        // v3.1.3: the local large-file threshold was removed (the remote's own
        // limit is authoritative); old configs that still carry the key keep
        // decoding because unknown keys are simply ignored.
        launchAtLoginRequested = try c.decodeIfPresent(Bool.self, forKey: .launchAtLoginRequested) ?? false
    }
}

/// Top-level app configuration. Custom decoding so NEW keys never invalidate
/// OLD config files (the v1.3.0 silent-root-loss bug).
public struct AppConfig: Codable, Equatable, Sendable {
    public var roots: [ManagedRoot]
    public var general: GeneralSettings

    public init(roots: [ManagedRoot] = [], general: GeneralSettings = .default) {
        self.roots = roots
        self.general = general
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roots = try c.decodeIfPresent([ManagedRoot].self, forKey: .roots) ?? []
        general = try c.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? .default
    }
}

/// JSON config persistence at <dir>/config.json (FR-02 / NFR privacy).
public final class ConfigStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var cache: AppConfig?

    /// Default on-disk location (`~/Library/Application Support/FileVault`).
    public static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/FileVault")
    }

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
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
        // Missing/corrupt file: return the default WITHOUT caching it — a
        // poisoned cache would make the NEXT save() wipe the user's real roots
        // (the silent-root-loss class of bug, v1.3.0). Retry the disk next time.
        return AppConfig()
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
