import Foundation

/// Post-update safety: verify the new bundle before installing it, and roll
/// back automatically if the new version fails to start (v3.3.0).
///
/// Lifecycle:
/// 1. The update flow writes a marker (previous version, new version, attempts)
///    right before relaunching.
/// 2. Every launch consumes the marker and bumps its attempt counter.
/// 3. A successful startup clears the marker.
/// 4. If the marker survives `maxLaunchAttempts` launches, the current bundle is
///    swapped back for the retained `.old` copy on the next start.
public enum UpdateGuard {
    public static let maxLaunchAttempts = 3
    static let markerFileName = "update-attempt.json"

    public struct Marker: Codable, Equatable, Sendable {
        /// Schema version for FUTURE evolution: a hand-written decoder keeps
        /// old markers loadable when non-optional fields are added later — a
        /// synthesized decoder would fail the whole marker and silently
        /// disable the crash-loop protection (v4.2.27).
        public var version: Int
        public var previousVersion: String
        public var newVersion: String
        public var attempts: Int
        public var startedAt: Date

        enum CodingKeys: String, CodingKey {
            case version, previousVersion, newVersion, attempts, startedAt
        }

        public init(previousVersion: String, newVersion: String, attempts: Int = 0, startedAt: Date = Date()) {
            self.version = 1
            self.previousVersion = previousVersion
            self.newVersion = newVersion
            self.attempts = attempts
            self.startedAt = startedAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            previousVersion = try c.decode(String.self, forKey: .previousVersion)
            newVersion = try c.decode(String.self, forKey: .newVersion)
            attempts = try c.decode(Int.self, forKey: .attempts)
            startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        }
    }

    public static func markerURL(configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent(markerFileName)
    }

    public static func read(configDirectory: URL) -> Marker? {
        guard let data = try? Data(contentsOf: markerURL(configDirectory: configDirectory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Marker.self, from: data)
    }

    /// Record that an update is about to be installed (called before relaunch).
    ///
    /// Returns false when the marker could not be persisted (read-only config
    /// dir, disk full, …). Without a marker a broken new build can never be
    /// rolled back, so the caller must abort the install instead of silently
    /// losing the crash-loop protection (v4.2.26).
    @discardableResult
    public static func beginUpdate(configDirectory: URL, previousVersion: String, newVersion: String) -> Bool {
        let marker = Marker(previousVersion: previousVersion, newVersion: newVersion, attempts: 0)
        return write(marker, configDirectory: configDirectory)
    }

    /// Remove a pending marker: called when the update is aborted after
    /// `beginUpdate` armed it (e.g. the new package could not be moved into
    /// place), so the next launch does not treat it as a crash loop (v4.2.26).
    public static func cancelUpdate(configDirectory: URL) {
        try? FileManager.default.removeItem(at: markerURL(configDirectory: configDirectory))
    }

    /// Called on every launch: bumps the attempt counter and returns the marker
    /// (nil when there is no update in flight).
    @discardableResult
    public static func consumeLaunch(configDirectory: URL) -> Marker? {
        guard var marker = read(configDirectory: configDirectory) else { return nil }
        marker.attempts += 1
        write(marker, configDirectory: configDirectory)
        return marker
    }

    /// Called once the app is up: the new version started fine.
    public static func markHealthy(configDirectory: URL) {
        try? FileManager.default.removeItem(at: markerURL(configDirectory: configDirectory))
    }

    /// More attempts than allowed → the bundle is presumed broken.
    ///
    /// Also requires that the running bundle is still the version the marker
    /// was written for: if the user manually reinstalled another (working)
    /// build after a couple of failed launches, rolling back to the stale
    /// `.old` copy would destroy their recovery (v4.2.26).
    public static func shouldRollback(_ marker: Marker, currentVersion: String) -> Bool {
        // Semantic comparison instead of exact string equality: a release zip
        // whose bundled version differs from its tag used to silently DISABLE
        // the rollback guard for that update (v4.2.27).
        marker.attempts >= maxLaunchAttempts
            && HttpReleaseFetcher.compare(marker.newVersion, currentVersion) == 0
    }

    /// Legacy overload without the running version. Kept for source
    /// compatibility with callers that only have the marker; new code should
    /// pass `currentVersion` so a manual reinstall is never rolled back.
    @available(*, deprecated, message: "Pass the running version: shouldRollback(_:currentVersion:)")
    public static func shouldRollback(_ marker: Marker) -> Bool {
        marker.attempts >= maxLaunchAttempts
    }

    /// The retained previous bundle next to the running app (…/FileVault.app.old).
    public static func rollbackSource(for bundleURL: URL) -> URL? {
        let candidate = bundleURL.deletingLastPathComponent()
            .appendingPathComponent(bundleURL.lastPathComponent + ".old")
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    /// Persist the marker; returns false when the directory or file could not
    /// be written. The old version used `try?` everywhere, so a failed marker
    /// write left the app updated but without crash-loop protection (v4.2.26).
    @discardableResult
    static func write(_ marker: Marker, configDirectory: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(marker) else { return false }
        let url = markerURL(configDirectory: configDirectory)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return false
        }
        // Verify the marker really landed: a silent write failure would leave
        // the freshly updated app without crash-loop protection.
        return fm.fileExists(atPath: url.path)
    }
}

/// Code-signature checks for a downloaded update bundle (v3.3.0).
///
/// The GitHub API digest only proves that the zip matches what that API said;
/// it does not prove who built it. Verifying the bundled app's signature closes
/// the gap once releases are signed with a Developer ID: an attacker cannot
/// re-sign a payload with the vendor's team id.
public enum UpdateSignature {
    public enum Failure: Error, LocalizedError, Equatable {
        case missingInfoPlist
        case invalidSignature(String)
        case wrongIdentifier(String, String)
        case teamChanged(current: String?, new: String?)

        public var errorDescription: String? {
            switch self {
            case .missingInfoPlist:
                return NSLocalizedString("更新包缺少 Info.plist", comment: "update guard")
            case .invalidSignature(let detail):
                return String(format: NSLocalizedString("更新包签名校验失败：%@", comment: "update guard"), detail)
            case .wrongIdentifier(let expected, let got):
                return String(format: NSLocalizedString("更新包不是本应用（%@ ≠ %@）", comment: "update guard"),
                              got, expected)
            case .teamChanged(let current, let new):
                let none = NSLocalizedString("无", comment: "update guard: none")
                return String(format: NSLocalizedString("更新包签名团队不一致（%@ ≠ %@）", comment: "update guard"),
                              new ?? none, current ?? none)
            }
        }
    }

    public struct Info: Equatable, Sendable {
        public var identifier: String?
        public var teamIdentifier: String?
        public var signatureValid: Bool
        public var isAdHoc: Bool
    }

    /// Verify a freshly extracted bundle before it replaces the running app.
    public static func verify(newBundle: URL,
                              expectedIdentifier: String = AppBrand.bundleIdentifier,
                              referenceBundle: URL? = nil) throws {
        let info = inspect(newBundle)
        guard info.identifier != nil else { throw Failure.missingInfoPlist }
        guard info.signatureValid else {
            throw Failure.invalidSignature(NSLocalizedString("codesign --verify 未通过", comment: "update guard"))
        }
        guard info.identifier == expectedIdentifier else {
            throw Failure.wrongIdentifier(expectedIdentifier, info.identifier ?? "")
        }
        if let referenceBundle {
            let reference = inspect(referenceBundle)
            guard acceptTeam(current: reference.teamIdentifier, new: info.teamIdentifier) else {
                throw Failure.teamChanged(current: reference.teamIdentifier, new: info.teamIdentifier)
            }
        }
    }

    /// Pinning rule:
    /// - Signed release → the update must come from the same team.
    /// - Unsigned/ad-hoc release (development builds) → any ad-hoc bundle with
    ///   the same identifier passes; a *downgrade* from signed to unsigned is
    ///   rejected.
    /// - First migration ad-hoc → Developer ID is allowed once.
    public static func acceptTeam(current: String?, new: String?) -> Bool {
        switch (current, new) {
        case (nil, _): return true                    // dev builds: identifier is the only pin
        case (let current?, let new?): return current == new
        case (_?, nil): return false                  // signed release must never downgrade
        }
    }

    /// Read identifier + team id and check the signature with codesign.
    public static func inspect(_ bundle: URL) -> Info {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        let identifier: String? = {
            guard let data = try? Data(contentsOf: plist),
                  let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                return nil
            }
            return obj["CFBundleIdentifier"] as? String
        }()

        let verify = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path])
        let details = run("/usr/bin/codesign", ["-dv", "--verbose=4", bundle.path])
        let text = details.stderr + details.stdout
        let team = parseValue(in: text, key: "TeamIdentifier")
        let adHoc = text.contains("Signature=adhoc")
        return Info(identifier: identifier,
                    teamIdentifier: team == "not set" ? nil : team,
                    signatureValid: verify.status == 0,
                    isAdHoc: adHoc)
    }

    static func parseValue(in text: String, key: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == key {
                return parts[1]
            }
        }
        return nil
    }

    struct ProcessResult { var status: Int32; var stdout: String; var stderr: String }

    static func run(_ path: String, _ args: [String]) -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
        } catch {
            return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        p.waitUntilExit()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(status: p.terminationStatus,
                            stdout: String(decoding: outData, as: UTF8.self),
                            stderr: String(decoding: errData, as: UTF8.self))
    }
}
