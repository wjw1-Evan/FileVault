import XCTest
@testable import FileVaultCore

/// Fake locator for install-strategy tests.
final class FakeLocator: GitLocator {
    let result: String?
    init(result: String?) { self.result = result }
    func locate() -> String? { result }
}

final class GitEnvGuardTests: XCTestCase {
    func testDetectWithRealGit() async {
        let guard_ = GitEnvGuard(locator: FakeLocator(result: "/usr/bin/git"))
        let r = await guard_.detect()
        guard case .success(let d) = r else {
            return XCTFail("detect should succeed with real git")
        }
        XCTAssertEqual(d.gitPath, "/usr/bin/git")
        XCTAssertTrue(d.version.contains("2."))
        XCTAssertEqual(d.source, .system)
    }

    func testDetectFailsWithoutGit() async {
        let guard_ = GitEnvGuard(locator: FakeLocator(result: nil))
        let r = await guard_.detect()
        guard case .failure = r else {
            return XCTFail("detect should fail without git")
        }
        if case .failed = guard_.status {} else { XCTFail("status should be failed") }
    }

    func testVersionParsing() {
        let v = GitEnvGuard.version(fromExecutable: "/usr/bin/git")
        XCTAssertNotNil(v)
        XCTAssertTrue(v?.contains("2.") ?? false)
    }
}

// MARK: - FR-01 install strategy chain (mirror ladder)

final class GitEnvGuardInstallTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fv-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// A stand-in for a provisioned git payload.
    private func makeFakeGit() throws -> String {
        let bin = dir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let git = bin.appendingPathComponent("git")
        let script = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"git version 2.56.1\"; exit 0; fi\nexit 0\n"
        try script.write(to: git, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)
        return git.path
    }

    func testInstallFallsBackToProvisionedGit() async throws {
        let git = try makeFakeGit()
        let fake = FakeGitProvisioner(result: .success(git))
        let guard_ = GitEnvGuard(locator: FakeLocator(result: nil), provisioner: fake,
                                 allowXcodeCLTFallback: false)
        let detection = try await guard_.install()
        XCTAssertEqual(detection.gitPath, git)
        XCTAssertEqual(detection.version, "2.56.1")
        XCTAssertEqual(guard_.lastStrategy, .downloaded)
        XCTAssertEqual(fake.callCount, 1)
    }

    func testInstallPrefersExistingGitOverDownloading() async throws {
        let fake = FakeGitProvisioner(result: .failure(GitProvisionError.noMirrors))
        let guard_ = GitEnvGuard(locator: FakeLocator(result: "/usr/bin/git"), provisioner: fake,
                                 allowXcodeCLTFallback: false)
        let detection = try await guard_.install()
        XCTAssertEqual(detection.gitPath, "/usr/bin/git")
        XCTAssertEqual(fake.callCount, 0, "an existing git must never trigger a download")
    }

    func testInstallSurfacesEveryMirrorFailure() async throws {
        let reasons = ["GitHub 官方: 连接超时", "ghfast.top 加速: 连接中断"]
        let fake = FakeGitProvisioner(result: .failure(GitProvisionError.allMirrorsFailed(reasons: reasons)))
        let guard_ = GitEnvGuard(locator: FakeLocator(result: nil), provisioner: fake,
                                 allowXcodeCLTFallback: false)
        do {
            _ = try await guard_.install()
            XCTFail("install must fail when every mirror fails")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("备用下载地址"), message)
            XCTAssertTrue(message.contains("GitHub 官方"), message)
            XCTAssertTrue(message.contains("ghfast.top"), message)
        }
    }

    func testSourceClassification() {
        XCTAssertEqual(GitEnvGuard.source(for: "/usr/bin/git"), .system)
        XCTAssertEqual(GitEnvGuard.source(for: "/opt/homebrew/bin/git"), .system)
        let provisioned = GitBinaryProvisioner.defaultInstallRoot.appendingPathComponent("2.56.1-arm64/bin/git").path
        XCTAssertEqual(GitEnvGuard.source(for: provisioned), .downloaded)
    }
}
