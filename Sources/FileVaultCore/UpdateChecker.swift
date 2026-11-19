import Foundation

/// Update offer built from the latest GitHub Release (auto-update, FR-20).
public struct ReleaseInfo: Equatable, Sendable {
    public var version: String       // "1.1.0" (no v prefix)
    public var tagName: String       // "v1.1.0"
    public var notes: String
    public var assetName: String     // "Pastward-1.1.0.zip"（v4.2.31 前为 FileVault-*.zip；更新器按版本号匹配，不依赖资产名前缀）
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
    /// GitHub API 403/429: quota exhausted, not "no release" (v4.2.27).
    case rateLimited
    case downloadFailed
    /// Transport-level failure while downloading: carries the underlying
    /// message (e.g. URLError.localizedDescription) so a user can tell a
    /// missing network / proxy from a corrupt package (v4.2.26).
    case downloadTransport(String)
    /// The asset host answered with a non-2xx HTTP status (v4.2.26).
    case httpStatus(Int)
    case checksumMismatch
    /// The release has no usable sha256 digest. Installing unverified bytes is
    /// fail-open, so we abort instead (v4.2.26).
    case missingChecksum
    case notBundled
    /// Extracting the downloaded zip failed (disk full, corrupt archive, …):
    /// this is not a download failure (v4.2.26).
    case extractFailed(String)
    /// The extracted bundle failed the code-signature / identity check (v3.3.0).
    case signatureRejected(String)
    /// Rotating the running bundle aside failed (permissions, read-only volume).
    case installFailed(String)

    public static func == (lhs: UpdateError, rhs: UpdateError) -> Bool {
        switch (lhs, rhs) {
        case (.noRelease, .noRelease), (.noAsset, .noAsset), (.rateLimited, .rateLimited),
         (.downloadFailed, .downloadFailed),
             (.checksumMismatch, .checksumMismatch), (.missingChecksum, .missingChecksum),
             (.notBundled, .notBundled):
            return true
        case (.downloadTransport(let a), .downloadTransport(let b)):
            return a == b
        case (.httpStatus(let a), .httpStatus(let b)):
            return a == b
        case (.extractFailed(let a), .extractFailed(let b)):
            return a == b
        case (.signatureRejected(let a), .signatureRejected(let b)):
            return a == b
        case (.installFailed(let a), .installFailed(let b)):
            return a == b
        default:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noRelease:
            return NSLocalizedString("未找到可用发布版本（网络不可达或 GitHub 受限）", comment: "update error")
        case .noAsset:
            return NSLocalizedString("发布版本缺少应用资产", comment: "update error")
        case .rateLimited:
            return NSLocalizedString("GitHub 访问受限（限流），将在后台自动重试", comment: "update error")
        case .downloadFailed:
            return NSLocalizedString("下载更新失败", comment: "update error")
        case .downloadTransport(let detail):
            return String(format: NSLocalizedString("下载更新失败：%@", comment: "update error"), detail)
        case .httpStatus(let status):
            return String(format: NSLocalizedString("下载更新失败：服务器返回 HTTP %d", comment: "update error"), status)
        case .checksumMismatch:
            return NSLocalizedString("更新包校验失败，已中止安装", comment: "update error")
        case .missingChecksum:
            return NSLocalizedString("更新包缺少 sha256 校验信息，已中止安装（可从 GitHub 手动下载安装）",
                                     comment: "update error")
        case .notBundled:
            return NSLocalizedString("仅 .app 包内运行时支持自动更新", comment: "update error")
        case .extractFailed(let detail):
            return String(format: NSLocalizedString("更新包解压失败：%@", comment: "update error"), detail)
        case .signatureRejected(let detail):
            return String(format: NSLocalizedString("更新包签名校验未通过：%@", comment: "update error"), detail)
        case .installFailed(let detail):
            return String(format: NSLocalizedString("安装更新失败：%@", comment: "update error"), detail)
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
                // Rate limiting will not recover within seconds: further
                // retries just burn more of the shared quota (v4.2.27).
                if error is UpdateError && (error as? UpdateError) == .rateLimited { break }
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
        guard let http = resp as? HTTPURLResponse else { throw UpdateError.noRelease }
        if http.statusCode == 403 || http.statusCode == 429 {
            // Shared-IP rate limiting is not "no release": retrying burns the
            // quota three more times and the message misled ("未找到可用发布
            // 版本") (v4.2.27).
            throw UpdateError.rateLimited
        }
        guard http.statusCode == 200 else { throw UpdateError.noRelease }
        return try Self.parseRelease(data)
    }

    /// Parse the GitHub releases/latest JSON payload (extracted for tests).
    public static func parseRelease(_ data: Data) throws -> ReleaseInfo {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else {
            throw UpdateError.noRelease
        }
        let assets = (obj["assets"] as? [[String: Any]]) ?? []
        // Pick the asset for THIS release: a stale re-uploaded zip used to win
        // first-match and (self-consistently) pass its own sha256 (v4.2.27).
        // Require the version in the filename when it is present; fall back to
        // the single zip only when nothing matches (tolerates future naming).
        let allZips = assets.filter { entry in
            guard let n = entry["name"] as? String else { return false }
            return n.hasSuffix(".zip") && !n.hasSuffix(".zip.old")
        }
        let ver = Self.version(fromTag: tag)
        let matched = allZips.filter { entry in
            guard let n = entry["name"] as? String else { return false }
            return Self.assetName(n, pinsVersion: ver)
        }
        let asset: [String: Any]
        if matched.count == 1 {
            asset = matched[0]
        } else if matched.count > 1 {
            throw UpdateError.noAsset // ambiguous: refuse rather than guess
        } else if allZips.count == 1 {
            asset = allZips[0]
        } else {
            throw UpdateError.noAsset
        }
        guard let name = asset["name"] as? String else { throw UpdateError.noAsset }
        let notes = (obj["body"] as? String) ?? ""
        let digest = asset["digest"] as? String
        let assetID = (asset["id"] as? NSNumber)?.int64Value ?? 0
        let assetSize = (asset["size"] as? NSNumber)?.int64Value ?? 0
        let assetURL = (asset["browser_download_url"] as? String) ?? ""
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

    /// Whether an asset name carries the release's version as a whole token
    /// (v4.2.31).
    ///
    /// A plain contains() matched prefix neighbours: a release looking for
    /// "4.2.3" also matched "FileVault-4.2.31.zip" — in the stale-re-upload
    /// scenario the version guard exists for (v4.2.27), that false match
    /// turned "pick the right zip" into "ambiguous, refuse to update". The
    /// version must not be flanked by digits on either side.
    static func assetName(_ name: String, pinsVersion ver: String) -> Bool {
        guard !ver.isEmpty else { return false }
        var searchStart = name.startIndex
        while let r = name.range(of: ver, range: searchStart..<name.endIndex) {
            let boundedBefore = r.lowerBound == name.startIndex
                || !name[name.index(before: r.lowerBound)].isNumber
            let boundedAfter = r.upperBound == name.endIndex
                || !name[r.upperBound].isNumber
            if boundedBefore && boundedAfter { return true }
            searchStart = r.upperBound
        }
        return false
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
