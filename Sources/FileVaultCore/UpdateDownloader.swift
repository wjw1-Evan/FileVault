import Foundation

/// Streams the update asset with byte-level progress (FR-20 v1.2.2).
public enum UpdateDownloader {
    /// The user's gh auth token (private repo access). Nil when gh is absent.
    public static func ghToken() -> String? {
        let p = Process()
        p.executableURL = SelfUpdater.ghURL()
        p.arguments = ["auth", "token"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return nil
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Download with progress: URLSession + gh token. Falls back to gh CLI when
    /// no token is available (progress unavailable on that path).
    @discardableResult
    public static func download(info: ReleaseInfo, repo: String = "wjw1-Evan/FileVault",
                                progress: ((Double, Int64, Int64) -> Void)? = nil,
                                attempts: Int = 3) async throws -> URL {
        var lastError: Error = UpdateError.downloadFailed
        for attempt in 1...max(1, attempts) {
            do {
                return try await downloadOnce(info: info, repo: repo, progress: progress)
            } catch {
                lastError = error
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                }
            }
        }
        throw lastError
    }

    /// One download attempt (URLSession with gh token; CLI fallback).
    private static func downloadOnce(info: ReleaseInfo, repo: String,
                                     progress: ((Double, Int64, Int64) -> Void)?) async throws -> URL {
        guard let token = ghToken(), info.assetID > 0 else {
            return try await SelfUpdater.download(info: info, into: FileManager.default.temporaryDirectory.appendingPathComponent("fv-update-cli"), repo: repo)
        }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/assets/\(info.assetID)")!)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
        let total = info.assetSize > 0 ? info.assetSize : response.expectedContentLength
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("fv-update-\(info.assetName)")
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
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
