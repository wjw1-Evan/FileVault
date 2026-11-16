import XCTest
@testable import FileVaultCore

/// v4.2.15: changes made in the last seconds before quitting (before the 5 s
/// debounce fired) must be committed at the next launch — no FSEvents event
/// exists for them any more, so startup runs one catch-up sweep.
final class StartupCatchUpTests: XCTestCase {
    func testStartupCommitsChangesLeftFromLastSession() async throws {
        let base = TestSupport.makeTempDir("startup")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let folder = base + "/vault"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        TestSupport.write("seed", to: folder + "/seed.md")

        // A previous session had a repo; the user then edited and quit quickly.
        let setup = RepoManager(runner: TestSupport.newRunner())
        _ = try await setup.ensureRepo(at: folder)
        TestSupport.write("edited after quit", to: folder + "/draft.md")

        let cfgURL = URL(fileURLWithPath: base + "/cfg")
        let store = ConfigStore(directory: cfgURL)
        store.save(AppConfig(roots: [ManagedRoot(path: folder)]))

        let service = FileVaultService(configDirectory: cfgURL)
        try await service.start()

        var waited = 0.0
        var dirty = 1
        while waited < 10 {
            dirty = (try? await service.repoManager.status(path: folder).count) ?? 1
            if dirty == 0 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        XCTAssertEqual(dirty, 0, "startup must commit the leftover change")
        let files = await service.repoManager.listFiles(path: folder)
        XCTAssertTrue(files.contains("draft.md"))
        let log = try await service.repoManager.log(path: folder, max: 5)
        XCTAssertTrue(log.contains { $0.subject.contains("draft.md") }, log.map(\.subject).joined(separator: " | "))
    }
}
