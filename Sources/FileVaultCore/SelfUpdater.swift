import Foundation
import CryptoKit

/// Verifies and installs an update bundle (FR-20).
/// The replace routine takes explicit paths so it is fully unit-testable.
public enum SelfUpdater {
    /// Verify sha256 of the downloaded zip against the release digest.
    ///
    /// Fail closed: a release without a usable digest must not install
    /// unverified bytes. The only remaining gate would be codesign, and ad-hoc
    /// releases accept any ad-hoc bundle with the same identifier, so a
    /// missing digest used to silently disable integrity checking (v4.2.26).
    public static func verify(zipURL: URL, expectedSHA256: String?) throws {
        let expected = expectedSHA256?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !expected.isEmpty else { throw UpdateError.missingChecksum }
        guard let data = try? Data(contentsOf: zipURL) else { throw UpdateError.downloadFailed }
        let digest = Self.sha256(data)
        guard digest == expected.lowercased() else { throw UpdateError.checksumMismatch }
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Atomically replace the bundle at `bundleURL` with the app inside
    /// `newZipURL`, then relaunch. Old bundle kept as <name>.old for rollback.
    ///
    /// `verifySignature` (default true) checks the extracted bundle's
    /// code signature and identifier before it is allowed to replace the
    /// running app (v3.3.0). Tests that fabricate unsigned bundles pass false.
    public static func replace(bundleURL: URL, newZipURL: URL, relaunch: Bool = true,
                               verifySignature: Bool = true) throws {
        let fm = FileManager.default
        guard bundleURL.pathExtension == "app" else { throw UpdateError.notBundled }
        let parent = bundleURL.deletingLastPathComponent()
        sweepOrphanStagingDirs(in: parent)
        let tmpExtract = parent.appendingPathComponent("fv-update-\(UUID().uuidString.prefix(6))")
        // 1. Extract (ditto preserves signatures/permissions).
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", newZipURL.path, tmpExtract.path]
        unzip.standardOutput = FileHandle.nullDevice
        // Capture stderr so extract failures carry the real reason (disk full,
        // corrupt archive) instead of a bare exit status (v4.2.27).
        let errPipe = Pipe()
        unzip.standardError = errPipe
        do {
            try unzip.run()
        } catch {
            try? fm.removeItem(at: tmpExtract)
            throw UpdateError.extractFailed(error.localizedDescription)
        }
        unzip.waitUntilExit()
        // A failed extraction is not a download failure: surfacing it as one
        // told users to retry the network when the real cause was a corrupt
        // archive or a full disk (v4.2.26).
        guard unzip.terminationStatus == 0 else {
            try? fm.removeItem(at: tmpExtract)
            let detail = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = (detail?.isEmpty == false) ? (detail! + " ") : ""
            throw UpdateError.extractFailed(reason + "ditto exited with status \(unzip.terminationStatus) while extracting \(newZipURL.lastPathComponent)")
        }
        guard fm.fileExists(atPath: tmpExtract.path) else {
            try? fm.removeItem(at: tmpExtract)
            throw UpdateError.extractFailed("extraction directory was not created")
        }
        // 2. Locate the new .app inside the extraction.
        let entries = (try? fm.contentsOfDirectory(atPath: tmpExtract.path)) ?? []
        guard let appName = entries.first(where: { $0.hasSuffix(".app") }),
              fm.fileExists(atPath: tmpExtract.appendingPathComponent(appName).appendingPathComponent("Contents/MacOS").path) else {
            try? fm.removeItem(at: tmpExtract)
            throw UpdateError.extractFailed("no runnable .app inside \(newZipURL.lastPathComponent)")
        }
        let newApp = tmpExtract.appendingPathComponent(appName)
        // 2.5 Code-signature check: the GitHub digest proves integrity against
        // that API, not authorship. Once releases are Developer-ID signed this
        // pins the update to the vendor's team.
        if verifySignature {
            do {
                try UpdateSignature.verify(newBundle: newApp, referenceBundle: bundleURL)
            } catch {
                try? fm.removeItem(at: tmpExtract)
                throw UpdateError.signatureRejected(error.localizedDescription)
            }
        }
        // 3. Rotate: current -> .old, new -> current, relaunch, cleanup.
        let oldURL = parent.appendingPathComponent(bundleURL.lastPathComponent + ".old")
        try? fm.removeItem(at: oldURL)
        // Fail loudly if the running bundle cannot be moved aside (read-only
        // volume, sandbox, missing permission): the old code ignored the error
        // and then failed with a generic "download failed".
        do {
            try fm.moveItem(at: bundleURL, to: oldURL)
        } catch {
            try? fm.removeItem(at: tmpExtract)
            throw UpdateError.installFailed(error.localizedDescription)
        }
        do {
            _ = try fm.moveItem(at: newApp, to: bundleURL)
        } catch {
            // Roll back on failure. Moving the new package into place is an
            // install failure (permissions, read-only volume), not a download
            // failure; the old generic message sent users to retry the
            // network (v4.2.26).
            _ = try? fm.moveItem(at: oldURL, to: bundleURL)
            try? fm.removeItem(at: tmpExtract)
            throw UpdateError.installFailed(error.localizedDescription)
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

    /// Remove `fv-update-*` staging directories left behind by a killed
    /// process (power loss during extract/replace): each holds a whole
    /// extracted bundle in /Applications (v4.2.27).
    public static func sweepOrphanStagingDirs(in parent: URL, olderThan: TimeInterval = 86_400) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in entries where name.hasPrefix("fv-update-") {
            let full = parent.appendingPathComponent(name).path
            let attrs = try? fm.attributesOfItem(atPath: full)
            let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
            guard Date().timeIntervalSince(mtime) > olderThan else { continue }
            try? fm.removeItem(atPath: full)
        }
    }

    /// Quote a path for shell embedding (relaunch helper runs via /bin/sh).
    public static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
