import Foundation

/// Downloads the update asset with progress and an overall time budget
/// (FR-20 v1.2.2; v4.2.32 moved from per-byte AsyncBytes iteration — which
/// measured ≈195 KB/s — to URLSession.download at full line speed).
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
                // Normalise so the retry ranking always compares UpdateErrors.
                lastError = Self.moreSpecific(Self.transportError(error), than: lastError)
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                }
            }
        }
        throw lastError
    }

    /// Keep the most diagnosable failure across retries: an HTTP status or a
    /// transport message beats the generic `.downloadFailed` (v4.2.26). The old
    /// code just kept the last attempt's error, which was often the generic one,
    /// so users could not tell "no network / proxy" from "bad package".
    static func moreSpecific(_ candidate: Error, than current: Error) -> Error {
        func rank(_ error: Error) -> Int {
            guard let updateError = error as? UpdateError else { return 0 }
            switch updateError {
            case .httpStatus: return 3
            case .downloadTransport, .checksumMismatch, .missingChecksum: return 2
            case .downloadFailed: return 0
            default: return 1
            }
        }
        return rank(candidate) >= rank(current) ? candidate : current
    }

    /// Overall budget for one download attempt. A stalled-but-open
    /// connection never tripped the 60 s request timeout (which is idle-
    /// based), so a trickling mirror held the update flow hostage forever
    /// (v4.2.32). Injectable for tests.
    public static var downloadTimeLimit: TimeInterval = 600

    /// One download attempt: `browser_download_url` via URLSession.download
    /// with progress polled from task.progress and an overall time budget.
    ///
    /// v4.2.32: this used to iterate `AsyncBytes` BYTE BY BYTE — measured
    /// 20 MB ≈ 103 s of pure per-byte await overhead (≈195 KB/s), so a 22 MB
    /// release took minutes on a fast line. URLSession.download streams
    /// internally at full speed; progress comes from the task's Progress
    /// (unit count 100 = percent).
    private static func downloadOnce(info: ReleaseInfo,
                                     progress: ((Double, Int64, Int64) -> Void)?) async throws -> URL {
        guard !info.assetURL.isEmpty, let url = URL(string: info.assetURL) else {
            throw UpdateError.downloadFailed
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("FileVaultApp", forHTTPHeaderField: "User-Agent")
        // The asset name comes from the GitHub API: never let it add path
        // components, and use a fresh file per attempt so a smaller re-upload
        // can never leave tail bytes from an earlier download (sha mismatch
        // forever). (v4.2.25)
        let rawName = (info.assetName as NSString).lastPathComponent
        let name = rawName.isEmpty ? "update.zip" : rawName
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("fv-update-\(UUID().uuidString.prefix(8))-\(name)")
        try? FileManager.default.removeItem(at: dest)

        let deadline = Date().addingTimeInterval(max(1, downloadTimeLimit))
        // One task for both progress polling and completion: the handler-
        // based downloadTask still exposes .progress (unit count 100).
        // DownloadBridge turns the one-shot completion handler into an
        // awaitable continuation (v4.2.32).
        let bridge = DownloadBridge()
        let task = URLSession.shared.downloadTask(with: req) { url, resp, error in
            bridge.complete(url: url, response: resp, error: error)
        }
        let monitor = Task {
            var lastFraction = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let p = task.progress
                let fraction = p.totalUnitCount > 0
                    ? Double(p.completedUnitCount) / Double(p.totalUnitCount)
                    : 0
                if fraction - lastFraction >= 0.01 {
                    lastFraction = fraction
                    let total = info.assetSize > 0 ? info.assetSize : 0
                    progress?(min(fraction, 0.999), Int64(fraction * Double(max(total, 0))), total)
                }
                if Date() > deadline { task.cancel(); return }
            }
        }
        defer { monitor.cancel() }
        do {
            let (fileURL, response) = try await bridge.waitForCompletion(task: task)
            // Only HTTP responses carry a failure status; non-HTTP schemes (file://,
            // used by tests and offline mirrors) with no transport error are fine.
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: fileURL)
                throw UpdateError.httpStatus(http.statusCode)
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let received = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let expected = info.assetSize > 0
                ? info.assetSize
                : response.expectedContentLength
            if expected > 0, received != expected {
                try? FileManager.default.removeItem(at: fileURL)
                throw UpdateError.downloadFailed
            }
            // Move into the fresh per-attempt path (a same-name collision
            // would fail the move; remove first as before).
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            do {
                try FileManager.default.moveItem(at: fileURL, to: dest)
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                throw UpdateError.downloadTransport(error.localizedDescription)
            }
            let total = info.assetSize > 0 ? info.assetSize : received
            progress?(1.0, received, total)
            return dest
        } catch {
            task.cancel()
            throw Self.transportError(error)
        }
    }

    /// Bridges a one-shot URLSession completion handler into an awaitable
    /// continuation. Kept as a class so the handler closure and the waiter
    /// share the resume state (v4.2.32).
    private final class DownloadBridge: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        private var result: Result<(URL, URLResponse), Error>?

        func complete(url: URL?, response: URLResponse?, error: Error?) {
            lock.lock()
            // Cancellation arrives as an error through the same handler.
            let r: Result<(URL, URLResponse), Error>
            if let error {
                r = .failure(error)
            } else if let url, let response {
                r = .success((url, response))
            } else {
                r = .failure(UpdateError.downloadFailed)
            }
            if let cont = continuation {
                continuation = nil
                lock.unlock()
                cont.resume(with: r)
            } else {
                result = r
                lock.unlock()
            }
        }

        func waitForCompletion(task: URLSessionTask) async throws -> (URL, URLResponse) {
            task.resume()
            return try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if let r = result {
                    result = nil
                    lock.unlock()
                    cont.resume(with: r)
                } else {
                    continuation = cont
                    lock.unlock()
                }
            }
        }
    }

    /// Map a thrown error to the most readable download error.
    static func transportError(_ error: Error) -> UpdateError {
        if let updateError = error as? UpdateError { return updateError }
        return UpdateError.downloadTransport(error.localizedDescription)
    }
}
