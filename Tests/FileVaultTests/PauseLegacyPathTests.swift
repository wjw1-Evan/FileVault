import XCTest
@testable import FileVaultCore

/// v4.2.32 watchlist item 6: the ManagedRoot DECODER keeps the stored path
/// verbatim (only the memberwise init resolves it), so a legacy config can
/// carry a stored form that `resolved()` does not canonicalise to — e.g. a
/// folder the user added through a symlinked directory in a pre-resolving
/// version. setRootPaused compared the raw stored string against the
/// resolved runtime key — the match failed and the flag was never
/// persisted, so a pause silently died on the next restart.
///
/// (Probe note: URL.resolvingSymlinksInPath deliberately does NOT expand
/// the system /tmp symlink, so the fixture uses a USER-created symlink —
/// the only form where stored and resolved actually differ.)
final class PauseLegacyPathTests: XCTestCase {

    /// Write the config the way an OLD version left it on disk: the raw
    /// unresolved string must survive a load/save round trip untouched.
    private func seedLegacyConfig(directory: String, unresolvedPath: String) throws {
        let json = """
        {
          "roots": [{"path": "\(unresolvedPath)", "paused": false}],
          "general": {"notificationsEnabled": true, "autoCheckUpdates": true,
                      "debounceSeconds": 5, "language": "system",
                      "launchAtLoginRequested": false}
        }
        """
        let url = URL(fileURLWithPath: directory).appendingPathComponent("config.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    func testPausePersistsForALegacyUnresolvedStoredPath() async throws {
        let base = TestSupport.makeTempDir("pause-legacy")
        defer { try? FileManager.default.removeItem(atPath: base) }
        // Real folder reached through a user-created symlink: the legacy
        // stored form and the resolved runtime key genuinely differ.
        let realFolder = base + "/real/docs"
        try FileManager.default.createDirectory(atPath: realFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: base + "/alias",
                                                  withDestinationPath: base + "/real")
        let unresolved = base + "/alias/docs"
        XCTAssertEqual(URL(fileURLWithPath: unresolved).resolvingSymlinksInPath().path,
                       realFolder, "fixture premise: the two forms actually differ")

        let cfgDir = TestSupport.makeTempDir("pause-cfg")
        defer { try? FileManager.default.removeItem(atPath: cfgDir) }
        try seedLegacyConfig(directory: cfgDir, unresolvedPath: unresolved)

        let service = FileVaultService(configDirectory: URL(fileURLWithPath: cfgDir))
        // No start() needed: pausing never touches the git-backed members.

        await service.setRootPaused(true, root: unresolved)

        let reloaded = ConfigStore(directory: URL(fileURLWithPath: cfgDir)).load()
        XCTAssertEqual(reloaded.roots.count, 1)
        XCTAssertEqual(reloaded.roots[0].path, unresolved,
                       "the stored path keeps its legacy form (no silent rewrite)")
        XCTAssertTrue(reloaded.roots[0].paused,
                      "the pause flag must persist even when the stored form predates path resolving")
    }

    func testPauseStillPersistsForTheCanonicalStoredPath() async throws {
        let base = TestSupport.makeTempDir("pause-canonical")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let folder = base + "/docs"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let cfgDir = TestSupport.makeTempDir("pause-cfg2")
        defer { try? FileManager.default.removeItem(atPath: cfgDir) }
        let store = ConfigStore(directory: URL(fileURLWithPath: cfgDir))
        var cfg = store.load()
        cfg.roots.append(ManagedRoot(path: folder))
        store.save(cfg)

        let service = FileVaultService(configDirectory: URL(fileURLWithPath: cfgDir))
        await service.setRootPaused(true, root: folder)

        let reloaded = ConfigStore(directory: URL(fileURLWithPath: cfgDir)).load()
        XCTAssertTrue(reloaded.roots[0].paused, "the canonical path keeps working")
    }
}
