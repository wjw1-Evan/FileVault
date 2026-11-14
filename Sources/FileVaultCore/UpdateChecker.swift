import Foundation

/// Update offer built from the latest GitHub Release (auto-update, FR-20).
public struct ReleaseInfo: Equatable, Sendable {
    public var version: String       // "1.1.0" (no v prefix)
    public var tagName: String       // "v1.1.0"
    public var notes: String
    public var assetName: String     // "FileVault-1.1.0.zip"
    public var sha256: String?       // asset digest from the API (when present)
    public var assetID: Int64        // GitHub asset id (for authenticated download)
    public var assetSize: Int64      // bytes (for progress)

    public init(version: String, tagName: String, notes: String, assetName: String, sha256: String?,
                assetID: Int64 = 0, assetSize: Int64 = 0) {
        self.version = version
        self.tagName = tagName
        self.notes = notes
        self.assetName = assetName
        self.sha256 = sha256
        self.assetID = assetID
        self.assetSize = assetSize
    }
}

public enum UpdateError: Error, LocalizedError {
    case ghUnavailable
    case noRelease
    case noAsset
    case downloadFailed
    case checksumMismatch
    case notBundled

    public var errorDescription: String? {
        switch self {
        case .ghUnavailable: return "无法查询更新（gh CLI 不可用或网络受限）"
        case .noRelease: return "未找到可用发布版本"
        case .noAsset: return "发布版本缺少应用资产"
        case .downloadFailed: return "下载更新失败"
        case .checksumMismatch: return "更新包校验失败，已中止安装"
        case .notBundled: return "仅 .app 包内运行时支持自动更新"
        }
    }
}

/// Source of release metadata (injectable for tests).
public protocol ReleaseFetching: Sendable {
    func latest() async throws -> ReleaseInfo
}

/// Fetches the latest release via the authenticated `gh` CLI (works for
/// private repos; the user's own machine always has gh when needed).
public struct GhReleaseFetcher: ReleaseFetching {
    public let repo: String
    public init(repo: String = "wjw1-Evan/FileVault") {
        self.repo = repo
    }

    public func latest() async throws -> ReleaseInfo {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/gh")
        if !FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/gh") {
            proc.executableURL = URL(fileURLWithPath: "/usr/local/bin/gh")
        }
        proc.arguments = ["api", "repos/\(repo)/releases/latest"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            throw UpdateError.ghUnavailable
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw UpdateError.noRelease }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return try Self.parseRelease(data)
    }

    /// Parse the GitHub releases/latest JSON payload (extracted for tests).
    public static func parseRelease(_ data: Data) throws -> ReleaseInfo {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else {
            throw UpdateError.noRelease
        }
        let assets = (obj["assets"] as? [[String: Any]]) ?? []
        let asset = assets.first { (($0["name"] as? String)?.hasSuffix(".zip") ?? false) }
        guard let name = asset?["name"] as? String else { throw UpdateError.noAsset }
        let notes = (obj["body"] as? String) ?? ""
        let digest = asset?["digest"] as? String
        let assetID = (asset?["id"] as? NSNumber)?.int64Value ?? 0
        let assetSize = (asset?["size"] as? NSNumber)?.int64Value ?? 0
        return ReleaseInfo(
            version: Self.version(fromTag: tag),
            tagName: tag,
            notes: notes,
            assetName: name,
            sha256: digest?.hasPrefix("sha256:") == true ? String(digest!.dropFirst(7)) : digest,
            assetID: assetID,
            assetSize: assetSize
        )
    }

    /// "v1.2.3" -> "1.2.3"
    public static func version(fromTag tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Semantic-ish comparison: -1 older, 0 equal, 1 newer.
    public static func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x < y { return -1 }
            if x > y { return 1 }
        }
        return 0
    }
}

/// Decides whether an update is available (FR-20).
public struct UpdateChecker: Sendable {
    public let currentVersion: String
    public let fetcher: ReleaseFetching

    public init(currentVersion: String, fetcher: ReleaseFetching) {
        self.currentVersion = currentVersion
        self.fetcher = fetcher
    }

    /// Returns the newer ReleaseInfo, or nil when up to date.
    public func check() async throws -> ReleaseInfo? {
        let latest = try await fetcher.latest()
        return GhReleaseFetcher.compare(latest.version, currentVersion) > 0 ? latest : nil
    }
}
