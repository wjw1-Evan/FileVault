import Foundation

/// Update offer built from the latest GitHub Release (auto-update, FR-20).
public struct ReleaseInfo: Equatable, Sendable {
    public var version: String       // "1.1.0" (no v prefix)
    public var tagName: String       // "v1.1.0"
    public var notes: String
    public var assetName: String     // "FileVault-1.1.0.zip"
    public var sha256: String?       // asset digest from the API (when present)
    public var assetID: Int64        // GitHub asset id
    public var assetSize: Int64      // bytes (for progress)
    public var assetURL: String      // browser_download_url (public repos: no auth needed)

    public init(version: String, tagName: String, notes: String, assetName: String, sha256: String?,
                assetID: Int64 = 0, assetSize: Int64 = 0, assetURL: String = "") {
        self.version = version
        self.tagName = tagName
        self.notes = notes
        self.assetName = assetName
        self.sha256 = sha256
        self.assetID = assetID
        self.assetSize = assetSize
        self.assetURL = assetURL
    }
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case noRelease
    case noAsset
    case downloadFailed
    case checksumMismatch
    case notBundled
    /// The extracted bundle failed the code-signature / identity check (v3.3.0).
    case signatureRejected(String)

    public static func == (lhs: UpdateError, rhs: UpdateError) -> Bool {
        switch (lhs, rhs) {
        case (.noRelease, .noRelease), (.noAsset, .noAsset), (.downloadFailed, .downloadFailed),
             (.checksumMismatch, .checksumMismatch), (.notBundled, .notBundled):
            return true
        case (.signatureRejected(let a), .signatureRejected(let b)):
            return a == b
        default:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noRelease: return "未找到可用发布版本（网络不可达或 GitHub 受限）"
        case .noAsset: return "发布版本缺少应用资产"
        case .downloadFailed: return "下载更新失败"
        case .checksumMismatch: return "更新包校验失败，已中止安装"
        case .notBundled: return "仅 .app 包内运行时支持自动更新"
        case .signatureRejected(let detail): return "更新包签名校验未通过：\(detail)"
        }
    }
}

/// Source of release metadata (injectable for tests).
public protocol ReleaseFetching: Sendable {
    func latest() async throws -> ReleaseInfo
}

/// Fetches the latest release over plain HTTPS from the public GitHub API.
/// No `gh` CLI dependency: the repo is public, so neither the metadata call
/// nor the asset download needs authentication — a normal user's Mac must be
/// able to self-update with nothing installed but FileVault itself
/// (v2.6.4: the old gh-based fetcher silently killed updates on machines
/// without an authenticated Homebrew gh).
public struct HttpReleaseFetcher: ReleaseFetching {
    public let repo: String
    public init(repo: String = "wjw1-Evan/FileVault") {
        self.repo = repo
    }

    public func latest() async throws -> ReleaseInfo {
        // 3 attempts with backoff: api.github.com is intermittently unreachable
        // on some networks (CN especially) — a single-shot check silently
        // starved updates for machines that only occasionally connect.
        var lastError: Error = UpdateError.noRelease
        for attempt in 1...3 {
            do {
                return try await fetchLatest()
            } catch {
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                }
            }
        }
        throw lastError
    }

    private func fetchLatest() async throws -> ReleaseInfo {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateError.noRelease
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("FileVaultApp", forHTTPHeaderField: "User-Agent") // GitHub API requires a UA
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.noRelease
        }
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
        let assetURL = (asset?["browser_download_url"] as? String) ?? ""
        return ReleaseInfo(
            version: Self.version(fromTag: tag),
            tagName: tag,
            notes: notes,
            assetName: name,
            sha256: digest?.hasPrefix("sha256:") == true ? String(digest!.dropFirst(7)) : digest,
            assetID: assetID,
            assetSize: assetSize,
            assetURL: assetURL
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
        return HttpReleaseFetcher.compare(latest.version, currentVersion) > 0 ? latest : nil
    }
}
