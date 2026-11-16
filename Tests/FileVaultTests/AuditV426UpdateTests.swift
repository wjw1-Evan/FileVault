import XCTest
import Darwin
@testable import FileVaultCore

/// Regression tests for the v4.2.26 audit, auto-update side.
///
/// These cover the invariants the fixes rely on: fail-closed sha256 checking,
/// diagnosable extraction/download failures with temp-file cleanup, crash-loop
/// markers that can fail to persist and only roll back the version they were
/// written for, and the CLT shim gate that keeps FR-01's mirror ladder first.
final class AuditV426UpdateErrorTests: XCTestCase {
    /// sha256 must fail CLOSED: a release without a digest is not installable.
    func testMissingExpectedDigestIsRejected() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("v426-nodigest"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("update.zip")
        try Data("payload".utf8).write(to: zip)

        for digest in [nil, "", "   "] as [String?] {
            XCTAssertThrowsError(try SelfUpdater.verify(zipURL: zip, expectedSHA256: digest),
                                 "digest \(String(describing: digest)) must not be accepted") { error in
                XCTAssertEqual(error as? UpdateError, .missingChecksum)
            }
        }
    }

    /// A real digest still passes (case-insensitively).
    func testMatchingDigestStillVerifies() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("v426-digest"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("update.zip")
        let payload = Data("payload".utf8)
        try payload.write(to: zip)
        XCTAssertNoThrow(try SelfUpdater.verify(zipURL: zip,
                                                expectedSHA256: SelfUpdater.sha256(payload).uppercased()))
    }

    /// Every new error case must carry a diagnosable, user-readable message.
    func testNewErrorCasesKeepTheirDetail() {
        let transport = UpdateError.downloadTransport("The Internet connection appears to be offline.")
        XCTAssertTrue(transport.localizedDescription.contains("offline"), transport.localizedDescription)

        let http = UpdateError.httpStatus(404)
        XCTAssertTrue(http.localizedDescription.contains("404"), http.localizedDescription)

        let missing = UpdateError.missingChecksum.localizedDescription
        XCTAssertTrue(missing.contains("sha256"), missing)

        let extract = UpdateError.extractFailed("ditto exited with status 1")
        XCTAssertTrue(extract.localizedDescription.contains("ditto exited with status 1"),
                      extract.localizedDescription)

        XCTAssertNotEqual(UpdateError.httpStatus(404), UpdateError.httpStatus(500))
        XCTAssertNotEqual(UpdateError.extractFailed("a"), UpdateError.extractFailed("b"))
        XCTAssertEqual(UpdateError.missingChecksum, UpdateError.missingChecksum)
    }
}

/// A corrupt archive must be reported as an extraction failure (not a download
/// failure) and must not leave the extraction directory behind.
final class AuditV426ExtractionTests: XCTestCase {
    private func makeFakeInstalledApp(in parent: URL) throws -> URL {
        let app = parent.appendingPathComponent("FileVault.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        try Data("old-binary".utf8).write(to: app.appendingPathComponent("Contents/MacOS/FileVaultApp"))
        return app
    }

    func testCorruptZipReportsExtractFailedAndCleansUp() throws {
        let work = URL(fileURLWithPath: TestSupport.makeTempDir("v426-badzip"))
        defer { try? FileManager.default.removeItem(at: work) }
        let parent = work.appendingPathComponent("Applications")
        let app = try makeFakeInstalledApp(in: parent)

        let zip = work.appendingPathComponent("broken.zip")
        try Data("this is definitely not a zip archive".utf8).write(to: zip)

        XCTAssertThrowsError(try SelfUpdater.replace(bundleURL: app, newZipURL: zip,
                                                      relaunch: false, verifySignature: false)) { error in
            guard let updateError = error as? UpdateError else {
                return XCTFail("expected UpdateError, got \(error)")
            }
            guard case .extractFailed(let detail) = updateError else {
                return XCTFail("expected .extractFailed, got \(updateError)")
            }
            XCTAssertTrue(detail.contains("ditto"), "detail should mention ditto: \(detail)")
        }

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        XCTAssertEqual(leftovers.filter { $0.hasPrefix("fv-update-") }, [],
                       "failed extraction must clean its tmp directory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path), "the installed bundle must be untouched")
        let binary = try String(contentsOf: app.appendingPathComponent("Contents/MacOS/FileVaultApp"),
                                encoding: .utf8)
        XCTAssertEqual(binary, "old-binary")
    }

    /// ditto succeeded but the archive contains no .app: still an extraction
    /// failure, still cleaned up.
    func testArchiveWithoutAppReportsExtractFailed() throws {
        let work = URL(fileURLWithPath: TestSupport.makeTempDir("v426-noapp"))
        defer { try? FileManager.default.removeItem(at: work) }
        let parent = work.appendingPathComponent("Applications")
        let app = try makeFakeInstalledApp(in: parent)

        let stage = work.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("not an app bundle".utf8).write(to: stage.appendingPathComponent("notes.txt"))
        let zip = work.appendingPathComponent("update.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", stage.path, zip.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        XCTAssertThrowsError(try SelfUpdater.replace(bundleURL: app, newZipURL: zip,
                                                      relaunch: false, verifySignature: false)) { error in
            guard case .extractFailed? = error as? UpdateError else {
                return XCTFail("expected .extractFailed, got \(error)")
            }
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        XCTAssertEqual(leftovers.filter { $0.hasPrefix("fv-update-") }, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }
}

/// Failed downloads must delete their partial temp file, and retries must keep
/// the most diagnosable error instead of a generic "download failed".
final class AuditV426DownloadCleanupTests: XCTestCase {
    private func tempFiles(containing token: String) -> [String] {
        let tmp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        return names.filter { $0.contains(token) }.map { tmp.appendingPathComponent($0).path }
    }

    func testSizeMismatchRemovesPartialTempFile() async throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("v426-dlclean"))
        let token = "v426-" + UUID().uuidString.prefix(8)
        defer {
            for path in tempFiles(containing: String(token)) { try? FileManager.default.removeItem(atPath: path) }
            try? FileManager.default.removeItem(at: dir)
        }
        let payload = Data(repeating: 0x41, count: 1024)
        let asset = dir.appendingPathComponent("asset.zip")
        try payload.write(to: asset)
        let info = ReleaseInfo(version: "9.9.9", tagName: "v9.9.9", notes: "",
                               assetName: "\(token).zip", sha256: "deadbeef",
                               assetSize: Int64(payload.count) + 4096,
                               assetURL: asset.absoluteString)
        do {
            _ = try await UpdateDownloader.download(info: info, attempts: 1)
            XCTFail("an incomplete download must throw")
        } catch let error as UpdateError {
            XCTAssertEqual(error, .downloadFailed)
        }
        XCTAssertTrue(tempFiles(containing: String(token)).isEmpty,
                      "a failed download must not leave a partial zip in /tmp")
    }

    /// file:// asset that does not exist: the transport diagnosis must survive.
    func testMissingAssetKeepsTransportDetail() async throws {
        let token = "v426-missing-" + UUID().uuidString.prefix(8)
        let info = ReleaseInfo(version: "9.9.9", tagName: "v9.9.9", notes: "",
                               assetName: "\(token).zip", sha256: "deadbeef",
                               assetSize: 0,
                               assetURL: "file:///tmp/\(token)-does-not-exist.zip")
        do {
            _ = try await UpdateDownloader.download(info: info, attempts: 1)
            XCTFail("a missing asset must throw")
        } catch let error as UpdateError {
            guard case .downloadTransport(let detail) = error else {
                return XCTFail("expected .downloadTransport, got \(error)")
            }
            XCTAssertFalse(detail.isEmpty, "the underlying transport reason must be preserved")
        }
    }

    /// An HTTP status must outrank a generic failure when retries disagree.
    func testMostSpecificErrorWins() {
        let transport = UpdateError.downloadTransport("offline")
        let kept = UpdateDownloader.moreSpecific(UpdateError.downloadFailed, than: transport)
        XCTAssertEqual(kept as? UpdateError, transport)

        let http = UpdateError.httpStatus(503)
        let keptHttp = UpdateDownloader.moreSpecific(UpdateError.downloadFailed, than: http)
        XCTAssertEqual(keptHttp as? UpdateError, http)
    }
}

/// Crash-loop marker persistence + rollback version gate (v4.2.26).
final class AuditV426RollbackGuardTests: XCTestCase {
    func testShouldRollbackRequiresTheRunningVersion() {
        let marker = UpdateGuard.Marker(previousVersion: "4.2.25", newVersion: "4.2.26",
                                        attempts: UpdateGuard.maxLaunchAttempts)
        XCTAssertTrue(UpdateGuard.shouldRollback(marker, currentVersion: "4.2.26"),
                      "same version + too many attempts must roll back")
        XCTAssertFalse(UpdateGuard.shouldRollback(marker, currentVersion: "4.2.27"),
                       "a manually reinstalled newer build must not be rolled back")
        XCTAssertFalse(UpdateGuard.shouldRollback(marker, currentVersion: "4.2.24"))

        let early = UpdateGuard.Marker(previousVersion: "4.2.25", newVersion: "4.2.26", attempts: 2)
        XCTAssertFalse(UpdateGuard.shouldRollback(early, currentVersion: "4.2.26"))
    }

    func testBeginUpdateReportsWriteFailure() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("v426-guard-ro"))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        guard !FileManager.default.isWritableFile(atPath: dir.path) else {
            throw XCTSkip("filesystem ignores directory permissions (running as root?)")
        }
        XCTAssertFalse(UpdateGuard.beginUpdate(configDirectory: dir,
                                               previousVersion: "4.2.25",
                                               newVersion: "4.2.26"),
                       "a failed marker write must be reported, not silently ignored")
        XCTAssertNil(UpdateGuard.read(configDirectory: dir))
    }

    /// A non-directory config path must also fail cleanly instead of trapping.
    func testBeginUpdateFailsWhenConfigPathIsAFile() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("v426-guard-file"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cfg")
        try Data("x".utf8).write(to: file)
        XCTAssertFalse(UpdateGuard.beginUpdate(configDirectory: file,
                                               previousVersion: "4.2.25",
                                               newVersion: "4.2.26"))
    }

    func testCancelUpdateRemovesArmedMarker() {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir("v426-guard-cancel"))
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(UpdateGuard.beginUpdate(configDirectory: dir,
                                              previousVersion: "4.2.25",
                                              newVersion: "4.2.26"))
        XCTAssertNotNil(UpdateGuard.read(configDirectory: dir))
        UpdateGuard.cancelUpdate(configDirectory: dir)
        XCTAssertNil(UpdateGuard.read(configDirectory: dir),
                     "an aborted update must not leave a crash-loop marker behind")
    }
}

/// FR-01: the Apple CLT tool shim must stay out of the candidate list while the
/// Command Line Tools are missing, so the mirror download runs before the
/// ~1.5 GB CLT dialog.
final class AuditV426CLTGatingTests: XCTestCase {
    func testMissingCommandLineToolsDropsTheXcodeGitShim() {
        let bundled = "/Applications/FileVault.app/Contents/Resources/git/bin/git"
        let provisioned = "/Users/me/Library/Application Support/FileVault/git/2.56.1-arm64/bin/git"
        let homebrew = "/opt/homebrew/bin/git"
        let raw = [bundled, provisioned, homebrew, "/usr/bin/git"]

        let filtered = SystemGitLocator.filteredCandidates(raw, commandLineToolsInstalled: false)
        XCTAssertEqual(filtered, [bundled, provisioned, homebrew],
                       "the xcode-select shim must not be probed before the mirror ladder")

        // `which git` resolving to the shim is the same problem.
        XCTAssertTrue(SystemGitLocator.filteredCandidates(["/usr/bin/git"],
                                                          commandLineToolsInstalled: false).isEmpty)
    }

    func testInstalledCommandLineToolsKeepTheShim() {
        let raw = ["/opt/homebrew/bin/git", "/usr/bin/git"]
        XCTAssertEqual(SystemGitLocator.filteredCandidates(raw, commandLineToolsInstalled: true), raw)
    }

    /// The CLT probe itself is a plain exit-status read: no dialog, no output.
    func testCommandLineToolsProbeUsesExitStatus() throws {
        let dir = TestSupport.makeTempDir("v426-clt-probe")
        defer { try? FileManager.default.removeItem(atPath: dir) }

        func makeTool(_ name: String, exitCode: Int) throws -> String {
            let path = dir + "/" + name
            try "#!/bin/sh\nexit \(exitCode)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }
        let installed = try makeTool("xcode-select-installed", exitCode: 0)
        let missing = try makeTool("xcode-select-missing", exitCode: 2)
        XCTAssertTrue(SystemGitLocator.commandLineToolsInstalled(xcodeSelectPath: installed))
        XCTAssertFalse(SystemGitLocator.commandLineToolsInstalled(xcodeSelectPath: missing))
        XCTAssertFalse(SystemGitLocator.commandLineToolsInstalled(xcodeSelectPath: dir + "/does-not-exist"))
    }
}

/// v4.2.26: a timed-out git must not leave ssh/git-remote-* descendants holding
/// the pipes (each one leaked a blocked global-queue reader thread).
final class AuditV426GitDescendantTests: XCTestCase {
    func testTimeoutKillsDescendantsHoldingThePipes() throws {
        let dir = TestSupport.makeTempDir("v426-timeout-desc")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let pidFile = dir + "/child.pid"
        let script = dir + "/git"
        let body = """
        #!/bin/sh
        sleep 30 &
        echo $! > "$CHILD_PID_FILE"
        sleep 30
        """
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)

        // 2 s (not 0.5): under full-suite load the shell needs a moment to start
        // and append the child pid before the timeout path kills it.
        let runner = GitRunner(gitExecutable: script, defaultTimeout: 2.0)
        let start = Date()
        XCTAssertThrowsError(try runner.runSync(["fetch"], timeout: 2.0,
                                                env: ["CHILD_PID_FILE": pidFile])) { error in
            guard let gitError = error as? GitCommandError else {
                return XCTFail("expected GitCommandError, got \(error)")
            }
            XCTAssertEqual(gitError.exitCode, -9)
            XCTAssertTrue(gitError.stderr.contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10,
                          "the timeout path must not block on descendant fds")

        let pidText = (try? String(contentsOfFile: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pidText, let childPID = pid_t(pidText) else {
            return XCTFail("fake git did not record its child pid")
        }
        XCTAssertTrue(waitUntilGone(childPID),
                      "the child process holding stdout/stderr must be terminated")
    }

    private func waitUntilGone(_ pid: pid_t) -> Bool {
        for _ in 0..<30 {
            if kill(pid, 0) != 0 { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}
