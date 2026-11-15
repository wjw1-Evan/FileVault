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
        public var previousVersion: String
        public var newVersion: String
        public var attempts: Int
        public var startedAt: Date

        public init(previousVersion: String, newVersion: String, attempts: Int = 0, startedAt: Date = Date()) {
            self.previousVersion = previousVersion
            self.newVersion = newVersion
            self.attempts = attempts
            self.startedAt = startedAt
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
    public static func beginUpdate(configDirectory: URL, previousVersion: String, newVersion: String) {
        let marker = Marker(previousVersion: previousVersion, newVersion: newVersion, attempts: 0)
        write(marker, configDirectory: configDirectory)
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

    static func write(_ marker: Marker, configDirectory: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(marker) else { return }
        try? data.write(to: markerURL(configDirectory: configDirectory), options: .atomic)
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
            case .missingInfoPlist: return "更新包缺少 Info.plist"
            case .invalidSignature(let detail): return "更新包签名校验失败：\(detail)"
            case .wrongIdentifier(let expected, let got): return "更新包不是本应用（\(got) ≠ \(expected)）"
            case .teamChanged(let current, let new): return "更新包签名团队不一致（\(new ?? "无") ≠ \(current ?? "无")）"
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
        guard info.signatureValid else { throw Failure.invalidSignature("codesign --verify 未通过") }
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
