import Foundation

/// Streams the update asset with byte-level progress (FR-20 v1.2.2).
/// v2.6.4: direct HTTPS download of the public release asset — no `gh` CLI,
/// no token, no Homebrew paths. Works on any Mac with just FileVault installed.
public enum UpdateDownloader {
    /// Download with progress and retries.
    @discardableResult
    public static func download(info: ReleaseInfo, repo: String = "wjw1-Evan/FileVault",
                                progress: ((Double, Int64, Int64) -> Void)? = nil,
                                attempts: Int = 3) async throws -> URL {
        var lastError: Error = UpdateError.downloadFailed
        for attempt in 1...max(1, attempts) {
            do {
                return try await downloadOnce(info: info, progress: progress)
            } catch {
                lastError = error
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                }
            }
        }
        throw lastError
    }

    /// One download attempt: stream `browser_download_url` to a temp file.
    private static func downloadOnce(info: ReleaseInfo,
                                     progress: ((Double, Int64, Int64) -> Void)?) async throws -> URL {
        guard !info.assetURL.isEmpty, let url = URL(string: info.assetURL) else {
            throw UpdateError.downloadFailed
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("FileVaultApp", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        // Only HTTP responses carry a failure status; non-HTTP schemes (file://,
        // used by tests and offline mirrors) with no transport error are fine.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.downloadFailed
        }
        let total = info.assetSize > 0 ? info.assetSize : response.expectedContentLength
        // The asset name comes from the GitHub API: never let it add path
        // components, and use a fresh file per attempt so a smaller re-upload
        // can never leave tail bytes from an earlier download (sha mismatch
        // forever). (v4.2.25)
        let rawName = (info.assetName as NSString).lastPathComponent
        let name = rawName.isEmpty ? "update.zip" : rawName
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("fv-update-\(UUID().uuidString.prefix(8))-\(name)")
        try? FileManager.default.removeItem(at: dest)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        try handle.truncate(atOffset: 0)
        defer { try? handle.close() }
        var buffer = Data()
        var received: Int64 = 0
        var lastReported = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 {
                    let fraction = Double(received) / Double(total)
                    if fraction - lastReported >= 0.01 {
                        lastReported = fraction
                        progress?(fraction, received, total)
                    }
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        if total > 0, received != total {
            throw UpdateError.downloadFailed
        }
        progress?(1.0, received, total)
        return dest
    }
}
