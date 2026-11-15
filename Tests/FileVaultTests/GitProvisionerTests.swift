import XCTest
@testable import FileVaultCore

// MARK: - Fakes

/// Transport fake: no network in tests. Outcomes are matched by URL substring.
final class FakeGitTransport: GitDownloadTransport, @unchecked Sendable {
    enum Outcome {
        case payload(URL)
        case writeThenFail(URL)
        case failure(Error)
        case stall(TimeInterval)
    }

    private let lock = NSLock()
    private var outcomes: [String: Outcome]
    private var requested: [String] = []

    init(outcomes: [String: Outcome]) {
        self.outcomes = outcomes
    }

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return requested
    }

    func download(from url: URL, to destination: URL, timeout: TimeInterval) async throws {
        lock.lock()
        requested.append(url.absoluteString)
        let outcome = outcomes.first { url.absoluteString.contains($0.key) }.map { $0.value }
        lock.unlock()

        switch outcome {
        case .payload(let file):
            try copy(file, to: destination)
        case .writeThenFail(let file):
            try copy(file, to: destination)
            throw URLError(.networkConnectionLost)
        case .failure(let error):
            throw error
        case .stall(let seconds):
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        case nil:
            throw URLError(.cannotFindHost)
        }
    }

    private func copy(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
    }
}

final class FakeGitProvisioner: GitProvisioning, @unchecked Sendable {
    let result: Result<String, Error>
    private let lock = NSLock()
    private var count = 0
    var onProvision: ((GitProvisionProgress?) -> Void)?

    init(result: Result<String, Error>) {
        self.result = result
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func provision(progress: GitProvisionProgress?) async throws -> String {
        lock.lock(); count += 1; lock.unlock()
        onProvision?(progress)
        return try result.get()
    }
}

// MARK: - Tests

final class GitProvisionerTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fv-git-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: Fixtures

    /// Build a real .tar.gz whose "git" is a tiny shell script that answers --version.
    private func makePayload(version: String = "2.56.1", withCredentialManager: Bool = false) throws -> (tarball: URL, build: GitBuild) {
        let fm = FileManager.default
        let payload = workDir.appendingPathComponent("payload-\(UUID().uuidString)", isDirectory: true)
        let bin = payload.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: payload.appendingPathComponent("libexec/git-core", isDirectory: true),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: payload.appendingPathComponent("share/git-core/templates", isDirectory: true),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: payload.appendingPathComponent("ssl", isDirectory: true),
                               withIntermediateDirectories: true)
        let script = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"git version \(version)\"; exit 0; fi\nexit 0\n"
        let git = bin.appendingPathComponent("git")
        try script.write(to: git, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)
        try Data("fake-ca".utf8).write(to: payload.appendingPathComponent("ssl/cacert.pem"))
        if withCredentialManager {
            // Mirror the upstream payload: GCM (.NET/Avalonia) next to real git helpers.
            let core = payload.appendingPathComponent("libexec/git-core", isDirectory: true)
            for name in ["git-credential-manager", "System.Private.CoreLib.dll",
                         "libcoreclr.dylib", "createdump", "git-lfs"] {
                try Data("x".utf8).write(to: core.appendingPathComponent(name))
            }
            try FileManager.default.createDirectory(at: core.appendingPathComponent("zh-Hans", isDirectory: true),
                                                    withIntermediateDirectories: true)
            try Data("x".utf8).write(to: core.appendingPathComponent("zh-Hans/gcm.resources.dll"))
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: core.appendingPathComponent("git-credential-manager").path)
        }

        let tarURL = workDir.appendingPathComponent("git-\(UUID().uuidString).tar.gz")
        try runTool("/usr/bin/tar", ["-czf", tarURL.path, "-C", payload.path, "."])
        return (tarURL, makeBuild(tarball: tarURL, version: version))
    }

    private func makeBuild(tarball: URL, version: String = "2.56.1") -> GitBuild {
        let size = (try? FileManager.default.attributesOfItem(atPath: tarball.path)[.size] as? NSNumber)?.int64Value ?? 0
        return GitBuild(version: version, tag: "v\(version)", asset: "fake-git.tar.gz",
                        sha256: (try? GitBinaryProvisioner.sha256(ofFile: tarball)) ?? "",
                        size: size, arch: .arm64)
    }

    @discardableResult
    private func runTool(_ path: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "tar", code: Int(p.terminationStatus)) }
        return p.terminationStatus
    }

    private func mirrors(_ hosts: [String]) -> [GitMirror] {
        hosts.map { GitMirror(id: $0, name: "mirror-\($0)", template: "https://\($0).test/{tag}/{asset}") }
    }

    private func provisioner(_ transport: GitDownloadTransport,
                             build: GitBuild,
                             mirrors: [GitMirror],
                             attemptDeadline: TimeInterval = 30) -> GitBinaryProvisioner {
        GitBinaryProvisioner(build: build, mirrors: mirrors, transport: transport,
                             installRoot: workDir.appendingPathComponent("install", isDirectory: true),
                             attemptDeadline: attemptDeadline, idleTimeout: 5)
    }

    // MARK: Behaviour

    func testFallsBackToNextMirrorWhenFirstFails() async throws {
        let (tarball, build) = try makePayload()
        let transport = FakeGitTransport(outcomes: [
            "first": .failure(URLError(.cannotConnectToHost)),
            "second": .payload(tarball),
        ])
        let p = provisioner(transport, build: build, mirrors: mirrors(["first", "second"]))
        let git = try await p.provision()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: git))
        XCTAssertTrue(git.hasSuffix("/bin/git"))
        XCTAssertEqual(transport.calls.count, 2, "must skip the dead mirror and use the second")
        XCTAssertTrue(transport.calls[0].contains("first"))
        XCTAssertTrue(transport.calls[1].contains("second"))
    }

    func testChecksumMismatchIsRejectedAndNextMirrorIsUsed() async throws {
        let (goodTarball, build) = try makePayload()
        let (otherTarball, _) = try makePayload(version: "9.9.9")   // different bytes -> wrong sha
        let transport = FakeGitTransport(outcomes: [
            "corrupt": .payload(otherTarball),
            "good": .payload(goodTarball),
        ])
        let p = provisioner(transport, build: build, mirrors: mirrors(["corrupt", "good"]))
        let git = try await p.provision()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: git))
        XCTAssertTrue(transport.calls.contains { $0.contains("good") })
    }

    func testInterruptedTransferFallsBack() async throws {
        let (tarball, build) = try makePayload()
        let transport = FakeGitTransport(outcomes: [
            "flaky": .writeThenFail(tarball),
            "stable": .payload(tarball),
        ])
        let p = provisioner(transport, build: build, mirrors: mirrors(["flaky", "stable"]))
        let git = try await p.provision()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: git))
    }

    func testStalledMirrorTimesOutAndFallsBack() async throws {
        let (tarball, build) = try makePayload()
        let transport = FakeGitTransport(outcomes: [
            "stalled": .stall(5),
            "healthy": .payload(tarball),
        ])
        let p = provisioner(transport, build: build, mirrors: mirrors(["stalled", "healthy"]),
                            attemptDeadline: 0.15)
        let started = Date()
        let git = try await p.provision()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: git))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "a stalled mirror must not block the ladder")
        XCTAssertTrue(transport.calls.contains { $0.contains("healthy") })
    }

    func testCredentialManagerIsPrunedBeforeInstall() async throws {
        let (tarball, build) = try makePayload(withCredentialManager: true)
        let transport = FakeGitTransport(outcomes: ["ok": .payload(tarball)])
        let p = provisioner(transport, build: build, mirrors: mirrors(["ok"]))
        let git = try await p.provision()
        let core = URL(fileURLWithPath: git).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("libexec/git-core")
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: core.appendingPathComponent("System.Private.CoreLib.dll").path))
        XCTAssertFalse(fm.fileExists(atPath: core.appendingPathComponent("git-credential-manager").path))
        XCTAssertFalse(fm.fileExists(atPath: core.appendingPathComponent("zh-Hans").path))
        XCTAssertTrue(fm.fileExists(atPath: core.appendingPathComponent("git-lfs").path),
                      "real git helpers must survive pruning")
        XCTAssertTrue(GitBinaryProvisioner.verifies(git))
    }

    func testPruneIsNoOpWhenPayloadHasNoCredentialManager() throws {
        let (tarball, _) = try makePayload()
        let dir = workDir.appendingPathComponent("plain-payload", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runTool("/usr/bin/tar", ["-xzf", tarball.path, "-C", dir.path])
        let core = dir.appendingPathComponent("libexec/git-core")
        try Data("x".utf8).write(to: core.appendingPathComponent("stays.dll"))
        XCTAssertEqual(try GitBinaryProvisioner.pruneUnusedHelpers(in: dir), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: core.appendingPathComponent("stays.dll").path))
    }

    func testAllMirrorsFailListsEveryReason() async throws {
        let (_, build) = try makePayload()
        let transport = FakeGitTransport(outcomes: [
            "a": .failure(URLError(.timedOut)),
            "b": .failure(URLError(.cannotFindHost)),
            "c": .failure(URLError(.secureConnectionFailed)),
        ])
        let p = provisioner(transport, build: build, mirrors: mirrors(["a", "b", "c"]))
        do {
            _ = try await p.provision()
            XCTFail("provisioning must fail when every mirror fails")
        } catch let error as GitProvisionError {
            guard case .allMirrorsFailed(let reasons) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(reasons.count, 3)
            XCTAssertTrue(reasons.contains { $0.contains("mirror-a") })
            let message = error.errorDescription ?? ""
            XCTAssertTrue(message.contains("mirror-a"))
            XCTAssertTrue(message.contains("超时"))
        }
    }

    func testSecondRunReusesInstalledCopyWithoutNetwork() async throws {
        let (tarball, build) = try makePayload()
        let transport = FakeGitTransport(outcomes: ["only": .payload(tarball)])
        let first = provisioner(transport, build: build, mirrors: mirrors(["only"]))
        let git = try await first.provision()
        XCTAssertEqual(transport.calls.count, 1)

        let second = provisioner(transport, build: build, mirrors: mirrors(["only"]))
        let again = try await second.provision()
        XCTAssertEqual(git, again)
        XCTAssertEqual(transport.calls.count, 1, "an installed git must not be downloaded twice")
    }

    func testProgressStagesAreReportedInOrder() async throws {
        let (tarball, build) = try makePayload()
        let transport = FakeGitTransport(outcomes: ["ok": .payload(tarball)])
        let p = provisioner(transport, build: build, mirrors: mirrors(["ok"]))
        let collector = ProgressCollector()
        _ = try await p.provision { stage, _, _ in collector.record(stage) }
        XCTAssertEqual(collector.stages, [.resolving, .downloading, .verifying, .extracting, .validating, .ready])
    }

    func testInstalledGitIsFoundByLocatorScan() async throws {
        let (tarball, build) = try makePayload()
        let transport = FakeGitTransport(outcomes: ["ok": .payload(tarball)])
        let p = provisioner(transport, build: build, mirrors: mirrors(["ok"]))
        let git = try await p.provision()
        let found = try XCTUnwrap(GitBinaryProvisioner.findInstalledGit(in: p.installRoot))
        XCTAssertEqual(URL(fileURLWithPath: found).resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: git).resolvingSymlinksInPath().path)
    }

    // MARK: Pure helpers

    func testMirrorTemplateExpansion() {
        let build = GitBuildCatalog.appleSilicon
        let mirror = GitMirror(id: "x", name: "x",
                               template: "https://example.test/{tag}/{asset}")
        XCTAssertEqual(mirror.url(for: build)?.absoluteString,
                       "https://example.test/v\(build.version)/\(build.asset)")
        let bad = GitMirror(id: "bad", name: "bad", template: "not-a-url/{asset}")
        XCTAssertNil(bad.url(for: build))
    }

    func testDefaultLadderIsUsableAndOrdered() {
        let build = GitBuildCatalog.appleSilicon
        let ladder = GitMirror.defaultLadder
        XCTAssertGreaterThanOrEqual(ladder.count, 3, "FR-01 needs multiple independent download addresses")
        XCTAssertEqual(ladder.first?.id, "github", "direct GitHub first, accelerators next")
        for mirror in ladder {
            XCTAssertNotNil(mirror.url(for: build), "mirror \(mirror.id) must expand to a URL")
        }
        XCTAssertEqual(Set(ladder.map(\.id)).count, ladder.count, "mirror ids must be unique")
    }

    func testBuildCatalogIsConsistent() {
        for build in GitBuildCatalog.all {
            XCTAssertEqual(build.sha256.count, 64, "sha256 must be pinned for \(build.arch)")
            XCTAssertTrue(build.sha256.allSatisfy { $0.isHexDigit })
            XCTAssertGreaterThan(build.size, 1_000_000)
            let archToken = build.arch == .arm64 ? "arm64" : "x64"
            XCTAssertTrue(build.asset.contains(archToken), "asset name must carry the arch (\(build.asset))")
            XCTAssertTrue(build.asset.contains(build.version))
            XCTAssertTrue(build.tag.contains(build.version))
        }
        XCTAssertEqual(GitBuildCatalog.build(for: .arm64).arch, .arm64)
        XCTAssertEqual(GitBuildCatalog.build(for: .x86_64).arch, .x86_64)
        XCTAssertEqual(Set(GitBuildCatalog.all.map(\.asset)).count, GitBuildCatalog.all.count)
    }

    func testEnvironmentOverridesPointIntoThePayload() throws {
        let (tarball, _) = try makePayload()
        let dir = workDir.appendingPathComponent("payload-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runTool("/usr/bin/tar", ["-xzf", tarball.path, "-C", dir.path])
        guard let root = GitBinaryProvisioner.locateGitRoot(in: dir) else {
            return XCTFail("tar layout should expose bin/git")
        }
        let env = GitBinaryProvisioner.environmentOverrides(gitRoot: root.path)
        XCTAssertEqual(env["GIT_EXEC_PATH"], root.path + "/libexec/git-core")
        XCTAssertEqual(env["GIT_SSL_CAINFO"], root.path + "/ssl/cacert.pem")
        XCTAssertEqual(env["GIT_TEMPLATE_DIR"], root.path + "/share/git-core/templates")
        XCTAssertEqual(GitBinaryProvisioner.gitRoot(forExecutable: root.path + "/bin/git"), root.path)
        XCTAssertNil(GitBinaryProvisioner.gitRoot(forExecutable: "/usr/bin/git"), "system git is not a payload")
    }

    func testLocateGitRootHandlesNestedLayout() throws {
        let nested = workDir.appendingPathComponent("nested-one-level", isDirectory: true)
        let bin = nested.appendingPathComponent("git-2.56.1/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let git = bin.appendingPathComponent("git")
        try "#!/bin/sh\nexit 0\n".write(to: git, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)
        XCTAssertEqual(GitBinaryProvisioner.locateGitRoot(in: nested)?.lastPathComponent, "git-2.56.1")
    }

    func testArchHasKnownBuild() {
        XCTAssertNotNil(GitBuildCatalog.build(for: GitArch.current))
        XCTAssertNotEqual(GitBuildCatalog.appleSilicon.sha256, GitBuildCatalog.intel.sha256)
    }
}

/// Thread-safe stage recorder for the progress test.
final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GitProvisionStage] = []

    func record(_ stage: GitProvisionStage) {
        lock.lock(); recorded.append(stage); lock.unlock()
    }

    var stages: [GitProvisionStage] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}
