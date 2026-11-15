import Foundation
import CryptoKit
import Security

// MARK: - License model

/// A signed licence token issued by the vendor.
///
/// Tokens are offline-verifiable: Ed25519 signature over the payload, checked
/// with the public key baked into the app. No licence server is required to
/// unlock the app, which keeps activation working behind corporate proxies and
/// on machines that never reach the vendor's backend.
public struct License: Codable, Equatable, Sendable {
    public var v: Int
    public var id: String
    public var email: String
    public var plan: String          // "pro"
    public var issuedAt: String      // yyyy-MM-dd
    public var expiresAt: String?    // nil = perpetual

    public init(v: Int = 1, id: String, email: String, plan: String = "pro",
                issuedAt: String, expiresAt: String? = nil) {
        self.v = v
        self.id = id
        self.email = email
        self.plan = plan
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    /// Perpetual licences never expire; dated ones expire at 00:00 UTC of the day.
    public func isExpired(now: Date) -> Bool {
        guard let expiresAt, let expiry = Self.dayFormatter.date(from: expiresAt) else { return false }
        return now >= expiry.addingTimeInterval(24 * 3600)
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

public enum LicenseError: Error, LocalizedError, Equatable {
    case malformed
    case unsupportedVersion(Int)
    case badSignature
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .malformed: return "激活码格式不正确，请检查是否完整复制"
        case .unsupportedVersion(let v): return "激活码版本过新（v\(v)），请升级应用后再试"
        case .badSignature: return "激活码无效（签名校验失败）"
        case .invalidPayload: return "激活码内容损坏"
        }
    }
}

// MARK: - Token codec

public enum LicenseToken {
    /// Public key used to verify production licences (Ed25519, raw 32 bytes,
    /// base64). The matching private key never ships with the app — it lives
    /// with the vendor's release tooling only.
    public static let productionPublicKey = "o+AcYVq1GhZmoDP7SgjevXIyImRHdEPVeYW8q7qxxQw="

    /// "fv1.<payload>.<signature>" — payload/signature are base64url (RFC 4648).
    public static func verify(_ token: String,
                              publicKeyBase64: String = productionPublicKey,
                              now: Date = Date()) throws -> License {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 3, parts[0] == "fv1" else { throw LicenseError.malformed }
        guard let payload = base64URLDecode(String(parts[1])) else { throw LicenseError.malformed }
        guard let sigData = base64URLDecode(String(parts[2])) else { throw LicenseError.malformed }
        guard let keyData = Data(base64Encoded: publicKeyBase64) else { throw LicenseError.badSignature }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw LicenseError.badSignature
        }
        guard key.isValidSignature(sigData, for: payload) else { throw LicenseError.badSignature }
        guard let license = try? JSONDecoder().decode(License.self, from: payload) else {
            throw LicenseError.invalidPayload
        }
        guard license.v == 1 else { throw LicenseError.unsupportedVersion(license.v) }
        return license
    }

    /// Test/vendor-side helper: build a signed token (not used by the app at runtime).
    public static func sign(_ license: License, privateKeyBase64: String) throws -> String {
        guard let keyData = Data(base64Encoded: privateKeyBase64),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
            throw LicenseError.badSignature
        }
        let payload = try JSONEncoder().encode(license)
        let sig = try key.signature(for: payload)
        return "fv1.\(base64URLEncode(payload)).\(base64URLEncode(sig))"
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

// MARK: - Storage

/// Minimal key/value seam so trial + licence state survive launches and are
/// testable without touching the user's real keychain.
public protocol LicenseStorage: AnyObject, Sendable {
    func string(forKey key: String) -> String?
    func setString(_ value: String?, forKey key: String)
}

/// Process-local storage (unit tests, and the safe default for embedders).
public final class InMemoryLicenseStorage: LicenseStorage, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }
    public func setString(_ value: String?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        if let value { values[key] = value } else { values[key] = nil }
    }
}

/// Keychain-backed storage: trial start and activation survive reinstalls of
/// the app bundle and are not editable from a text file.
public final class KeychainLicenseStorage: LicenseStorage, @unchecked Sendable {
    private let service: String
    public init(service: String = AppBrand.bundleIdentifier + ".license") {
        self.service = service
    }

    public func string(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setString(_ value: String?, forKey key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }
}

// MARK: - Manager

/// Trial + licence state machine.
///
/// Lifecycle: first launch starts a 14-day trial (recorded in the keychain).
/// A valid licence token always wins; after trial expiry the app keeps working
/// for viewing/restoring history but stops creating new automatic commits until
/// the user activates a licence.
public enum LicenseState: Equatable, Sendable {
    case trial(daysRemaining: Int)
    case licensed(License)
    case expired

    /// Whether automated version management (auto commit / auto push) may run.
    public var allowsAutomation: Bool {
        if case .expired = self { return false }
        return true
    }

    public var isLicensed: Bool {
        if case .licensed = self { return true }
        return false
    }
}

public final class LicenseManager: @unchecked Sendable {
    public static let trialStartKey = "trialStart"
    public static let tokenKey = "licenseToken"

    private let storage: LicenseStorage
    private let now: @Sendable () -> Date
    private let publicKeyBase64: String
    private let lock = NSLock()
    private var cached: LicenseState?

    public init(storage: LicenseStorage,
                now: @escaping @Sendable () -> Date = Date.init,
                publicKeyBase64: String = LicenseToken.productionPublicKey) {
        self.storage = storage
        self.now = now
        self.publicKeyBase64 = publicKeyBase64
    }

    /// Current state (cached after first resolution).
    public var state: LicenseState {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let s = resolve()
        cached = s
        return s
    }

    @discardableResult
    public func refresh() -> LicenseState {
        lock.lock()
        let s = resolve()
        cached = s
        lock.unlock()
        return s
    }

    /// Validate and persist a licence token; throws on invalid input.
    @discardableResult
    public func activate(_ token: String) throws -> LicenseState {
        let license = try LicenseToken.verify(token, publicKeyBase64: publicKeyBase64, now: now())
        guard !license.isExpired(now: now()) else { throw LicenseError.badSignature }
        storage.setString(token.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.tokenKey)
        return refresh()
    }

    @discardableResult
    public func deactivate() -> LicenseState {
        storage.setString(nil, forKey: Self.tokenKey)
        return refresh()
    }

    /// Trial start date, if any (exposed for diagnostics).
    public var trialStart: Date? {
        guard let raw = storage.string(forKey: Self.trialStartKey) else { return nil }
        return Self.dayFormatter.date(from: raw)
    }

    private func resolve() -> LicenseState {
        // 1. A valid licence always wins.
        if let token = storage.string(forKey: Self.tokenKey),
           let license = try? LicenseToken.verify(token, publicKeyBase64: publicKeyBase64, now: now()),
           !license.isExpired(now: now()) {
            return .licensed(license)
        }
        // 2. Otherwise the trial clock runs from the first launch.
        let start: Date
        if let raw = storage.string(forKey: Self.trialStartKey),
           let parsed = Self.dayFormatter.date(from: raw) {
            start = parsed
        } else {
            let today = now()
            storage.setString(Self.dayFormatter.string(from: today), forKey: Self.trialStartKey)
            start = Self.calendar.startOfDay(for: today)
        }
        let elapsedDays = Self.calendar.dateComponents([.day], from: Self.calendar.startOfDay(for: start),
                                                       to: Self.calendar.startOfDay(for: now())).day ?? 0
        let remaining = AppBrand.trialDays - elapsedDays
        if remaining <= 0 { return .expired }
        return .trial(daysRemaining: remaining)
    }

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
