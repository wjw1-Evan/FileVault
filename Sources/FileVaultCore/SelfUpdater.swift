import Foundation
import CryptoKit

/// Downloads, verifies and installs an update bundle (FR-20).
/// The replace routine takes explicit paths so it is fully unit-testable.
public enum SelfUpdater {
    /// Download the release asset into a directory via `gh release download`.
    @discardableResult
    public static func download(info: ReleaseInfo, into dir: URL, repo: String = "wjw1-Evan/FileVault") async throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = ghURL()
        proc.arguments = ["release", "download", info.tagName, "--repo", repo, "--pattern", info.assetName, "--output-dir", dir.path, "--clobber"]
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            throw UpdateError.downloadFailed
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            _ = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw UpdateError.downloadFailed
        }
        let file = dir.appendingPathComponent(info.assetName)
        guard FileManager.default.fileExists(atPath: file.path) else { throw UpdateError.downloadFailed }
        return file
    }

    /// Verify sha256 of the downloaded zip against the release digest.
    public static func verify(zipURL: URL, expectedSHA256: String?) throws {
        guard let expectedSHA256, !expectedSHA256.isEmpty else { return }
        guard let data = try? Data(contentsOf: zipURL) else { throw UpdateError.downloadFailed }
        let digest = Self.sha256(data)
        guard digest == expectedSHA256.lowercased() else { throw UpdateError.checksumMismatch }
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Atomically replace the bundle at `bundleURL` with the app inside
    /// `newZipURL`, then relaunch. Old bundle kept as <name>.old for rollback.
    public static func replace(bundleURL: URL, newZipURL: URL, relaunch: Bool = true) throws {
        let fm = FileManager.default
        guard bundleURL.pathExtension == "app" else { throw UpdateError.notBundled }
        let parent = bundleURL.deletingLastPathComponent()
        let tmpExtract = parent.appendingPathComponent("fv-update-\(UUID().uuidString.prefix(6))")
        // 1. Extract (ditto preserves signatures/permissions).
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", newZipURL.path, tmpExtract.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw UpdateError.downloadFailed }
        // 2. Locate the new .app inside the extraction.
        let entries = (try? fm.contentsOfDirectory(atPath: tmpExtract.path)) ?? []
        guard let appName = entries.first(where: { $0.hasSuffix(".app") }),
              fm.fileExists(atPath: tmpExtract.appendingPathComponent(appName).appendingPathComponent("Contents/MacOS").path) else {
            try? fm.removeItem(at: tmpExtract)
            throw UpdateError.downloadFailed
        }
        let newApp = tmpExtract.appendingPathComponent(appName)
        // 3. Rotate: current -> .old, new -> current, relaunch, cleanup.
        let oldURL = parent.appendingPathComponent(bundleURL.lastPathComponent + ".old")
        try? fm.removeItem(at: oldURL)
        _ = try? fm.moveItem(at: bundleURL, to: oldURL)
        do {
            _ = try fm.moveItem(at: newApp, to: bundleURL)
        } catch {
            // Roll back on failure.
            _ = try? fm.moveItem(at: oldURL, to: bundleURL)
            try? fm.removeItem(at: tmpExtract)
            throw UpdateError.downloadFailed
        }
        try? fm.removeItem(at: tmpExtract)
        if relaunch {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [bundleURL.path]
            try? open.run()
        }
        // Schedule .old cleanup on next successful start via marker? Keep .old for manual rollback.
    }

    static func ghURL() -> URL {
        for p in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] {
            if FileManager.default.isExecutableFile(atPath: p) {
                return URL(fileURLWithPath: p)
            }
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }
}
