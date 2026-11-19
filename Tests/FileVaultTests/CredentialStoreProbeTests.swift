import XCTest
@testable import FileVaultCore

/// CredentialStore's probe and helper-chain contract, driven by a fake git
/// script so every backend branch (keychain usage vs not-a-command vs 127,
/// existing helpers respected vs replaced, file fallback with 0600) is
/// deterministic — the real machine can only produce one of those states.
///
/// Note: GitRunner prepends --literal-pathspecs/-c flags, so the fake matches
/// on ANY argument position (same for-over-args shape as the slow-git
/// wrapper).
final class CredentialStoreProbeTests: XCTestCase {

    private var ctrl: String = ""
    private var logPath: String = ""
    private var script: String = ""

    private func makeFakeGit() throws {
        let base = TestSupport.makeTempDir("credprobe")
        ctrl = base + "/ctrl"
        logPath = base + "/calls.log"
        script = base + "/fake-git"
        try FileManager.default.createDirectory(atPath: ctrl, withIntermediateDirectories: true)
        let body = "#!/bin/sh\n" +
            "printf '%s\\n' \"$*\" >> \"" + logPath + "\"\n" +
            "p=0; c=0; ga=0; f=0; r=0\n" +
            "for a in \"$@\"; do\n" +
            "case \"$a\" in\n" +
            "credential-osxkeychain) p=1 ;;\n" +
            "config) c=1 ;;\n" +
            "--get-all) ga=1 ;;\n" +
            "fill) f=1 ;;\n" +
            "reject) r=1 ;;\n" +
            "esac\ndone\n" +
            "if [ \"$p\" = 1 ]; then\n" +
            "[ -f \"" + ctrl + "/usage\" ] && { echo 'usage: git credential-osxkeychain <get|store|erase>' >&2; exit 128; }\n" +
            "[ -f \"" + ctrl + "/not-git\" ] && { echo \"git: 'credential-osxkeychain' is not a git command.\" >&2; exit 1; }\n" +
            "[ -f \"" + ctrl + "/127\" ] && exit 127\n" +
            "exit 0\nfi\n" +
            "if [ \"$r\" = 1 ] && [ -f \"" + ctrl + "/reject-fail\" ]; then exit 1; fi\n" +
            "if [ \"$c\" = 1 ]; then\n" +
            "if [ \"$ga\" = 1 ]; then cat \"" + ctrl + "/helpers\" 2>/dev/null; fi\n" +
            "exit 0\nfi\n" +
            "if [ \"$f\" = 1 ]; then cat \"" + ctrl + "/fill\" 2>/dev/null; fi\n" +
            "exit 0\n"
        TestSupport.write(body, to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
    }

    private var runner: GitRunner {
        GitRunner(gitExecutable: script, defaultTimeout: 10)
    }

    private var calls: String {
        (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    }

    private func makeRepoDir() throws -> String {
        let dir = TestSupport.makeTempDir("credprobe-repo")
        return dir
    }

    private func touch(_ name: String) {
        TestSupport.write("on", to: ctrl + "/" + name)
    }

    /// The v4.2.25 probe: exit 128-with-usage means PRESENT; exit 1 with "is
    /// not a git command" means absent; 127 means absent.
    func testKeychainHelperAvailabilityProbe() async throws {
        try makeFakeGit()
        touch("usage")
        let present = await CredentialStore.isAvailable(runner: runner)
        XCTAssertTrue(present, "the real helper prints usage and exits 128")

        try makeFakeGit()
        touch("not-git")
        let notGit = await CredentialStore.isAvailable(runner: runner)
        XCTAssertFalse(notGit, "an unknown helper is exit 1 + 'is not a git command'")

        try makeFakeGit()
        touch("127")
        let exit127 = await CredentialStore.isAvailable(runner: runner)
        XCTAssertFalse(exit127)

        let missing = await CredentialStore.isAvailable(
            runner: GitRunner(gitExecutable: "/nonexistent/git", defaultTimeout: 5))
        XCTAssertFalse(missing, "a missing binary is not an available helper")
    }

    /// An existing user helper is respected untouched (gh, custom): prepare
    /// only READS the chain in that case — the log proves no write happened.
    func testExistingHelpersAreRespectedNotReplaced() async throws {
        try makeFakeGit()
        let repo = try makeRepoDir()
        TestSupport.write("store --file=\"/x/creds file\"", to: ctrl + "/helpers")
        let backend = await CredentialStore.prepare(runner: runner, repoPath: repo)
        XCTAssertEqual(backend, .file("/x/creds file"), "the quoted store path is parsed")
        XCTAssertFalse(calls.contains("--replace-all"),
                       "an existing helper chain is never rewritten")

        try makeFakeGit()
        let repo2 = try makeRepoDir()
        TestSupport.write("osxkeychain", to: ctrl + "/helpers")
        let backend2 = await CredentialStore.prepare(runner: runner, repoPath: repo2)
        XCTAssertEqual(backend2, .keychain)
        XCTAssertFalse(calls.contains("--replace-all"))
    }

    /// PAT mode takes over the chain from an inherited helper (v4.1.6): the
    /// reset marker + osxkeychain are written when the keychain exists.
    func testPrepareInstallsKeychainWhenTakeoverIsNeeded() async throws {
        try makeFakeGit()
        let repo = try makeRepoDir()
        // An existing value of bare "store" has no parseable --file: prepare
        // falls through and claims the chain with its own helper.
        TestSupport.write("store", to: ctrl + "/helpers")
        touch("usage")
        let backend = await CredentialStore.prepare(runner: runner, repoPath: repo)
        XCTAssertEqual(backend, .keychain)
        XCTAssertTrue(calls.contains("--replace-all"), "the inherited chain is reset first")
        XCTAssertTrue(calls.contains("osxkeychain"), "the keychain helper is added")
    }

    /// No keychain helper on this Mac (the bundled-git case): the private-file
    /// fallback with 0600 file / 0700 dir is installed (v4.0.2).
    func testPrepareFallsBackToPrivateFileWhenKeychainUnavailable() async throws {
        try makeFakeGit()
        let repo = try makeRepoDir()
        touch("not-git")
        let storeFile = URL(fileURLWithPath: ctrl).appendingPathComponent("creds/secret")
        let backend = await CredentialStore.prepare(runner: runner, repoPath: repo,
                                                    storeFile: storeFile)
        guard case .file(let path) = backend else {
            return XCTFail("expected the file backend, got \(backend)")
        }
        XCTAssertEqual(path, storeFile.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeFile.path))
        let filePerms = try FileManager.default.attributesOfItem(atPath: storeFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(filePerms, 0o600, "the credential file is owner-only")
        let dirPerms = try FileManager.default.attributesOfItem(atPath: storeFile.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerms, 0o700, "the credential directory is owner-only")
        XCTAssertTrue(calls.contains("store --file="), "the store helper is configured")
    }

    /// approve exits 0 even when nothing was stored — the read-back guard is
    /// the real test (v4.2.25): a missing read-back or a DIFFERENT value must
    /// throw instead of telling the UI the token was saved.
    func testStoreVerifiesTheReadback() async throws {
        try makeFakeGit()
        let repo = try makeRepoDir()
        TestSupport.write("username=alice\npassword=tok-123\n", to: ctrl + "/fill")
        try await CredentialStore.store(runner: runner, url: "https://github.com/x/y",
                                        username: "alice", password: "tok-123")

        try makeFakeGit()
        TestSupport.write("username=alice\npassword=SOMETHING-ELSE\n", to: ctrl + "/fill")
        do {
            try await CredentialStore.store(runner: runner, url: "https://github.com/x/y",
                                            username: "alice", password: "tok-123")
            XCTFail("a mismatched read-back must throw")
        } catch let error as CredentialStore.CredentialError {
            XCTAssertTrue(error.localizedDescription.contains("读回了不同"),
                          error.localizedDescription)
        }

        // Nothing readable back at all (helper missing/misconfigured).
        try makeFakeGit()
        do {
            try await CredentialStore.store(runner: runner, url: "https://github.com/x/y",
                                            username: "alice", password: "tok-123")
            XCTFail("a missing read-back must throw")
        } catch let error as CredentialStore.CredentialError {
            XCTAssertTrue(error.localizedDescription.contains("无法从本机凭证库读回"),
                          error.localizedDescription)
        }
    }

    /// The v4.2.27 askpass guard from the parsing side: a prompt-echo value is
    /// not a credential, fill returns nil and store reports failure.
    func testFillRejectsPromptEchoValues() async throws {
        try makeFakeGit()
        TestSupport.write("Username for 'https://x': \nPassword for 'https://x': \n",
                          to: ctrl + "/fill")
        let filled = await CredentialStore.fill(runner: runner, url: "https://github.com/x/y")
        XCTAssertNil(filled, "prompt text is not a stored credential")
    }

    func testEraseSurfacesFailure() async throws {
        try makeFakeGit()
        try await CredentialStore.erase(runner: runner, url: "https://github.com/x/y")

        try makeFakeGit()
        touch("reject-fail")
        do {
            try await CredentialStore.erase(runner: runner, url: "https://github.com/x/y")
            XCTFail("a failed reject must throw")
        } catch let error as CredentialStore.CredentialError {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testStorePathParsingFromHelperValue() {
        XCTAssertEqual(CredentialStore.storePath(fromHelperValue: "store --file=\"/x/creds file\""),
                       "/x/creds file", "quoted paths are unquoted")
        XCTAssertEqual(CredentialStore.storePath(fromHelperValue: "store --file=/x/creds"),
                       "/x/creds")
        XCTAssertEqual(CredentialStore.storePath(fromHelperValue: "store --file=\"abc"),
                       "abc", "a missing closing quote still yields the path")
        XCTAssertNil(CredentialStore.storePath(fromHelperValue: "osxkeychain"))
        XCTAssertNil(CredentialStore.storePath(fromHelperValue: "store --file=\"\""),
                     "an empty path is not a private-file backend (v4.2.26)")
    }
}
