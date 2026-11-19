import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// v4.2.31 settings UI behaviour round (fix-settings-ui):
/// - the 测试 button refuses the same bare-host paste mistake the save guard
///   blocks — synchronously, without taking the busy lock or running git;
///   complete forms (absolute path, ssh://, scp-style) still reach the probe;
/// - the support mail URL contract is pinned: address + app/OS versions in
///   the subject, and never a silent no-op;
/// - the .gitignore chip insertion dedupes by trimmed line.
@MainActor
final class SettingsUIBehaviorTests: XCTestCase {

    /// Same shape as SettingsModelTests.makeModel (AppGuardTests.swift): a
    /// real service with one protected folder, bound through a real AppState.
    private func makeModel() async throws -> (SettingsModel, FileVaultService, String) {
        let base = TestSupport.makeTempDir("setui")
        try? FileManager.default.createDirectory(atPath: base + "/vault", withIntermediateDirectories: true)
        TestSupport.write("s", to: base + "/vault/s.md")
        let service = FileVaultService(configDirectory: URL(fileURLWithPath: base + "/cfg"))
        try await service.start()
        try await service.addRoot(path: base + "/vault")
        let app = AppState()
        app.service = service
        let model = SettingsModel()
        model.bind(app)
        return (model, service, base)
    }

    // MARK: - 测试 refuses what 保存 blocks (v4.2.31)

    /// A bare host ("github.com/user/repo") is the paste mistake the address
    /// guard exists for. Saving refuses it; testing used to run git on it
    /// anyway — git reads it as a LOCAL PATH and the classified error misled
    /// more than it explained.
    func testTestConnectionRefusesBareHostInsteadOfRunningGit() async throws {
        let (model, _, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault"

        model.urlBinding(repoPath).wrappedValue = "github.com/user/repo"
        model.testConnection(repoPath)
        let first = model.message(repoPath)?.0 ?? ""
        XCTAssertTrue(first.contains("不完整"), "refusal expected, got: '\(first)'")

        // The guard returned BEFORE beginRepoOp: a second call must get the
        // same refusal, not "正在处理上一个操作" — the busy lock was never held.
        model.urlBinding(repoPath).wrappedValue = "example.org/x"
        model.testConnection(repoPath)
        let second = model.message(repoPath)?.0 ?? ""
        XCTAssertTrue(second.contains("不完整"),
                      "second refusal expected (busy lock must not be held), got: '\(second)'")
    }

    /// The refusal is narrow: complete forms still reach the probe. A local
    /// absolute path is the network-free representative (ssh:// and scp-style
    /// take the same branch — GitRemoteAddress is covered separately).
    func testTestConnectionSendsCompleteFormsIntoTheProbe() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault"
        let bare = URL(fileURLWithPath: base).appendingPathComponent("remote.git")
        _ = try? await service.repoManager.runner.run(["init", "--bare", bare.path])

        model.urlBinding(repoPath).wrappedValue = bare.path
        model.testConnection(repoPath)
        // The probe is async: wait for the alert to land.
        var outcome: ConnectionAlert?
        for _ in 0..<40 {
            outcome = model.connectionAlert
            if outcome != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(outcome?.ok, true, outcome?.detail ?? "probe never finished")
    }

    // MARK: - saveRepo's address guard, pinned end to end

    func testSaveRepoBlocksBareHostAndWritesNothing() async throws {
        let (model, service, base) = try await makeModel()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let repoPath = base + "/vault"

        model.urlBinding(repoPath).wrappedValue = "github.com/user/repo"
        var outcome: SettingsModel.SaveOutcome?
        model.saveRepo(repoPath) { outcome = $0 }
        guard case .blocked(let message) = outcome else {
            return XCTFail("expected .blocked for a bare host, got: \(String(describing: outcome))")
        }
        XCTAssertTrue(message.contains("不完整"), message)
        // The guard ran before any git write: the config stays remote-less.
        let stored = await service.repoManager.remoteURL(path: repoPath)
        XCTAssertNil(stored, "an incomplete address must never reach git config")
    }

    // MARK: - Support mail contract (v4.2.31: pinned, was fully untested)

    func testSupportMailURLCarriesAddressAndVersions() {
        let url = SettingsModel.supportMailURL(appVersion: "4.2.31", osText: "macOS 15.2")
        let absolute = url?.absoluteString ?? ""
        XCTAssertTrue(absolute.hasPrefix("mailto:support@filevault.app"), absolute)
        XCTAssertTrue(absolute.contains("4.2.31"), "subject must carry the app version: \(absolute)")
        XCTAssertTrue(absolute.contains("macOS%2015.2") || absolute.contains("macOS 15.2"),
                      "subject must carry the OS version: \(absolute)")
    }

    // MARK: - .gitignore chip insertion

    func testGitignoreChipInsertionDedupesByTrimmedLine() {
        XCTAssertEqual(GitignoreSheet.appendRule(".DS_Store", to: ""), ".DS_Store")
        XCTAssertEqual(GitignoreSheet.appendRule("*.log", to: ".DS_Store"), ".DS_Store\n*.log")
        XCTAssertEqual(GitignoreSheet.appendRule("*.log", to: ".DS_Store\n"), ".DS_Store\n*.log")
        XCTAssertEqual(GitignoreSheet.appendRule(".DS_Store", to: "  .DS_Store \n*.log"), "  .DS_Store \n*.log",
                       "a trimmed-line duplicate must not be inserted twice")
        XCTAssertEqual(GitignoreSheet.appendRule("node_modules/", to: "# .DS_Store"), "# .DS_Store\nnode_modules/")
    }
}
