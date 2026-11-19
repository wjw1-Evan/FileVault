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
        // URL(fileURLWithPath:) is infallible and resolvingSymlinksInPath()
        // never throws — the old try? bound unconditionally (v4.2.31).
        self.path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        self.paused = paused
    }
}

/// General (non-root) user preferences (v1.3.0 complete settings).
public struct GeneralSettings: Codable, Equatable, Sendable {
    public var notificationsEnabled: Bool
    public var autoCheckUpdates: Bool
    public var debounceSeconds: Int          // auto-commit quiet window
    /// Interface language: "system" (default), "zh-Hans" or "en" (v3.4.0).
    public var language: String
    /// The USER's intent for login-launch; re-registered after updates break it.
    public var launchAtLoginRequested: Bool

    public init(notificationsEnabled: Bool = true,
                autoCheckUpdates: Bool = true,
                debounceSeconds: Int = 5,
                language: String = "system",
                launchAtLoginRequested: Bool = false) {
        self.notificationsEnabled = notificationsEnabled
        self.autoCheckUpdates = autoCheckUpdates
        self.debounceSeconds = max(1, debounceSeconds)
        let valid = ["system", "zh-Hans", "en"]
        self.language = valid.contains(language) ? language : "system"
        self.launchAtLoginRequested = launchAtLoginRequested
    }

    public static let `default` = GeneralSettings()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        autoCheckUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? true
        debounceSeconds = max(1, (try c.decodeIfPresent(Int.self, forKey: .debounceSeconds)) ?? 5)
        let rawLanguage = (try c.decodeIfPresent(String.self, forKey: .language)) ?? "system"
        language = ["system", "zh-Hans", "en"].contains(rawLanguage) ? rawLanguage : "system"
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

/// Why the on-disk configuration could not be used as-is (v4.2.12).
public enum ConfigLoadIssue: String, Sendable, Equatable {
    /// config.json was corrupt; the last good backup was used instead.
    case recoveredFromBackup
    /// Neither config.json nor its backup could be read.
    case unreadable
}

/// JSON config persistence at <dir>/config.json (FR-02 / NFR privacy).
public final class ConfigStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var cache: AppConfig?
    /// Signature (size+mtime) of config.json when `cache` was read/written.
    /// A second FileVault instance can edit the file at any time (the docs
    /// support running two instances) — serving a stale cache made the next
    /// save silently overwrite the other instance's changes (v4.2.26).
    private var cacheSignature: String?
    /// Set when the first disk read had to recover from a bad primary file.
    public private(set) var lastLoadIssue: ConfigLoadIssue?

    /// Default on-disk location (`~/Library/Application Support/FileVault`).
    ///
    /// `FV_CONFIG_DIR` overrides it for diagnostics/screenshots and isolated
    /// runs — rendering a demo vault must never touch the real configuration.
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["FV_CONFIG_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/FileVault")
    }

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    /// Fingerprint of config.json on disk (nil when it does not exist).
    private func diskSignature() -> String? {
        let primary = directory.appendingPathComponent("config.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: primary.path),
              let size = attrs[.size] as? Int,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return "\(size)-\(modified.timeIntervalSince1970)"
    }

    public func load() -> AppConfig {
        lock.lock(); defer { lock.unlock() }
        // Re-read when another writer changed the file since we cached it.
        if let cache, cacheSignature == diskSignature() { return cache }
        let primary = directory.appendingPathComponent("config.json")
        let backup = directory.appendingPathComponent(Self.backupFileName)
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: primary),
           let cfg = try? decoder.decode(AppConfig.self, from: data) {
            cache = cfg
            cacheSignature = diskSignature()
            lastLoadIssue = nil
            return cfg
        }
        let primaryExists = FileManager.default.fileExists(atPath: primary.path)
        if let data = try? Data(contentsOf: backup),
           let cfg = try? decoder.decode(AppConfig.self, from: data) {
            // Recover the last good state instead of silently starting empty;
            // the next save() rewrites config.json from this cache.
            cache = cfg
            cacheSignature = diskSignature()
            lastLoadIssue = .recoveredFromBackup
            return cfg
        }
        if primaryExists {
            // Deliberately do NOT cache: a poisoned cache would make the next
            // save() wipe the user's real roots (v1.3.0).
            lastLoadIssue = .unreadable
            return AppConfig()
        }
        lastLoadIssue = nil
        return AppConfig()
    }

    /// Persist the configuration. Returns false when the file could not be
    /// written (disk full, read-only folder): callers must tell the user that
    /// the change works for this session but may not survive a restart — the
    /// old silent `try?` made "已保存" a lie (v4.2.25).
    @discardableResult
    public func save(_ config: AppConfig) -> Bool {
        lock.lock(); defer { lock.unlock() }
        cache = config
        lastSaveIssue = nil
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Do NOT chmod an EXISTING directory: a deliberately read-only config dir
        // must stay read-only so save() reports the failure. New directories are
        // created 0700 above.
        let primary = directory.appendingPathComponent("config.json")
        let backup = directory.appendingPathComponent(Self.backupFileName)
        // Keep the previous good config as a backup before replacing it. A
        // corrupt primary is kept aside for forensics instead of overwritten.
        if FileManager.default.fileExists(atPath: primary.path) {
            if let old = try? Data(contentsOf: primary),
               (try? JSONDecoder().decode(AppConfig.self, from: old)) != nil {
                // v4.2.32: a failed backup write used to be silent — the next
                // corrupt primary then had NO good copy to recover from, and
                // nothing anywhere said so. Record it; the save still proceeds
                // (the primary is replaced with the new good config either way).
                do {
                    try old.write(to: backup, options: .atomic)
                } catch {
                    lastSaveIssue = .backupWriteFailed
                }
                // The backup holds every protected-folder path too: without the
                // chmod it stayed 0644 while the primary was 0600 (v4.2.27).
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: backup.path)
            } else {
                let stamp = Self.stamp()
                let corrupt = directory.appendingPathComponent("config.corrupt-\(stamp).json")
                try? FileManager.default.moveItem(atPath: primary.path, toPath: corrupt.path)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: corrupt.path)
            }
        }
        guard let data = try? JSONEncoder().encode(config) else { return false }
        do {
            try data.write(to: primary, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: primary.path)
            cacheSignature = diskSignature()
            return true
        } catch {
            return false
        }
    }

    static let backupFileName = "config.backup.json"

    /// Why the last save was degraded (survives until the next successful
    /// save so Settings can surface it, v4.2.32).
    public enum SaveIssue: String, Sendable, Equatable {
        /// The pre-save backup of the previous config could not be written;
        /// the primary file is still current (the save itself succeeded).
        case backupWriteFailed
    }
    public private(set) var lastSaveIssue: SaveIssue?

    private static func stamp() -> String {
        // en_US_POSIX digits: an ar/falocale system formats digits as
        // ٢٠٢٦… producing a filename that no shell/regex round-trips
        // (same class of bug as RepoManager.backupStamp, fixed there in
        // v4.2.25) (v4.2.32).
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// Test probe for the locale contract (v4.2.32).
    static func stampForTests() -> String { stamp() }
}
