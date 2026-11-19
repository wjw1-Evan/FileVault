import XCTest
@testable import FileVaultCore

/// GitEnvGuard's injectable/pure helpers: the CLT probe (injectable
/// xcode-select path), the candidate filter that drops Apple's shim, the
/// source classification, and the version parser.
final class GitEnvGuardHelpersTests: XCTestCase {

    private func makeScript(_ body: String, name: String) throws -> String {
        let dir = TestSupport.makeTempDir("geguard-" + name)
        let path = dir + "/" + name
        TestSupport.write(body, to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testCommandLineToolsProbeRespectsExitStatus() throws {
        let ok = try makeScript("#!/bin/sh\nexit 0\n", name: "clt-ok")
        XCTAssertTrue(SystemGitLocator.commandLineToolsInstalled(xcodeSelectPath: ok))
        let missing = try makeScript("#!/bin/sh\nexit 2\n", name: "clt-missing")
        XCTAssertFalse(SystemGitLocator.commandLineToolsInstalled(xcodeSelectPath: missing))
        XCTAssertFalse(SystemGitLocator.commandLineToolsInstalled(xcodeSelectPath: "/nonexistent/xcode-select"))
    }

    /// 'which git' resolves to the same Apple shim: with CLT uninstalled the
    /// shim must leave the candidate list (v4.2.26).
    func testFilteredCandidatesDropTheShimWhenCLTIsMissing() {
        let candidates = ["/opt/homebrew/bin/git", "/usr/bin/git", "/usr/local/bin/git"]
        XCTAssertEqual(SystemGitLocator.filteredCandidates(candidates, commandLineToolsInstalled: true),
                       candidates)
        let filtered = SystemGitLocator.filteredCandidates(candidates, commandLineToolsInstalled: false)
        XCTAssertFalse(filtered.contains("/usr/bin/git"), "the CLT shim is dropped")
        XCTAssertTrue(filtered.contains("/opt/homebrew/bin/git"))
        XCTAssertTrue(filtered.contains("/usr/local/bin/git"))
    }

    func testSourceClassification() {
        let insideBundle = (Bundle.main.bundleURL.path as NSString)
            .appendingPathComponent("Resources/git/bin/git")
        XCTAssertEqual(GitEnvGuard.source(for: insideBundle), .bundled,
                       Bundle.main.bundlePath)
        let downloaded = GitBinaryProvisioner.defaultInstallRoot
            .appendingPathComponent("git/bin/git").path
        XCTAssertEqual(GitEnvGuard.source(for: downloaded), .downloaded)
        XCTAssertEqual(GitEnvGuard.source(for: "/opt/homebrew/bin/git"), .system)
    }

    func testVersionParsing() throws {
        let fake = try makeScript("#!/bin/sh\necho 'git version 9.9.9-custom'\n", name: "git-fake")
        XCTAssertEqual(GitEnvGuard.version(fromExecutable: fake), "9.9.9-custom")
        let garbage = try makeScript("#!/bin/sh\necho 'not a version line'\n", name: "git-garbage")
        XCTAssertNil(GitEnvGuard.version(fromExecutable: garbage))
        XCTAssertNil(GitEnvGuard.version(fromExecutable: "/nonexistent/git"))
        // The real git on this machine parses through the same path.
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/git") {
            let real = GitEnvGuard.version(fromExecutable: "/usr/bin/git")
            XCTAssertNotNil(real)
            XCTAssertFalse(real!.hasPrefix("git version"), "the prefix is stripped")
        }
    }

    func testGitEnvErrorMessagesAreReadable() {
        XCTAssertFalse(GitEnvError.notFound.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(GitEnvError.installFailed.errorDescription?.isEmpty ?? true)
        let provision = GitEnvError.provisionFailed("mirror 3 unreachable")
        XCTAssertTrue(provision.errorDescription?.contains("mirror 3 unreachable") == true)
    }
}
