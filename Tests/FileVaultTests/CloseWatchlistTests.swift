
import XCTest
@testable import FileVaultCore

/// v4.2.32 watchlist closure round: each test pins one adjudicated item —
/// fixed, or falsified with evidence (falsification is documented in the
/// test comments so the suspicion is not re-litigated later).
final class CloseWatchlistTests: XCTestCase {

    // MARK: - Item 1: shared date formatters

    /// A huge recovery scan used to spend ~0.13 ms per record building two
    /// formatters (≈397 ms for 3,000 commits). The parsers are now shared;
    /// this pins correctness across many sequential parses (format results
    /// stay identical — no behavioral change intended).
    func testParseGitDateStableAcrossManyRecords() {
        // ISO with timezone: the format git's %aI produces.
        let iso = "2026-11-19T12:34:56+08:00"
        let first = HistoryService.parseGitDate(iso)
        for _ in 0..<3_000 {
            XCTAssertEqual(HistoryService.parseGitDate(iso)?.timeIntervalSince1970,
                           first?.timeIntervalSince1970)
        }
        // Fallback format ("yyyy-MM-dd HH:mm:ss Z") also round-trips.
        XCTAssertNotNil(HistoryService.parseGitDate("2026-11-19 12:34:56 +0800"))
        XCTAssertNil(HistoryService.parseGitDate("not a date"))
    }

    // MARK: - Item 2: SelfUpdater edges

    private func makeAppShell(_ dir: URL) throws -> URL {
        let app = dir.appendingPathComponent("FileVault.app")
        try FileManager.default.createDirectory(
            atPath: app.appendingPathComponent("Contents/MacOS").path,
            withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(
            to: app.appendingPathComponent("Contents/MacOS/FileVaultApp"))
        return app
    }

    /// Zip an .app bundle so the archive's ROOT is the .app itself
    /// (SelfUpdater.locateApp scans only the extraction root).
    private func zipAppBundle(_ app: URL, to zip: URL) throws {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run(); ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0, "fixture zip creation failed")
    }

    /// signatureRejected: a bundle whose identifier differs from the running
    /// app must be refused BEFORE any rotation happens (verifySignature: true
    /// against a reference shell with a different identifier).
    func testReplaceRejectsWrongIdentifierBeforeRotation() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("cw-sig"))
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let app = try makeAppShell(dir)
        let info = dir.appendingPathComponent("FileVault.app/Contents/Info.plist")
        let plist = ["CFBundleIdentifier": "com.example.other"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: info)

        let newStage = dir.appendingPathComponent("stage")
        let newAppPath = newStage.appendingPathComponent("FileVault.app")
        try FileManager.default.createDirectory(
            atPath: newAppPath.appendingPathComponent("Contents/MacOS").path,
            withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(
            to: newAppPath.appendingPathComponent("Contents/MacOS/FileVaultApp"))
        let newPlist = ["CFBundleIdentifier": "com.example.different"]
        try PropertyListSerialization.data(fromPropertyList: newPlist, format: .xml, options: 0)
            .write(to: newAppPath.appendingPathComponent("Contents/Info.plist"))
        try zipAppBundle(newAppPath, to: dir.appendingPathComponent("new.zip"))

        XCTAssertThrowsError(try SelfUpdater.replace(
            bundleURL: app, newZipURL: dir.appendingPathComponent("new.zip"),
            relaunch: false, verifySignature: true)) { e in
            guard case UpdateError.signatureRejected = e else {
                return XCTFail("expected signatureRejected, got \(e)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("FileVault.app.old").path),
            "a rejected signature must not rotate the running bundle")
    }

    /// Move-in failure must roll the old bundle back. The mid-rotation
    /// state cannot be forced from the filesystem (the first move VACATES
    /// the destination, so no pre-occupied target survives to make the
    /// second move fail — verified), hence the injectable move seam pins
    /// the rollback contract deterministically (v4.2.32).
    func testRotateBundleRollsBackWhenMoveInFails() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("cw-rotate"))
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let fm = FileManager.default
        let current = dir.appendingPathComponent("FileVault.app")
        let old = dir.appendingPathComponent("FileVault.app.old")
        let newApp = dir.appendingPathComponent("new/FileVault.app")
        for d in [current.appendingPathComponent("Contents"), newApp.appendingPathComponent("Contents")] {
            try fm.createDirectory(atPath: d.path, withIntermediateDirectories: true)
        }
        try Data("running".utf8).write(to: current.appendingPathComponent("Contents/marker"))
        try Data("update".utf8).write(to: newApp.appendingPathComponent("Contents/marker"))

        XCTAssertThrowsError(try SelfUpdater.rotateBundle(current: current, old: old, newApp: newApp) { from, to in
            // First move (current → .old) runs for real; the second fails.
            if from == current {
                try fm.moveItem(at: from, to: to)
            } else {
                throw CocoaError(.fileWriteUnknown)
            }
        }) { e in
            guard case UpdateError.installFailed = e else {
                return XCTFail("expected installFailed, got \(e)")
            }
        }
        XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent("Contents/marker").path),
                      "the running bundle must be restored in place")
        let restored = try String(contentsOf: current.appendingPathComponent("Contents/marker"), encoding: .utf8)
        XCTAssertEqual(restored, "running")
        XCTAssertFalse(fm.fileExists(atPath: old.path), "the vacated slot is cleaned up by the restore")
    }

    /// The happy rotation: current → .old, new → current, with real moves.
    func testRotateBundleHappyPath() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("cw-rotate-ok"))
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let fm = FileManager.default
        let current = dir.appendingPathComponent("FileVault.app")
        let old = dir.appendingPathComponent("FileVault.app.old")
        let newApp = dir.appendingPathComponent("new/FileVault.app")
        for d in [current.appendingPathComponent("Contents"), newApp.appendingPathComponent("Contents")] {
            try fm.createDirectory(atPath: d.path, withIntermediateDirectories: true)
        }
        try Data("running".utf8).write(to: current.appendingPathComponent("Contents/marker"))
        try Data("update".utf8).write(to: newApp.appendingPathComponent("Contents/marker"))

        try SelfUpdater.rotateBundle(current: current, old: old, newApp: newApp)
        let now = try String(contentsOf: current.appendingPathComponent("Contents/marker"), encoding: .utf8)
        XCTAssertEqual(now, "update", "the new bundle takes over the running path")
        let kept = try String(contentsOf: old.appendingPathComponent("Contents/marker"), encoding: .utf8)
        XCTAssertEqual(kept, "running", "the old bundle is retained for rollback")
    }

    // MARK: - Item 4: ConfigStore backup observability + POSIX stamp

    /// stamp() must produce ASCII digits under any system locale: pin the
    /// formatter contract (en_US_POSIX), because a non-ASCII-digit locale
    /// made the corrupt-forensics filename unusable in shell round-trips.
    func testStampIsAlwaysASCIIDigits() {
        let s = ConfigStore.stampForTests()
        XCTAssertNotNil(s.range(of: "^[0-9]{8}-[0-9]{6}$", options: .regularExpression),
                        "stamp must be yyyyMMdd-HHmmss in ASCII digits, got: \(s)")
    }

    /// A read-only backup path must surface through lastSaveIssue instead of
    /// silently leaving no good copy behind (the save itself still succeeds).
    func testBackupWriteFailureIsObservable() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("cw-backup"))
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let store = ConfigStore(directory: dir)
        var cfg = store.load()
        cfg.roots = [ManagedRoot(path: dir.appendingPathComponent("docs").path)]
        XCTAssertTrue(store.save(cfg))

        // Make the backup file path un-writable: a DIRECTORY at the backup
        // path makes old.write(to:) fail while the primary still writes.
        let fm = FileManager.default
        let backup = dir.appendingPathComponent(ConfigStore.backupFileName)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)

        cfg.roots.append(ManagedRoot(path: dir.appendingPathComponent("more").path))
        XCTAssertTrue(store.save(cfg), "the primary save itself must still succeed")
        XCTAssertEqual(store.lastSaveIssue, .backupWriteFailed,
                       "a failed backup write must be observable")
    }

    // MARK: - Item 6: diagnostics staging sweep

    func testSweepRemovesOnlyStaleDiagnosticsStaging() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("cw-diagsweep"))
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let fm = FileManager.default
        let fresh = dir.appendingPathComponent("fv-diagnostics-fresh")
        let stale = dir.appendingPathComponent("fv-diagnostics-stale")
        let unrelated = dir.appendingPathComponent("other-dir")
        for d in [fresh, stale, unrelated] {
            try fm.createDirectory(atPath: d.path, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)],
                             ofItemAtPath: stale.path)
        SupportBundle.sweepOrphanStagingDirs(in: dir)
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))
        XCTAssertFalse(fm.fileExists(atPath: stale.path))
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path))
    }

    /// The export path itself sweeps orphans (piggyback cleanup).
    func testExportSweepsOrphansOnEntry() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("cw-diagexport"))
        defer { try? FileManager.default.removeItem(atPath: dir.path) }
        let fm = FileManager.default
        let stale = fm.temporaryDirectory
            .appendingPathComponent("fv-diagnostics-stale-\(UUID().uuidString.prefix(4))")
        try fm.createDirectory(atPath: stale.path, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)],
                             ofItemAtPath: stale.path)
        let dest = dir.appendingPathComponent("diag.zip")
        _ = try SupportBundle.export(report: "hello",
                                     configDirectory: nil,
                                     destination: dest)
        XCTAssertFalse(fm.fileExists(atPath: stale.path),
                       "a day-old orphan is swept when the next export runs")
    }

    // MARK: - Item 7: restoreDirectory refuses a literal .git

    func testRestoreDirectoryRefusesDotGit() async throws {
        let base = TestSupport.makeTempDir("cw-dotgit")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/repo"
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        let mgr = RepoManager(runner: TestSupport.newRunner())
        _ = try await mgr.createRepo(at: repoPath)
        let svc = HistoryService(repoManager: mgr)
        for target in [".git", ".git/config", "/.git"] {
            do {
                _ = try await svc.restoreDirectory(repoPath: repoPath,
                                                   directory: target,
                                                   to: "1234567890abcdef")
                XCTFail("literal .git target must be refused: \(target)")
            } catch let e as HistoryError {
                XCTAssertTrue(String(describing: e).contains("invalidPath") ||
                              String(describing: e).contains("无效"),
                              "expected invalidPath for \(target), got \(e)")
            }
        }
        // The repository must still be intact.
        XCTAssertTrue(mgr.isRepo(at: repoPath), ".git must never be deleted by the guard")
    }

    // MARK: - Item 9: fetcher transport seam

    private struct CannedTransport: ReleaseTransport {
        // struct copies would split the counter — route through a class box.
        final class Box: @unchecked Sendable {
            var responses: [Result<(Data, URLResponse), Error>]
            var calls = 0
            let lock = NSLock()
            init(_ r: [Result<(Data, URLResponse), Error>]) { responses = r }
            func next() throws -> (Data, URLResponse) {
                lock.lock(); defer { lock.unlock() }
                let r = responses[min(calls, responses.count - 1)]
                calls += 1
                return try r.get()
            }
        }
        private let box: Box
        init(_ r: [Result<(Data, URLResponse), Error>]) { box = Box(r) }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try box.next()
        }
        var realCalls: Int { box.calls }
    }

    private func http(_ status: Int) -> URLResponse {
        HTTPURLResponse(url: URL(string: "https://api.github.com/x")!,
                        statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testFetcherRetriesTransientFailureThenSucceeds() async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "tag_name": "v9.9.9",
            "assets": [["name": "Pastward-9.9.9.zip", "id": 1, "size": 10,
                        "browser_download_url": "https://example.com/z",
                        "digest": "sha256:" + String(repeating: "a", count: 64)]],
        ])
        let transport = CannedTransport([
            .failure(URLError(.timedOut)),
            .success((payload, http(200))),
        ])
        let fetcher = HttpReleaseFetcher(repo: "a/b", transport: transport)
        let info = try await fetcher.latest()
        XCTAssertEqual(info.version, "9.9.9")
        XCTAssertEqual(transport.realCalls, 2, "transient failure retries once")
    }

    func testFetcherShortCircuitsRateLimit() async throws {
        let transport = CannedTransport([
            .success((Data("{}".utf8), http(403))),
        ])
        let fetcher = HttpReleaseFetcher(repo: "a/b", transport: transport)
        do {
            _ = try await fetcher.latest()
            XCTFail("403 must surface as rateLimited")
        } catch {
            XCTAssertEqual(error as? UpdateError, .rateLimited)
        }
        XCTAssertEqual(transport.realCalls, 1,
                       "rate limiting must not burn the quota with retries")
    }

    func testFetcherMapsNon2xxToNoRelease() async throws {
        let transport = CannedTransport([
            .success((Data("{}".utf8), http(500))),
        ])
        let fetcher = HttpReleaseFetcher(repo: "a/b", transport: transport)
        do {
            _ = try await fetcher.latest()
            XCTFail("500 must surface as noRelease")
        } catch {
            XCTAssertEqual(error as? UpdateError, .noRelease)
        }
    }
}
