import XCTest
@testable import FileVaultCore

/// Regression tests for the v4.2.26 audit.
///
/// Focus: the app must degrade readably (never trap) when the git environment
/// could not be prepared, and every git command must run non-interactively in a
/// stable English locale so the failure classifiers keep working.
final class ServiceReadinessTests: XCTestCase {
    private func makeServiceDir(_ name: String) -> (dir: String, configDir: URL) {
        let dir = TestSupport.makeTempDir(name)
        return (dir, URL(fileURLWithPath: dir).appendingPathComponent("config"))
    }

    /// A first launch where git cannot be found/installed leaves the service
    /// half-built. Adding a folder then used to dereference a nil
    /// implicitly-unwrapped repoManager and crash the app.
    func testNotReadyServiceRejectsAddRootWithReadableError() async throws {
        let (dir, configDir) = makeServiceDir("notready")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let folder = dir + "/vault"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        let service = FileVaultService(configDirectory: configDir, locator: FakeLocator(result: nil))
        XCTAssertFalse(service.isReady, "nothing is built before start()")
        do {
            try await service.start()
            XCTFail("start() must fail when git cannot be located")
        } catch {
            // expected: git environment failure is surfaced to the UI
        }
        XCTAssertFalse(service.isReady)

        do {
            try await service.addRoot(path: folder)
            XCTFail("addRoot() must throw instead of trapping on a nil repoManager")
        } catch let error as FileVaultServiceError {
            guard case .environmentNotReady = error else {
                return XCTFail("expected environmentNotReady, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.lowercased().contains("git"),
                          "the error must explain that Git is not ready")
        } catch {
            XCTFail("must be a readable FileVaultServiceError, got \(error)")
        }
        // A failed add must not leave a phantom entry in the config.
        XCTAssertTrue(service.configStore.load().roots.isEmpty)
    }

    /// Background paths (safety sweep, pause toggles, removal) can run while a
    /// retry of the git setup is still pending; they must be no-ops, not traps.
    func testNotReadyServiceBackgroundCallsAreSafe() async throws {
        let (dir, configDir) = makeServiceDir("notready-bg")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let folder = dir + "/vault"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let store = ConfigStore(directory: configDir)
        var cfg = store.load()
        cfg.roots = [ManagedRoot(path: folder)]
        XCTAssertTrue(store.save(cfg))

        let service = FileVaultService(configDirectory: configDir, locator: FakeLocator(result: nil))
        await service.sweepOnce()
        await service.commitAllNow()
        await service.setRootPaused(true, root: folder)
        await service.removeRoot(path: folder)
        XCTAssertTrue(service.configStore.load().roots.isEmpty, "removeRoot still forgets the folder")
    }
}

/// v4.2.26: v4.2.25 pinned git diagnostics to English by *defaulting* LC_ALL/LANG,
/// so an inherited user locale (Terminal launch, launchctl setenv, login item)
/// silently brought back the "translated git output breaks every classifier"
/// bug. The runner must force a non-interactive, English environment.
final class GitRunnerEnvironmentTests: XCTestCase {
    func testForcesStableLocaleAndNonInteractiveEditor() throws {
        let dir = TestSupport.makeTempDir("runner-env")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fakeGit = dir + "/git"
        let script = "#!/bin/sh\necho \"LC_ALL=$LC_ALL|LANG=$LANG|GIT_EDITOR=$GIT_EDITOR|GIT_PAGER=$GIT_PAGER\"\n"
        try script.write(toFile: fakeGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGit)

        setenv("LC_ALL", "zh_CN.UTF-8", 1)
        setenv("LANG", "zh_CN.UTF-8", 1)
        defer {
            unsetenv("LC_ALL")
            unsetenv("LANG")
        }

        let runner = GitRunner(gitExecutable: fakeGit, defaultTimeout: 10)
        let result = try runner.runSync(["version"], timeout: 10)
        XCTAssertTrue(result.succeeded, result.stderr)
        XCTAssertTrue(result.stdout.contains("LC_ALL=C|LANG=C"), result.stdout)
        XCTAssertTrue(result.stdout.contains("GIT_EDITOR=true"), result.stdout)
        XCTAssertTrue(result.stdout.contains("GIT_PAGER=cat"), result.stdout)
    }
}
